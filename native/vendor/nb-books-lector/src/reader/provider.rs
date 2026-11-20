//! Contrato de formato: lo que el lector le pide a cualquier documento.
//!
//! Un PDF se pagina por páginas fijas. Un EPUB reflowable no tiene páginas. Un
//! cómic es una secuencia de imágenes y un audiolibro, una línea temporal. Si el
//! lector conociera esas diferencias, cada formato nuevo obligaría a tocarlo
//! entero.
//!
//! Aquí está la frontera: el lector habla con [`DocumentProvider`] y nunca con
//! un formato. Lo que un formato no sabe hacer lo declara en
//! [`ReaderCapabilities`], y **la interfaz se construye a partir de eso**: una
//! función que el formato no soporta no se muestra deshabilitada, se oculta.
//! Mostrar un control de tipografía sobre un cómic es prometer algo que no va a
//! pasar.
//!
//! Contrato: `docs/architecture/reader-contracts.md`, sección 4.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::locator::Locator;
use crate::error::{NbError, NbResult};

/// Posición en los términos del propio formato.
///
/// Es lo que el proveedor entiende y lo que la superficie de render necesita. El
/// [`Locator`] es lo que se guarda; esto es lo que se pinta. La conversión entre
/// ambos es responsabilidad del proveedor, y es justamente lo que impide que el
/// resto del sistema sepa de páginas.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase", tag = "kind", content = "value")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum NativePosition {
    /// Página absoluta, contando desde 1. PDF y cómic.
    Page(u32),
    /// Recurso interno y desplazamiento en caracteres dentro de él. EPUB.
    Fragment { href: String, offset: u32 },
    /// Instante en segundos desde el principio. Audio.
    Time(f64),
}

/// Con cuánta certeza se resolvió un locator.
///
/// **No es informativo, es contractual.** ADR-004 obliga a marcar visiblemente
/// una anotación reanclada de forma aproximada: es preferible una anotación
/// marcada como incierta que una anotación silenciosamente mal situada.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum Precision {
    /// El identificador de fragmento del formato resolvió tal cual.
    Exact,
    /// El fragmento ya no resuelve y se encontró por la cita textual. La
    /// posición es buena, pero el documento cambió.
    Quote,
    /// Ni fragmento ni cita: se usó la progresión. **Hay que avisar al usuario.**
    Approximate,
}

impl Precision {
    /// Indica si el usuario tiene que enterarse de cómo se resolvió.
    ///
    /// Solo el tercer escalón: ahí se ha adivinado, y una anotación colocada por
    /// progresión puede estar en otro párrafo.
    #[must_use]
    pub const fn requires_warning(self) -> bool {
        matches!(self, Self::Approximate)
    }

    /// Indica si la posición **ya no es donde se anotó**.
    ///
    /// Cierto también cuando se encontró por la cita, que es una posición buena.
    /// Se distingue de [`Self::requires_warning`] porque son dos cosas distintas
    /// que la interfaz muestra distinto: una anotación reanclada por cita está
    /// bien situada pero su documento cambió, y el usuario tiene derecho a
    /// saberlo; una reanclada por progresión puede estar en otro párrafo, y eso
    /// se avisa con más fuerza. Marcar solo la segunda dejaría a la primera
    /// indistinguible de una que nunca se movió.
    #[must_use]
    pub const fn is_relocated(self) -> bool {
        !matches!(self, Self::Exact)
    }
}

/// Dónde quedó un locator al resolverlo.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct Resolution {
    pub position: NativePosition,
    pub precision: Precision,
}

/// Lo que se pinta de una posición.
///
/// Dos formas, porque los formatos son dos cosas distintas: un EPUB es marcado
/// que el webview compone, y un PDF o un cómic son imágenes. La imagen viaja
/// como **ruta**, no como bytes: `docs/architecture/data-flows.md`
/// manda que se sirva por el protocolo de assets y no por el canal JSON, que
/// tendría que codificarla en base64 y pasarla por un mensaje.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase", tag = "kind")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum Rendered {
    /// Marcado **ya saneado**: sin scripts, sin recursos remotos y sin nada que
    /// pueda navegar fuera del documento.
    Markup {
        html: String,
        media_type: String,
        /// Lo que el capítulo trae y no se pinta, para que la interfaz lo diga
        /// en lugar de dejar un hueco sin explicación.
        #[serde(default)]
        omitted: Vec<crate::reader::sanitize::OmittedContent>,
    },
    /// Imagen en disco, para servir por el protocolo de assets.
    Image { path: String, media_type: String },
}

