//! Proveedor de PDF, con el motor nativo enlazado **en tiempo de ejecución**.
//!
//! # Por qué se enlaza al arrancar y no al compilar
//!
//! El repositorio no versiona binarios, así que la biblioteca de PDF se obtiene
//! aparte, con hash fijado (`scripts/fetch-pdfium.mjs`). Enlazarla al compilar
//! haría que un clon limpio dejara de compilar sin ella, y el criterio 1 de la
//! el proyecto dice que un clon limpio compila **sin editar ningún archivo**.
//!
//! Enlazándola al arrancar, la aplicación compila y funciona sin ella: el
//! componente de PDF queda como no instalado, la interfaz oculta lo que dependa
//! de él, y todo lo demás sigue. Es la regla 1 de la Constitución aplicada a una
//! dependencia externa, y de paso hace trivial el escenario de caos que faltaba
//! para probar la ausencia, basta con no tenerla.
//!
//! # Sin motor de JavaScript
//!
//! Se usa la variante sin V8. El modelo de amenazas prohíbe expresamente que el
//! intérprete de PDF pueda ejecutar script, y la distinción está en el propio
//! archivo que se descarga, así que es verificable.
//!
//! Contratos: `docs/audit/threat-model.md`, sección 3.1, y
//! `docs/adr/002-critical-bottlenecks.md`.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};

use pdfium_render::prelude::{PdfDocumentMetadataTagType, PdfRenderConfig, Pdfium};

use super::locator::{contexto_de, Locations, Locator, TextContext};
use super::provider::{
    DocumentProvider, NativePosition, Navigation, NavigationEntry, PageSize, Precision,
    ProviderFactory, ReaderCapabilities, Rendered, Resolution, TextLayer, TextLayerStatus,
    TextSpan,
};
use crate::error::{NbError, NbResult};

/// Tipo de medio que sirve este proveedor.
pub const MEDIA_TYPE: &str = "application/pdf";

/// Variable con la que apuntar a la biblioteca a mano.
pub const RUTA_ENV: &str = "NB_BOOKS_PDFIUM";

/// Nombre del producto, tal y como lo escribe el empaquetador en la ruta de
/// recursos de Linux. Tiene que coincidir con `productName` de
/// `tauri.conf.json`; si uno de los dos cambia, el motor de PDF deja de
/// encontrarse en un `.deb` y en ningún otro sitio.
#[cfg(all(unix, not(target_os = "macos")))]
const NOMBRE_DEL_PRODUCTO: &str = "NB Books";

/// Un PDF no tiene recursos internos con nombre: la publicación es el recurso.
/// Readium usa `/` para ese caso y aquí se hace igual, para que un locator
/// exportado signifique lo mismo fuera.
const RECURSO: &str = "/";

/// Anchura a la que se rasteriza una página.
///
/// Fija y no dependiente de la ventana **a propósito**: si dependiera, cambiar
/// el tamaño de la ventana invalidaría la caché entera, y volver a rasterizar
/// cuatrocientas páginas por arrastrar un borde es exactamente el
/// comportamiento que el presupuesto de rendimiento prohíbe. La interfaz escala
/// la imagen, que es barato.
///
/// Hasta dos mil píxeles ahora dentro del presupuesto del lector.
/// Con 1.240, en una pantalla de doble
/// densidad la columna de lectura pide más de dos mil píxeles físicos y la
/// página se estiraba: el texto salía blando, y ampliarla lo empeoraba. Medido
/// en la aplicación instalada, 1.240 píxeles pintados sobre 2.056.
const ANCHO: i32 = 2000;

/// Mantiene la página dentro del presupuesto de píxeles del lector.
const MAXIMO_PIXELES_PAGINA: i32 = 5_000_000;

/// Presupuesto de la caché de páginas rasterizadas, en bytes.
///
/// El desalojo es por uso menos reciente. Sin tope, desplazarse por un documento
/// largo llena el disco de páginas que nadie va a volver a mirar.
const PRESUPUESTO_CACHE: u64 = 256 * 1024 * 1024;

/// Estado del motor nativo.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    /// La biblioteca está y responde.
    Available,
    /// No se encontró. La aplicación funciona; el PDF, no.
    NotInstalled,
}

/// Turno para hablar con el motor nativo.
///
/// **PDFium no admite llamadas concurrentes.** No es una suposición: la primera
/// versión de este módulo dejaba que las pruebas lo usaran desde varios hilos a
/// la vez y el proceso moría con `SIGTRAP`, que es como una comprobación interna
/// de C++ aborta. La característica `thread_safe` del envoltorio de Rust protege
/// las vinculaciones, no el estado interno del motor.
///
/// Serializar aquí, en la frontera, es lo que hace que el resto del programa no
/// tenga que saberlo. El coste es que dos páginas no se rasterizan a la vez; la
/// alternativa es que el proceso se caiga entero, que es exactamente lo que la
/// regla 1 de la Constitución prohíbe.
static TURNO: Mutex<()> = Mutex::new(());

fn turno() -> MutexGuard<'static, ()> {
    // Un mutex envenenado significa que un hilo entró en pánico usando el motor.
    // Seguir usándolo es lo correcto: el pánico era del código de arriba, y
    // negarse a rasterizar para siempre por eso sería convertir un fallo local
    // en uno permanente.
    TURNO
        .lock()
        .unwrap_or_else(|envenenado| envenenado.into_inner())
}

fn motor() -> &'static Option<Pdfium> {
    static MOTOR: OnceLock<Option<Pdfium>> = OnceLock::new();

    MOTOR.get_or_init(|| {
        let _turno = turno();
        let Some(candidatas) = rutas_candidatas() else {
            tracing::info!(
                "se indicó una ruta de biblioteca de PDF que no existe; el componente queda como no instalado"
            );
            return None;
        };

        for ruta in candidatas {
            if let Ok(vinculos) = Pdfium::bind_to_library(&ruta) {
                tracing::info!("motor de PDF disponible");
                return Some(Pdfium::new(vinculos));
            }
        }

        if let Ok(vinculos) = Pdfium::bind_to_system_library() {
            tracing::info!("motor de PDF disponible en el sistema");
            return Some(Pdfium::new(vinculos));
        }

        // No es un error: es una capacidad que esta instalación no tiene.
        tracing::info!(
            "no se encontró la biblioteca de PDF; el componente queda como no instalado"
        );
        None
    })
}

/// Dónde se busca la biblioteca, en orden.
///
/// No se registran las rutas: son del sistema de quien ejecuta.
fn rutas_candidatas() -> Option<Vec<PathBuf>> {
    // Si alguien dice dónde está, **manda esa ruta y no se busca en otro sitio**.
    // Una configuración explícita que se ignora en silencio porque había otra
    // copia por ahí es peor que no tener configuración.
    //
    // Y de paso es el mecanismo de inyección de fallos que la suite de caos
    // necesita para el escenario de "ausencia de la biblioteca nativa": apuntar
    // a una ruta que no existe.
    if let Some(ruta) = std::env::var_os(RUTA_ENV) {
        let ruta = PathBuf::from(ruta);
        return ruta.exists().then_some(vec![ruta]);
    }

    let mut rutas = Vec::new();

    // 2. Donde el instalador deja los recursos, que **no es el mismo sitio en
    //    las tres plataformas**. Decía "junto al ejecutable" y eso solo es
    //    cierto en Windows: en un `.deb` el binario va a `/usr/bin` y los
    //    recursos a `/usr/lib/NB Books`, y en un `.app` de macOS son
    //    `Contents/MacOS` y `Contents/Resources`. Buscar solo junto al binario
    //    dejaba el motor de PDF sin encontrar en dos de las tres.
    //
    //    Se calcula desde el ejecutable en lugar de pedírselo a Tauri porque
    //    esto corre en `bootstrap()`, antes de que exista el `AppHandle`.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            rutas.push(Pdfium::pdfium_platform_library_name_at_path(dir));

            #[cfg(target_os = "macos")]
            rutas.push(Pdfium::pdfium_platform_library_name_at_path(
                dir.join("../Resources").as_path(),
            ));

            #[cfg(all(unix, not(target_os = "macos")))]
            rutas.push(Pdfium::pdfium_platform_library_name_at_path(
                dir.join("../lib").join(NOMBRE_DEL_PRODUCTO).as_path(),
            ));
        }
    }

    // 3. Donde la deja `scripts/fetch-pdfium.mjs` en desarrollo.
    rutas.push(Pdfium::pdfium_platform_library_name_at_path(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../vendor/pdfium")
            .as_path(),
    ));

    Some(rutas)
}

/// Indica si el motor de PDF está disponible en esta instalación.
///
/// Es lo que el registro de componentes consulta al arrancar para decidir si el
/// lector de PDF se ofrece o se oculta.
#[must_use]
pub fn engine_state() -> Engine {
    if motor().is_some() {
        Engine::Available
    } else {
        Engine::NotInstalled
    }
}

/// Convierte el tamaño que da el motor a píxeles enteros.
///
/// Un tamaño no positivo o no finito se sustituye por uno de un punto en lugar
/// de por cero: cero haría que la relación de aspecto fuese una división por
/// cero justo donde la interfaz reserva el hueco.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn medida(ancho: f32, alto: f32) -> PageSize {
    let sano = |v: f32| {
        if v.is_finite() && v >= 1.0 {
            v.round() as u32
        } else {
            1
        }
    };
    PageSize {
        width: sano(ancho),
        height: sano(alto),
    }
}

fn ancho_de_rasterizado(ancho: f32, alto: f32) -> NbResult<i32> {
    if !ancho.is_finite() || !alto.is_finite() || ancho <= 0.0 || alto <= 0.0 {
        return Err(NbError::DocumentCorrupted);
    }
    let proporcion = f64::from(alto) / f64::from(ancho);
    let presupuesto = f64::from(MAXIMO_PIXELES_PAGINA);
    let mut objetivo = (presupuesto / proporcion)
        .sqrt()
        .floor()
        .clamp(1.0, f64::from(ANCHO)) as i32;
    let pixeles = |ancho: i32| f64::from(ancho) * (f64::from(ancho) * proporcion).ceil();
    // Contar también la fila que añade el redondeo del alto al rasterizar.
    while objetivo > 1 && pixeles(objetivo) > presupuesto {
        objetivo -= 1;
    }
    if pixeles(objetivo) > presupuesto {
        return Err(NbError::DocumentCorrupted);
    }
    Ok(objetivo)
}