/// La narración que trae el propio libro para un capítulo.
///
/// Es lo que describe una superposición de EPUB 3 -Media Overlays-: qué tramo de
/// un audio va con qué trozo del texto. Viaja con la forma del audio preparado de
/// la voz -un archivo y sus marcas por `Locator`- porque para quien escucha es lo
/// mismo: audio que se sigue con el texto. La diferencia es que este lo leyó una
/// persona.
#[derive(Debug, Clone, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct SynchronizedAudio {
    /// El capítulo al que acompaña.
    pub href: String,
    /// El audio, ya extraído a la caché: se pide por el protocolo de assets.
    pub path: String,
    /// Hasta dónde llega el último tramo, en milisegundos.
    #[ts(type = "number")]
    pub duration_ms: u64,
    /// Un tramo por cada `par` de la superposición, en orden.
    ///
    /// Cota: los `par` de un capítulo, que el propio libro trae.
    pub marks: Vec<Marca>,
}

/// Una entrada del índice navegable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct NavigationEntry {
    pub title: String,
    pub locator: Locator,
    /// El índice es un árbol: partes, capítulos, secciones.
    pub children: Vec<NavigationEntry>,
}

/// Estructura navegable del documento.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct Navigation {
    pub entries: Vec<NavigationEntry>,
}

/// Lo que un formato sabe hacer.
///
/// Los seis que nombra el contrato, ni uno más. Cada capacidad añadida aquí es
/// una decisión de interfaz, y añadirlas "por si acaso" produce controles que
/// nadie sabe si funcionan.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct ReaderCapabilities {
    /// Se puede seleccionar texto con el ratón o el teclado.
    pub text_selection: bool,
    /// El formato sabe buscar dentro de sí mismo.
    pub internal_search: bool,
    /// El contenido se re-pagina al cambiar el tamaño de la ventana.
    pub reflow: bool,
    /// Se puede cambiar la tipografía y el espaciado.
    pub typography: bool,
    /// Hay audio sincronizado con el texto.
    pub synchronized_audio: bool,
    /// Se puede sacar texto plano, para búsqueda, accesibilidad e indexación.
    ///
    /// Un PDF escaneado sin OCR responde `false`, y eso **se le dice al
    /// usuario** en lugar de presentarle un documento silenciosamente ilegible
    /// para un lector de pantalla.
    pub text_extraction: bool,
}

/// Lo que el lector le pide a un documento, sea del formato que sea.
pub trait DocumentProvider: Send + Sync {
    /// Tipo de medio que este proveedor sirve.
    fn media_type(&self) -> &str;

    /// Estructura navegable: índice, capítulos, pistas.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentCorrupted`] si el documento no se deja recorrer.
    fn navigation(&self) -> NbResult<Navigation>;

    /// Convierte una posición nativa del formato en un [`Locator`] canónico.
    ///
    /// Es la mitad que **guarda**: lo que produce aquí es lo que acabará en una
    /// anotación o en el progreso, y tiene que sobrevivir a cambiar la
    /// tipografía, el dispositivo y la edición.
    ///
    /// # Errors
    ///
    /// [`NbError::PathNotAllowed`] si la posición no pertenece a este documento,
    /// o [`NbError::DocumentCorrupted`] si no se puede describir.
    fn locator_at(&self, position: &NativePosition) -> NbResult<Locator>;

    /// Resuelve un [`Locator`] a una posición pintable, **con degradación**.
    ///
    /// Es la mitad que **restaura**, y la que hace o deshace la promesa de
    /// ADR-004. El orden de la cascada es fragmento canónico, cita textual y
    /// progresión aproximada, y lo que se devuelve dice por cuál se resolvió.
    ///
    /// Nunca se descarta una anotación en silencio, y nunca se coloca en un
    /// lugar equivocado sin decirlo.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si el locator no pertenece a este
    /// documento, o [`NbError::DocumentCorrupted`] si no hay forma de situarlo
    /// ni siquiera aproximadamente.
    fn resolve(&self, locator: &Locator) -> NbResult<Resolution>;