/// Cuántas páginas se miran como mucho para decidir si el PDF tiene capa de
/// texto. Un preliminar sin texto —cubierta, guarda, portadilla— no pasa de
/// unas pocas páginas; recorrer treinta y nueve mil al abrir o al consultar las
/// capacidades era lo que hacía tardar minutos un documento grande.
const MUESTRA_CAPA_TEXTO: u16 = 24;

/// Cuántos bytes de cada extremo del archivo entran en la huella de la caché de
/// páginas. Dos PDF con distinto contenido difieren en la cabecera, en los
/// primeros objetos, en la tabla `xref`/cola o en su tamaño; leer esos dos
/// extremos evita hashear un gigabyte entero al abrir o en cada página.
const TRAMO_HUELLA_CACHE: u64 = 64 * 1024;

/// Calcula la identidad corta con la que se nombran los PNG en la caché.
fn huella_para_cache(ruta: &Path) -> String {
    use sha2::{Digest, Sha256};
    use std::io::{Read, Seek, SeekFrom};

    let Ok(mut archivo) = crate::paths::open_noatime(ruta) else {
        return "desconocido".to_owned();
    };
    let largo = archivo.metadata().map_or(0, |m| m.len());

    let mut hasher = Sha256::new();
    hasher.update(largo.to_le_bytes());

    let mut buf = vec![0_u8; usize::try_from(TRAMO_HUELLA_CACHE.min(largo)).unwrap_or(0)];
    if let Ok(n) = archivo.read(&mut buf) {
        hasher.update(&buf[..n]);
    }
    if largo > TRAMO_HUELLA_CACHE {
        let desde = largo.saturating_sub(TRAMO_HUELLA_CACHE);
        if archivo.seek(SeekFrom::Start(desde)).is_ok() {
            if let Ok(n) = archivo.read(&mut buf) {
                hasher.update(&buf[..n]);
            }
        }
    }

    let digest = hasher.finalize();
    let mut salida = String::with_capacity(16);
    for byte in &digest[..8] {
        use std::fmt::Write;
        let _ = write!(salida, "{byte:02x}");
    }
    salida
}

/// Documento de PDFium mantenido abierto mientras dura [`PdfDocument`].
///
/// Volver a llamar a `load_pdf_from_file` en cada página obligaba a releer la
/// tabla de referencias cruzadas entera en cada paso de página. Mantenerlo
/// abierto evita ese coste; todo acceso —incluido `Drop`— ocurre bajo [`turno`].
struct DocumentoAbierto(std::mem::ManuallyDrop<pdfium_render::prelude::PdfDocument<'static>>);

// SAFETY: PDFium no admite llamadas concurrentes, pero todo acceso al documento
// —incluido su cierre en `Drop`— adquiere antes el cerrojo global `TURNO`.
unsafe impl Send for DocumentoAbierto {}
unsafe impl Sync for DocumentoAbierto {}

impl DocumentoAbierto {
    const fn new(doc: pdfium_render::prelude::PdfDocument<'static>) -> Self {
        Self(std::mem::ManuallyDrop::new(doc))
    }

    fn get(&self) -> &pdfium_render::prelude::PdfDocument<'static> {
        &self.0
    }
}

impl Drop for DocumentoAbierto {
    fn drop(&mut self) {
        let _turno = turno();
        // SAFETY: `self.0` solo se suelta aquí, una vez y bajo `TURNO`.
        unsafe {
            std::mem::ManuallyDrop::drop(&mut self.0);
        }
    }
}

/// Un PDF abierto.
pub struct PdfDocument {
    documento: DocumentoAbierto,
    paginas: u16,
    /// Identidad del archivo para nombrar sus páginas en la caché, calculada
    /// una sola vez al abrir.
    identidad: String,
    /// Texto por página, extraído a demanda y recordado para no pedírselo dos
    /// veces al motor.
    texto: Vec<OnceLock<String>>,
    /// Tamaño de cada página, en puntos, leído a demanda y recordado.
    tamanos: Vec<OnceLock<PageSize>>,
    /// Si el documento tiene capa de texto, calculado una vez sobre las
    /// primeras páginas con [`MUESTRA_CAPA_TEXTO`].
    tiene_texto: OnceLock<bool>,
    cache: PathBuf,
}

impl PdfDocument {
    /// Abre un PDF.
    ///
    /// # Errors
    ///
    /// - [`NbError::ComponentUnavailable`] si no hay motor de PDF instalado. Es
    ///   deliberadamente distinto de que el archivo esté mal: la interfaz oculta
    ///   la función en lugar de decirle al usuario que su documento está roto.
    /// - [`NbError::FileNotFound`] si la ruta no existe.
    /// - [`NbError::DocumentCorrupted`] si el motor no lo puede abrir.
    pub fn open(path: &Path, cache_dir: &Path) -> NbResult<Self> {
        let Some(motor) = motor().as_ref() else {
            return Err(NbError::ComponentUnavailable);
        };

        if !path.exists() {
            return Err(NbError::FileNotFound);
        };

        let identidad = huella_para_cache(path);

        let (documento, paginas) = {
            let _turno = turno();
            let archivo = crate::paths::open_noatime(path).map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    NbError::FileNotFound
                } else {
                    NbError::DocumentCorrupted
                }
            })?;
            let documento = motor.load_pdf_from_reader(archivo, None).map_err(|error| {
                // El error del motor puede citar la ruta: no se registra.
                tracing::warn!(
                    clase = ?std::mem::discriminant(&error),
                    "el motor no pudo abrir el PDF"
                );
                NbError::DocumentCorrupted
            })?;

            let paginas = u16::try_from(documento.pages().len()).unwrap_or(u16::MAX);
            (DocumentoAbierto::new(documento), paginas)
        };

        if paginas == 0 {
            return Err(NbError::DocumentCorrupted);
        }

        let total = usize::from(paginas);
        let texto = (0..total).map(|_| OnceLock::new()).collect();
        let tamanos = (0..total).map(|_| OnceLock::new()).collect();

        Ok(Self {
            documento,
            paginas,
            identidad,
            texto,
            tamanos,
            tiene_texto: OnceLock::new(),
            cache: cache_dir.to_path_buf(),
        })
    }

    /// Título y autor que declara el diccionario de información del PDF.
    ///
    /// Muchos escaneos lo traen vacío o con el nombre del programa que los hizo;
    /// por eso lo que sale de aquí entra como propuesta del archivo, que pierde
    /// frente a lo que el usuario corrija.
    #[must_use]
    pub fn declared_metadata(&self) -> (Option<String>, Option<String>) {
        let _turno = turno();
        let datos = self.documento.get().metadata();
        let leer = |etiqueta| {
            datos
                .get(etiqueta)
                .map(|t| t.value().trim().to_owned())
                .filter(|v| !v.is_empty())
        };
        (
            leer(PdfDocumentMetadataTagType::Title),
            leer(PdfDocumentMetadataTagType::Author),
        )
    }

    /// Número de páginas.
    #[must_use]
    pub const fn page_count(&self) -> u16 {
        self.paginas
    }

    /// Indica si el documento tiene capa de texto.
    ///
    /// Un PDF escaneado sin OCR no la tiene, y eso **se le dice al usuario** en
    /// lugar de presentarle un documento silenciosamente ilegible para un lector
    /// de pantalla. Es requisito de accesibilidad, no una mejora.
    #[must_use]
    pub fn has_text_layer(&self) -> bool {
        *self.tiene_texto.get_or_init(|| {
            if self
                .texto
                .iter()
                .filter_map(OnceLock::get)
                .any(|t| !t.trim().is_empty())
            {
                return true;
            }
            let tope = self.paginas.min(MUESTRA_CAPA_TEXTO);
            (1..=tope).any(|p| self.page_text(p).is_ok_and(|t| !t.trim().is_empty()))
        })
    }

    /// Texto de una página.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si la página no existe.
    pub fn page_text(&self, page: u16) -> NbResult<&str> {
        let indice = usize::from(page.checked_sub(1).ok_or(NbError::DocumentNotFound)?);
        let celda = self.texto.get(indice).ok_or(NbError::DocumentNotFound)?;
        if let Some(texto) = celda.get() {
            return Ok(texto.as_str());
        }

        let (texto, tamano) = {
            let _turno = turno();
            let pagina = self
                .documento
                .get()
                .pages()
                .get(i32::from(page) - 1)
                .map_err(|_| NbError::DocumentNotFound)?;
            let texto = normalizar(&pagina.text().map(|t| t.all()).unwrap_or_default());
            let tamano = medida(pagina.width().value, pagina.height().value);
            (texto, tamano)
        };

        let _ = self.tamanos[indice].set(tamano);
        Ok(celda.get_or_init(|| texto).as_str())
    }

    /// Tamaño de una página, en puntos del documento.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si la página no existe.
    pub fn page_dimensions(&self, page: u16) -> NbResult<PageSize> {
        let indice = usize::from(page.checked_sub(1).ok_or(NbError::DocumentNotFound)?);
        let celda = self.tamanos.get(indice).ok_or(NbError::DocumentNotFound)?;
        if let Some(tamano) = celda.get() {
            return Ok(*tamano);
        }

        let tamano = {
            let _turno = turno();
            let pagina = self
                .documento
                .get()
                .pages()
                .get(i32::from(page) - 1)
                .map_err(|_| NbError::DocumentNotFound)?;
            medida(pagina.width().value, pagina.height().value)
        };

        let _ = celda.set(tamano);
        Ok(tamano)
    }

    /// Capa de texto de una página, con las coordenadas de cada fragmento.
    ///
    /// Es lo que la interfaz superpone sobre la imagen para que un lector de
    /// pantalla lea el contenido y para que la selección de texto sea real y no
    /// un rectángulo dibujado encima. Requisito de accesibilidad, no mejora: sin
    /// esto, un PDF es una imagen opaca para quien no la ve.
    ///
    /// Cuando el documento no tiene texto, se devuelve la capa **vacía y
    /// declarada como ausente**, en lugar de una lista vacía que sería
    /// indistinguible de una página en blanco.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si la página no existe,
    /// [`NbError::ComponentUnavailable`] si no hay motor, o
    /// [`NbError::DocumentCorrupted`] si la página no se deja leer.
    pub fn page_text_layer(&self, page: u16) -> NbResult<TextLayer> {
        if page == 0 || page > self.paginas {
            return Err(NbError::DocumentNotFound);
        }

        if !self.has_text_layer() {
            return Ok(TextLayer {
                page: u32::from(page),
                status: TextLayerStatus::Missing,
                spans: Vec::new(),
            });
        }

        if motor().is_none() {
            return Err(NbError::ComponentUnavailable);
        }

        let _turno = turno();
        let pagina = self
            .documento
            .get()
            .pages()
            .get(i32::from(page) - 1)
            .map_err(|_| NbError::DocumentNotFound)?;

        let ancho = f64::from(pagina.width().value);
        let alto = f64::from(pagina.height().value);
        if ancho <= 0.0 || alto <= 0.0 {
            return Err(NbError::DocumentCorrupted);
        }

        let texto = pagina.text().map_err(|_| NbError::DocumentCorrupted)?;
        let mut spans = Vec::new();

        for segmento in texto.segments().iter() {
            let contenido = segmento.text();
            if contenido.trim().is_empty() {
                continue;
            }
            let caja = segmento.bounds();

            spans.push(TextSpan {
                text: contenido,
                x: f64::from(caja.left().value) / ancho,
                // PDF cuenta desde abajo y el marcado desde arriba. Se convierte
                // aquí una vez, no en cada consumidor.
                y: 1.0 - f64::from(caja.top().value) / alto,
                width: f64::from(caja.width().value) / ancho,
                height: f64::from(caja.height().value) / alto,
            });
        }

        Ok(TextLayer {
            page: u32::from(page),
            status: TextLayerStatus::Available,
            spans,
        })
    }

    /// Estado de accesibilidad del documento entero.
    ///
    /// Lo que la interfaz necesita para poder **decirlo** en lugar de que el
    /// usuario lo descubra.
    #[must_use]
    pub fn accessibility(&self) -> TextLayerStatus {
        if self.has_text_layer() {
            TextLayerStatus::Available
        } else {
            TextLayerStatus::Missing
        }
    }

    /// Rasteriza una página y devuelve la ruta de la imagen.
    ///
    /// Escribe en la caché y no en memoria porque la imagen va al webview por el
    /// protocolo de assets: pasarla por el canal JSON obligaría a codificarla en
    /// base64 dentro de un mensaje.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si la página no existe,
    /// [`NbError::ComponentUnavailable`] si el motor desapareció, o
    /// [`NbError::StorageFailure`] si no se puede escribir la caché.
    pub fn render_page(&self, page: u16) -> NbResult<PathBuf> {
        if page == 0 || page > self.paginas {
            return Err(NbError::DocumentNotFound);
        }

        let destino = self.ruta_en_cache(page);
        if destino.exists() {
            // Tocar el archivo lo hace el más reciente para el desalojo.
            let _ = std::fs::File::open(&destino)
                .and_then(|f| f.set_modified(std::time::SystemTime::now()));
            return Ok(destino);
        }

        if motor().is_none() {
            return Err(NbError::ComponentUnavailable);
        }

        let (ancho, alto, rgba) = {
            let _turno = turno();
            let pagina = self
                .documento
                .get()
                .pages()
                .get(i32::from(page) - 1)
                .map_err(|_| NbError::DocumentNotFound)?;

            let ancho = ancho_de_rasterizado(pagina.width().value, pagina.height().value)?;
            let mapa = pagina
                .render_with_config(
                    &PdfRenderConfig::new()
                        .set_target_width(ancho)
                        .set_maximum_width(ancho)
                        .set_maximum_height(MAXIMO_PIXELES_PAGINA / ancho),
                )
                .map_err(|_| NbError::DocumentCorrupted)?;

            // Se copian las dimensiones y los píxeles, y se suelta el turno
            // antes de tocar el disco: escribir un PNG no necesita el motor, y
            // retenerlo mientras se escribe serializaría también la parte que
            // no hace falta.
            (mapa.width(), mapa.height(), mapa.as_rgba_bytes())
        };

        std::fs::create_dir_all(&self.cache).map_err(|_| NbError::StorageFailure)?;
        escribir_png(&destino, ancho, alto, &rgba)?;

        // El desalojo va después de escribir: primero está la página que se
        // acaba de pedir, y luego se hace sitio.
        desalojar(&self.cache, PRESUPUESTO_CACHE);

        Ok(destino)
    }

    fn ruta_en_cache(&self, page: u16) -> PathBuf {
        // Los límites van en el nombre para no reutilizar un raster anterior
        // sobredimensionado. Las páginas antiguas las retira el desalojo.
        self.cache.join(format!(
            "{}-{page:05}-{ANCHO}-{MAXIMO_PIXELES_PAGINA}.png",
            self.identidad
        ))
    }
}