    /// Texto plano de un rango, para búsqueda, accesibilidad e indexación.
    ///
    /// # Errors
    ///
    /// [`NbError::FormatUnsupported`] si el documento no tiene capa de texto,
    /// que es distinto de tenerla vacía y hay que poder distinguirlo.
    fn text_range(&self, locator: &Locator, len: usize) -> NbResult<String>;

    /// Lo que hay que pintar en una posición.
    ///
    /// Para un formato de marcado, el marcado **ya saneado**: sanear aquí y no
    /// en el webview es lo que hace que la política de contenido sea la segunda
    /// barrera y no la primera.
    ///
    /// # Errors
    ///
    /// [`NbError::PathNotAllowed`] si la posición no es de este formato, o
    /// [`NbError::DocumentCorrupted`] si el contenido no se deja preparar.
    fn render(&self, position: &NativePosition) -> NbResult<Rendered>;

    /// Trocea el documento en fragmentos indexables, cada uno con el locator de
    /// donde empieza.
    ///
    /// Lo trocea **el proveedor** y no la búsqueda porque solo él sabe construir
    /// un locator dentro de su propio formato: un desplazamiento de EPUB, una
    /// página de PDF y una pista de audio no se numeran igual. La búsqueda solo
    /// guarda lo que reciba, y así añadir un formato no obliga a tocarla.
    ///
    /// # Errors
    ///
    /// [`NbError::FormatUnsupported`] si el formato no tiene texto que dar. No
    /// es un fallo: es lo que `capabilities().text_extraction` anticipa, y es lo
    /// que permite marcar el documento como no buscable en lugar de dejarlo con
    /// un índice vacío, indistinguible de uno que nadie ha indexado.
    fn text_chunks(&self, _max_chars: usize) -> NbResult<Vec<(Locator, String)>> {
        Err(NbError::FormatUnsupported)
    }

    /// Tamaño intrínseco de la página que se pinta en esta posición.
    ///
    /// Hace falta **antes** de tener la imagen, para reservar el hueco y no dar
    /// el salto de maquetación. Por eso está aquí y no se deduce de la imagen
    /// rendida: cuando la imagen llega, el salto ya ha ocurrido.
    ///
    /// # Errors
    ///
    /// [`NbError::FormatUnsupported`] si el formato no se pinta como imagen. Un
    /// EPUB no tiene tamaño de página: lo tiene la ventana.
    fn page_size(&self, _position: &NativePosition) -> NbResult<PageSize> {
        Err(NbError::FormatUnsupported)
    }

    /// Capa de texto de la posición, para superponerla al pintado.
    ///
    /// Solo la necesita lo que se pinta como imagen: en un formato de marcado el
    /// texto **es** lo que se pinta, y superponerle otro lo duplicaría para el
    /// lector de pantalla.
    ///
    /// # Errors
    ///
    /// [`NbError::FormatUnsupported`] si el formato no se pinta como imagen.
    /// Que la página no tenga texto no es un error: se devuelve declarada como
    /// ausente, que es distinto de una lista vacía.
    fn text_layer(&self, _position: &NativePosition) -> NbResult<TextLayer> {
        Err(NbError::FormatUnsupported)
    }

    /// La narración del propio libro para un capítulo, si la trae.
    ///
    /// De fábrica ninguna: solo un EPUB 3 con superposiciones la tiene, y un
    /// formato sin ellas se comporta exactamente como antes.
    ///
    /// # Errors
    ///
    /// Los del formato al leer la superposición o su audio.
    fn synchronized_audio(&self, _href: &str) -> NbResult<Option<SynchronizedAudio>> {
        Ok(None)
    }