impl DocumentProvider for PdfDocument {
    fn media_type(&self) -> &str {
        MEDIA_TYPE
    }

    fn navigation(&self) -> NbResult<Navigation> {
        // El índice del propio PDF llega; por ahora, una entrada por
        // página, que es navegación real y no un hueco. No pide `locator_at` en
        // cada página porque `locator_at` extrae la cita de texto para el
        // reanclaje, y hacerlo aquí obligaría a leer todas las páginas al abrir.
        let entries = (1..=self.paginas)
            .map(|pagina| {
                let locator = Locator::new(
                    RECURSO,
                    MEDIA_TYPE,
                    Locations {
                        fragments: vec![format!("page={pagina}")],
                        progression: Some(0.0),
                        total_progression: Some(f64::from(pagina - 1) / f64::from(self.paginas)),
                        position: Some(u32::from(pagina)),
                    },
                    None,
                )?
                .with_title(&format!("Página {pagina}"));

                Ok(NavigationEntry {
                    title: format!("Página {pagina}"),
                    locator,
                    children: Vec::new(),
                })
            })
            .collect::<NbResult<Vec<_>>>()?;

        Ok(Navigation { entries })
    }

    fn locator_at(&self, position: &NativePosition) -> NbResult<Locator> {
        let NativePosition::Page(pagina) = position else {
            // Un PDF tiene páginas fijas: no hay recursos internos con nombre ni
            // línea temporal.
            return Err(NbError::PathNotAllowed);
        };
        let pagina = u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?;
        if pagina == 0 || pagina > self.paginas {
            return Err(NbError::PathNotAllowed);
        }

        // La cita es lo que permite reanclar cuando el documento cambia de
        // edición y las páginas se desplazan.
        let contexto = self
            .page_text(pagina)
            .ok()
            .map(|t| t.chars().take(48).collect::<String>())
            .filter(|c| !c.trim().is_empty())
            .and_then(|cita| TextContext::new(None, &cita, None).ok());

        Locator::new(
            RECURSO,
            MEDIA_TYPE,
            Locations {
                fragments: vec![format!("page={pagina}")],
                progression: Some(0.0),
                total_progression: Some(f64::from(pagina - 1) / f64::from(self.paginas)),
                position: Some(u32::from(pagina)),
            },
            contexto,
        )
        .map(|l| l.with_title(&format!("Página {pagina}")))
    }