    /// Locator de una cita que el usuario acaba de seleccionar.
    ///
    /// # Por qué la cita se busca en el documento en lugar de creérsela
    ///
    /// La selección la hace el webview, que es zona no confiable, y la cita es
    /// justo lo que sostiene el segundo escalón de la cascada de ADR-004. Una
    /// cita que no esté en el documento produciría una anotación que no se puede
    /// reanclar nunca, y el usuario no lo sabría hasta perderla. Aquí se busca en
    /// el texto real: si aparece, el locator queda anclado a donde de verdad
    /// está; si no aparece, no hay anotación.
    ///
    /// `hint` es la progresión total donde el usuario cree estar leyendo, y sirve
    /// para desempatar: una frase repetida en dos capítulos ancla a la ocurrencia
    /// más cercana a donde estaba, no a la primera del libro.
    ///
    /// # Errors
    ///
    /// - [`NbError::FormatUnsupported`] si el formato no tiene texto.
    /// - [`NbError::DocumentNotFound`] si la cita no aparece en el documento.
    fn locator_for_quote(&self, _quote: &str, _hint: Option<f64>) -> NbResult<Locator> {
        Err(NbError::FormatUnsupported)
    }

    /// Qué sabe hacer este formato.
    fn capabilities(&self) -> ReaderCapabilities;
}

/// Sabe abrir documentos de un tipo de medio.
///
/// Separado del proveedor porque abrir un documento cuesta —lee el archivo,
/// construye índices— y el registro tiene que poder decir "sé abrir esto" sin
/// abrirlo.
pub trait ProviderFactory: Send + Sync {
    /// Tipo de medio que sabe abrir.
    ///
    /// Devuelve `&str` y no `&'static str` ahora : el tipo de medio
    /// de un proveedor del núcleo se conoce al compilar, pero el de uno que
    /// aporta una extensión sale de su manifiesto y se conoce al instalarla.
    /// Exigir `'static` obligaría a filtrar memoria por cada extensión de
    /// formato para satisfacer al tipo, que es la clase de truco que un
    /// contrato mal puesto arrastra al resto del código.
    fn media_type(&self) -> &str;

    /// Abre un documento.
    ///
    /// # Errors
    ///
    /// Los del formato: [`NbError::FileNotFound`],
    /// [`NbError::DocumentCorrupted`] o [`NbError::FormatUnsupported`].
    fn open(&self, path: &Path) -> NbResult<Box<dyn DocumentProvider>>;
}

/// Registro de proveedores por tipo de medio.
///
/// Es lo que permite que añadir un formato sea añadir un archivo, no tocar el
/// lector. Y lo que permite que **falte** un formato sin que nada se rompa: un
/// tipo de medio sin proveedor responde [`NbError::ComponentUnavailable`], que
/// es exactamente lo que la interfaz necesita para ocultar la función en lugar
/// de ofrecerla rota.
#[derive(Default)]
pub struct ProviderRegistry {
    fabricas: BTreeMap<String, Box<dyn ProviderFactory>>,
}

impl ProviderRegistry {
    /// Crea un registro vacío.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Registra un proveedor. Si ya había uno para ese tipo, lo sustituye.
    pub fn register(&mut self, factory: Box<dyn ProviderFactory>) {
        let tipo = factory.media_type().to_owned();
        if self.fabricas.insert(tipo.clone(), factory).is_some() {
            tracing::warn!(media_type = %tipo, "se sustituyó un proveedor ya registrado");
        }
    }

    /// Indica si hay proveedor para ese tipo de medio.
    #[must_use]
    pub fn supports(&self, media_type: &str) -> bool {
        self.fabricas.contains_key(media_type)
    }

    /// Tipos de medio que se pueden abrir hoy, en orden estable.
    #[must_use]
    pub fn media_types(&self) -> Vec<&str> {
        self.fabricas.keys().map(String::as_str).collect()
    }

    /// Abre un documento con el proveedor que le corresponda.
    ///
    /// # Errors
    ///
    /// [`NbError::ComponentUnavailable`] si no hay proveedor para ese tipo de
    /// medio. Es deliberadamente distinto de [`NbError::FormatUnsupported`]: el
    /// primero dice "esta instalación no puede", el segundo "esto no es un
    /// documento". La interfaz reacciona distinto a cada uno.
    pub fn open(&self, media_type: &str, path: &Path) -> NbResult<Box<dyn DocumentProvider>> {
        let Some(fabrica) = self.fabricas.get(media_type) else {
            tracing::info!(
                media_type,
                "no hay proveedor para este tipo de medio en esta instalación"
            );
            return Err(NbError::ComponentUnavailable);
        };
        fabrica.open(path)
    }
}