    fn resolve(&self, locator: &Locator) -> NbResult<Resolution> {
        // 1. La página, corroborada con la cita cuando la hay: que una página
        //    exista no prueba que siga teniendo el mismo texto.
        if let Some(pagina) = locator
            .locations
            .position
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p >= 1 && *p <= self.paginas)
        {
            let corrobora = locator.text.as_ref().is_none_or(|contexto| {
                self.page_text(pagina)
                    .is_ok_and(|t| t.starts_with(&contexto.highlight))
            });
            if corrobora {
                return Ok(Resolution {
                    position: NativePosition::Page(u32::from(pagina)),
                    precision: Precision::Exact,
                });
            }
        }

        // 2. La cita, en cualquier página: si al documento le añadieron un
        //    prólogo, el texto sigue estando aunque su página haya cambiado.
        if let Some(cita) = locator.text.as_ref().map(|t| t.highlight.as_str()) {
            if let Some(pagina) =
                (1..=self.paginas).find(|&p| self.page_text(p).is_ok_and(|t| t.contains(cita)))
            {
                return Ok(Resolution {
                    position: NativePosition::Page(u32::from(pagina)),
                    precision: Precision::Quote,
                });
            }
        }

        // 3. La progresión total, y se marca.
        if let Some(total) = locator.locations.total_progression {
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let pagina = ((total * f64::from(self.paginas)) as u16 + 1).min(self.paginas);
            return Ok(Resolution {
                position: NativePosition::Page(u32::from(pagina)),
                precision: Precision::Approximate,
            });
        }

        Err(NbError::DocumentNotFound)
    }

    fn text_range(&self, locator: &Locator, len: usize) -> NbResult<String> {
        if !self.has_text_layer() {
            // Un escaneado sin OCR no tiene texto que dar, y devolver una cadena
            // vacía sería indistinguible de una página en blanco.
            return Err(NbError::FormatUnsupported);
        }

        let resolucion = self.resolve(locator)?;
        let NativePosition::Page(pagina) = resolucion.position else {
            return Err(NbError::DocumentCorrupted);
        };

        Ok(self
            .page_text(u16::try_from(pagina).unwrap_or(1))?
            .chars()
            .take(len)
            .collect())
    }

    fn render(&self, position: &NativePosition) -> NbResult<Rendered> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };

        let ruta =
            self.render_page(u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?)?;

        Ok(Rendered::Image {
            path: ruta.to_string_lossy().into_owned(),
            media_type: "image/png".to_owned(),
        })
    }

    fn text_chunks(&self, max_chars: usize) -> NbResult<Vec<(Locator, String)>> {
        let mut salida = Vec::new();
        let mut con_texto = 0_u16;

        for pagina in 1..=self.paginas {
            // Una página que no se deja leer no detiene la indexación del resto:
            // un PDF con una página dañada sigue siendo buscable en las otras
            // doscientas, y negarse a indexarlo entero por una sería castigar al
            // usuario por un defecto del archivo.
            let Ok(texto) = self.page_text(pagina) else {
                tracing::info!(pagina, "una página no dio texto al indexar");
                continue;
            };
            if texto.trim().is_empty() {
                continue;
            }
            con_texto += 1;

            let locator = self.locator_at(&NativePosition::Page(u32::from(pagina)))?;
            // Una página larga se parte, pero **todos sus trozos comparten el
            // locator de la página**: en un PDF la unidad de posición es la
            // página, y fabricar posiciones intermedias sería inventarse una
            // precisión que el formato no tiene.
            for trozo in trocear(texto, max_chars) {
                salida.push((locator.clone(), trozo));
            }
        }

        if con_texto == 0 {
            // Ni una página con texto: es un escaneo sin OCR. Se dice, en lugar
            // de devolver una lista vacía que parecería un documento indexado y
            // sin resultados.
            return Err(NbError::FormatUnsupported);
        }

        Ok(salida)
    }

    fn page_size(&self, position: &NativePosition) -> NbResult<PageSize> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };
        self.page_dimensions(u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?)
    }

    fn text_layer(&self, position: &NativePosition) -> NbResult<TextLayer> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };
        self.page_text_layer(u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?)
    }

    fn locator_for_quote(&self, quote: &str, hint: Option<f64>) -> NbResult<Locator> {
        // El espacio en blanco del marcado no es contenido, y el texto de este
        // documento ya está normalizado. La cita llega del webview tal y como se
        // ve —con la indentación del XHTML dentro—, así que se normaliza igual
        // antes de buscarla: sin esto, un párrafo escrito en varias líneas no se
        // encontraría nunca y no se podría anotar.
        let cita = quote.split_whitespace().collect::<Vec<_>>().join(" ");
        let cita = cita.as_str();
        if cita.is_empty() {
            // Una cita vacía encuentra cualquier punto del documento, así que
            // anclaría en el primero. Es la misma invariante que el Locator ya
            // hace cumplir; aquí se rechaza antes de buscar.
            return Err(NbError::PathNotAllowed);
        }

        let paginas = f64::from(self.paginas);
        let objetivo = hint.unwrap_or(0.0);

        // De todas las páginas donde aparezca la cita se elige la más cercana a
        // donde el usuario estaba leyendo. Ordenar primero los números de
        // página por distancia a `objetivo` y parar en la primera coincidencia
        // da exactamente el mismo resultado que recorrerlas todas, pero cuando
        // el usuario selecciona en la página que tiene delante solo extrae el
        // texto de esa página.
        let mut candidatas: Vec<u16> = (1..=self.paginas).collect();
        candidatas.sort_by(|&a, &b| {
            let da = (f64::from(a - 1) / paginas - objetivo).abs();
            let db = (f64::from(b - 1) / paginas - objetivo).abs();
            da.total_cmp(&db).then_with(|| a.cmp(&b))
        });

        let mut encontrada: Option<(u16, usize)> = None;
        for pagina in candidatas {
            let Ok(texto) = self.page_text(pagina) else {
                continue;
            };
            if let Some(byte) = texto.find(cita) {
                encontrada = Some((pagina, byte));
                break;
            }
        }

        let (pagina, byte) = encontrada.ok_or(NbError::DocumentNotFound)?;
        let texto = self.page_text(pagina)?;
        let contexto = contexto_de(texto, byte, cita)?;

        Locator::new(
            RECURSO,
            MEDIA_TYPE,
            Locations {
                fragments: vec![format!("page={pagina}")],
                progression: Some(0.0),
                total_progression: Some(f64::from(pagina - 1) / paginas),
                position: Some(u32::from(pagina)),
            },
            Some(contexto),
        )
        .map(|l| l.with_title(&format!("Página {pagina}")))
    }

    fn capabilities(&self) -> ReaderCapabilities {
        ReaderCapabilities {
            text_selection: self.has_text_layer(),
            internal_search: self.has_text_layer(),
            // Un PDF tiene páginas fijas: ni se re-pagina ni admite cambiar la
            // tipografía. Ofrecer esos controles sería prometer algo imposible.
            reflow: false,
            typography: false,
            synchronized_audio: false,
            text_extraction: self.has_text_layer(),
        }
    }
}

/// Fábrica del proveedor de PDF.
pub struct PdfFactory {
    cache: PathBuf,
}

impl PdfFactory {
    /// Crea la fábrica con el directorio donde cachear las páginas.
    #[must_use]
    pub fn new(cache_dir: PathBuf) -> Self {
        Self { cache: cache_dir }
    }
}

impl ProviderFactory for PdfFactory {
    fn media_type(&self) -> &'static str {
        MEDIA_TYPE
    }

    fn open(&self, path: &Path) -> NbResult<Box<dyn DocumentProvider>> {
        Ok(Box::new(PdfDocument::open(path, &self.cache)?))
    }
}

/// Normaliza el texto de una página.
fn normalizar(texto: &str) -> String {
    texto.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Escribe una imagen RGBA como PNG.
///
/// Con `png`, que ya estaba en el árbol, en lugar de arrastrar el crate `image`
/// entero con decodificadores de formatos que aquí no se usan.
fn escribir_png(destino: &Path, ancho: i32, alto: i32, rgba: &[u8]) -> NbResult<()> {
    // Atómica: la caché se consulta por existencia del archivo desde otro hilo,
    // y un PNG a medio escribir no se decodifica.
    crate::paths::write_atomic(destino, |temporal| {
        let archivo = std::fs::File::create(temporal).map_err(|_| NbError::StorageFailure)?;
        let mut codificador = png::Encoder::new(
            std::io::BufWriter::new(archivo),
            u32::try_from(ancho).unwrap_or(0),
            u32::try_from(alto).unwrap_or(0),
        );
        codificador.set_color(png::ColorType::Rgba);
        codificador.set_depth(png::BitDepth::Eight);
        codificador.set_compression(png::Compression::Fast);

        codificador
            .write_header()
            .and_then(|mut w| w.write_image_data(rgba))
            .map_err(|_| NbError::StorageFailure)
    })
}

/// Desaloja las páginas menos recientes hasta caber en el presupuesto.
fn desalojar(cache: &Path, presupuesto: u64) {
    let Ok(entradas) = std::fs::read_dir(cache) else {
        return;
    };

    let mut paginas: Vec<(std::time::SystemTime, u64, PathBuf)> = entradas
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_some_and(|x| x == "png"))
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            Some((meta.modified().ok()?, meta.len(), e.path()))
        })
        .collect();

    let total: u64 = paginas.iter().map(|(_, tamano, _)| tamano).sum();
    if total <= presupuesto {
        return;
    }

    // De la más antigua a la más reciente: se desaloja por uso menos reciente.
    paginas.sort_by_key(|(cuando, _, _)| *cuando);

    let mut acumulado = total;
    let mut desalojadas = 0;
    for (_, tamano, ruta) in paginas {
        if acumulado <= presupuesto {
            break;
        }
        if std::fs::remove_file(&ruta).is_ok() {
            acumulado -= tamano;
            desalojadas += 1;
        }
    }

    tracing::debug!(desalojadas, "caché de páginas ajustada al presupuesto");
}