/// Un fragmento de texto con su sitio en la página.
///
/// Las coordenadas van **normalizadas de 0 a 1** sobre el tamaño de la página, no
/// en píxeles: la interfaz escala la imagen y la superposición tiene que escalar
/// con ella. En píxeles, cambiar el zoom descolocaría el texto respecto de lo que
/// hay debajo, que es justo lo que rompe la selección y confunde a un lector de
/// pantalla.
///
/// El origen es la esquina **superior** izquierda, como en el marcado, y no la
/// inferior izquierda de PDF: la conversión se hace aquí una vez, y no en cada
/// consumidor.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct TextSpan {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Qué se puede decir de la accesibilidad de una página.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum TextLayerStatus {
    /// Tiene texto real: se puede leer, seleccionar, buscar e indexar.
    Available,
    /// Es una imagen sin texto: un escaneado sin OCR.
    ///
    /// **Se declara**, no se disimula. Presentar un documento silenciosamente
    /// ilegible para una tecnología de asistencia es peor que decir que no se
    /// puede leer, porque quien lo necesita pierde el tiempo intentándolo.
    Missing,
}

/// La capa de texto de una página.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct TextLayer {
    pub page: u32,
    pub status: TextLayerStatus,
    /// Fragmentos en orden de lectura, tal y como los da el documento.
    pub spans: Vec<TextSpan>,
}

/// Tamaño intrínseco de una página que se pinta como imagen.
///
/// En píxeles del original, no del rendido: es el dato con el que la interfaz
/// calcula cualquier ajuste, y el único que no cambia cuando el usuario redimensiona.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct PageSize {
    pub width: u32,
    pub height: u32,
}

/// Cómo encaja una página dentro de la ventana.
///
/// Vive aquí y no en el proveedor de cómic porque el PDF tiene el mismo problema
/// y la misma respuesta: son los dos formatos que se pintan como imagen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum FitMode {
    /// La página ocupa todo el ancho. Es el ajuste natural de un cómic largo:
    /// se lee bajando, y el ancho es lo que se quiere aprovechar.
    #[default]
    Width,
    /// La página cabe entera de alto, sin desplazamiento vertical.
    Height,
    /// La página cabe entera. Es `Width` o `Height`, el que sea más restrictivo.
    Page,
    /// Tamaño original, sin escalar.
    Original,
}

impl FitMode {
    /// Calcula el tamaño con el que pintar una página dentro de una ventana.
    ///
    /// El cálculo está en Rust y no en la interfaz porque es el mismo para los
    /// dos formatos que lo necesitan, y porque una regla de encaje duplicada en
    /// dos sitios se convierte en dos reglas de encaje distintas.
    ///
    /// Nunca **amplía** más allá del original salvo que se pida a propósito con
    /// `Width` o `Height`: escalar un escaneo pequeño hasta llenar un monitor de
    /// cuatro mil píxeles no lo hace más legible, lo hace más borroso.
    #[must_use]
    pub fn apply(self, page: PageSize, viewport: PageSize) -> PageSize {
        if page.width == 0 || page.height == 0 || viewport.width == 0 || viewport.height == 0 {
            return page;
        }

        let ancho = f64::from(page.width);
        let alto = f64::from(page.height);
        let escala = match self {
            Self::Original => 1.0,
            Self::Width => f64::from(viewport.width) / ancho,
            Self::Height => f64::from(viewport.height) / alto,
            Self::Page => {
                (f64::from(viewport.width) / ancho).min(f64::from(viewport.height) / alto)
            }
        };

        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        PageSize {
            width: ((ancho * escala).round() as u32).max(1),
            height: ((alto * escala).round() as u32).max(1),
        }
    }
}

/// Dónde está cada fragmento dentro del audio.
#[derive(Debug, Clone, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/", rename = "AudioMark")]
pub struct Marca {
    #[ts(type = "number")]
    pub start_ms: u64,
    #[ts(type = "number")]
    pub end_ms: u64,
    pub locator: Locator,
}