/// Parte un texto en trozos de como mucho `max_chars` caracteres, cortando por
/// párrafo, por frase o por espacio.
///
/// Cortar a ciegas partiría una palabra por la mitad y la dejaría fuera del
/// índice en sus dos mitades, que es peor que un trozo algo más corto.
fn trocear(texto: &str, max_chars: usize) -> Vec<String> {
    let caracteres: Vec<char> = texto.chars().collect();
    // Por párrafo, por frase o por espacio, en ese orden. En una página
    // de PDF un salto de línea suelto es una línea de la maquetación, así que el
    // párrafo es la línea en blanco. Ver `segmentos`.
    let fronteras = super::segmentos::fronteras_por_linea_en_blanco(&caracteres);
    super::segmentos::segmentar(&caracteres, &fronteras, max_chars)
        .into_iter()
        .map(|tramo| caracteres[tramo].iter().collect::<String>())
        .filter(|trozo| !trozo.trim().is_empty())
        .collect()
}

#[cfg(test)]
mod pruebas_de_rasterizado {
    use super::ancho_de_rasterizado;
    use crate::error::NbError;

    #[test]
    fn una_pagina_cuadrada_u_horizontal_conserva_los_dos_mil_pixeles() {
        assert_eq!(ancho_de_rasterizado(200.0, 200.0), Ok(2000));
        assert_eq!(ancho_de_rasterizado(842.0, 595.0), Ok(2000));
        assert_eq!(ancho_de_rasterizado(200.0, 250.0), Ok(2000));
    }

    #[test]
    fn una_geometria_imposible_no_llega_a_reservar_un_bitmap() {
        for (ancho, alto) in [
            (0.0, 100.0),
            (100.0, 0.0),
            (f32::NAN, 100.0),
            (100.0, f32::INFINITY),
            (f32::MIN_POSITIVE, f32::MAX),
        ] {
            assert_eq!(
                ancho_de_rasterizado(ancho, alto),
                Err(NbError::DocumentCorrupted)
            );
        }
    }
}

#[cfg(test)]
mod pruebas_de_empaquetado {
    /// El motor de PDF tiene que **viajar dentro del instalador**.
    ///
    /// Es la lección de una aplicación anterior del mismo autor, que exigía
    /// instalar a mano VLC, una versión concreta de Python y media docena de
    /// paquetes antes de arrancar. Aquí el criterio es que quien instala no
    /// instala nada más, así que la biblioteca nativa va declarada como recurso
    /// del paquete. Sin esa línea el binario se construye igual y los PDF
    /// simplemente no se abren en la máquina de quien lo recibe.
    #[test]
    fn la_biblioteca_nativa_viaja_en_el_instalador() {
        let config: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tauri.conf.json"),
            )
            .expect("tauri.conf.json"),
        )
        .expect("json válido");

        let recursos = config["bundle"]["resources"]
            .as_object()
            .expect("bundle.resources tiene que declarar qué viaja con la aplicación");

        assert!(
            recursos.keys().any(|origen| origen.contains("pdfium")),
            "el motor de PDF no viaja en el instalador: los PDF no se abrirán tras instalar"
        );
    }

    /// El nombre del producto está escrito en dos sitios y **tienen que
    /// coincidir**.
    ///
    /// En un paquete de Linux el binario va a `/usr/bin` y los recursos a
    /// `/usr/lib/<productName>`, así que la ruta donde se busca la biblioteca
    /// lleva ese nombre dentro. Si alguien renombra el producto en la
    /// configuración y no aquí, el motor de PDF deja de encontrarse **solo en el
    /// paquete instalado**: en desarrollo sigue funcionando, porque ahí se
    /// encuentra por otra vía. Esa es exactamente la clase de defecto que no
    /// aparece hasta que alguien instala de verdad.
    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn el_nombre_del_producto_coincide_con_la_ruta_de_recursos() {
        let config: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tauri.conf.json"),
            )
            .expect("tauri.conf.json"),
        )
        .expect("json válido");

        assert_eq!(
            config["productName"].as_str(),
            Some(super::NOMBRE_DEL_PRODUCTO),
            "productName y NOMBRE_DEL_PRODUCTO discrepan: en un paquete de Linux \
             el motor de PDF no se encontraría"
        );
    }
}
