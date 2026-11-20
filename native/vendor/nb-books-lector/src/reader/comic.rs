//! Proveedor de cómic: una secuencia de imágenes dentro de un contenedor.
//!
//! Es el formato más simple de los tres y el que más superficie hostil tiene: un
//! CBZ es un ZIP con imágenes, y un ZIP es donde viven el recorrido de
//! directorios y las bombas de descompresión. Las defensas no están aquí: están
//! en `crate::zip`, dentro del lector, de modo que **no hay forma de abrir un
//! cómic saltándoselas**.
//!
//! # Qué es una posición en un cómic
//!
//! Una página, y nada más. No hay texto que citar, así que la cascada de ADR-004
//! se queda en dos escalones: la página, y la progresión. Eso no es una carencia
//! del modelo, es lo que el formato da de sí, y decirlo es mejor que fingir una
//! precisión que no existe.
//!
//! Contratos: `docs/architecture/reader-contracts.md` y
//! `docs/audit/threat-model.md`, sección 3.1.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::locator::{Locations, Locator};
use super::provider::{
    DocumentProvider, NativePosition, Navigation, NavigationEntry, PageSize, Precision,
    ProviderFactory, ReaderCapabilities, Rendered, Resolution,
};
use crate::error::{NbError, NbResult};
use crate::zip::Archive;

/// Tipo de medio que sirve este proveedor.
pub const MEDIA_TYPE: &str = "application/vnd.comicbook+zip";

/// Como en el PDF: la publicación es el recurso.
const RECURSO: &str = "/";

/// Longitud del prefijo `sha256:` de la identidad por contenido.
const PREFIJO: usize = "sha256:".len();

/// Extensiones de imagen que se consideran páginas.
///
/// Lista cerrada: un contenedor puede traer un `README.txt`, un `ComicInfo.xml`
/// o basura del sistema de archivos, y ninguna de esas cosas es una página.
const IMAGENES: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp"];

/// Un cómic abierto.
pub struct ComicDocument {
    /// Entradas que son páginas, en **orden natural del nombre**.
    ///
    /// Del nombre y no del contenedor: el orden dentro de un ZIP es el que le
    /// dio quien lo comprimió, y en un cómic las páginas se nombran para
    /// ordenarse (`001.jpg`, `002.jpg`). Fiarse del orden del archivo produce
    /// cómics que empiezan por la página veinte.
    paginas: Vec<String>,
    /// El contenedor abierto, con su índice ya leído y validado.
    ///
    /// Se conserva en lugar de reabrirlo en cada página porque leer el índice
    /// cuesta lo mismo para una página que para trescientas, y un cómic se lee
    /// página a página. El `Mutex` está porque leer una entrada mueve el cursor
    /// del archivo y el contrato del proveedor es `&self`.
    contenedor: Mutex<Archive>,
    /// Identidad por contenido, calculada una sola vez.
    ///
    /// Una sola vez y no por página: recorrer un cómic de 400 MB para nombrar
    /// cada archivo de caché convertiría pasar de página en una lectura entera
    /// del documento.
    identidad: String,
    cache: PathBuf,
}

impl ComicDocument {
    /// Abre un cómic.
    ///
    /// # Errors
    ///
    /// - [`NbError::FileNotFound`] si la ruta no existe.
    /// - [`NbError::PathNotAllowed`] si alguna entrada del contenedor intenta
    ///   escapar del destino.
    /// - [`NbError::DocumentCorrupted`] si el contenedor no se deja abrir o si
    ///   no tiene ni una imagen: un cómic sin páginas no es un cómic.
    pub fn open(path: &Path, cache_dir: &Path) -> NbResult<Self> {
        // Aquí es donde se aplican la validación de rutas internas y los límites
        // de descompresión: el contenedor se rechaza entero si algo no cuadra.
        let contenedor = Archive::open(path)?;

        let mut paginas: Vec<String> = contenedor
            .entries()
            .iter()
            .map(|e| e.name.clone())
            .filter(|nombre| es_imagen(nombre))
            .collect();

        if paginas.is_empty() {
            tracing::warn!("el contenedor no tiene ninguna imagen");
            return Err(NbError::DocumentCorrupted);
        }

        // Orden natural: `10.jpg` va después de `9.jpg`, no antes.
        paginas.sort_by(|a, b| orden_natural(a, b));

        let identidad = crate::library::hash_file(path)
            .map(|(h, _)| h.as_str()[PREFIJO..PREFIJO + 16].to_owned())
            .unwrap_or_else(|_| "desconocido".to_owned());

        Ok(Self {
            paginas,
            contenedor: Mutex::new(contenedor),
            identidad,
            cache: cache_dir.to_path_buf(),
        })
    }

    /// Número de páginas.
    #[must_use]
    pub fn page_count(&self) -> u16 {
        u16::try_from(self.paginas.len()).unwrap_or(u16::MAX)
    }

    /// Extrae una página a la caché y devuelve su ruta.
    ///
    /// A disco y no a memoria porque la imagen va al webview por el protocolo de
    /// assets, y porque un cómic de trescientas páginas a color no cabe en
    /// memoria y no hace falta que quepa.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentNotFound`] si la página no existe, o
    /// [`NbError::StorageFailure`] si no se puede escribir la caché.
    pub fn page_image(&self, page: u16) -> NbResult<PathBuf> {
        let indice = page.checked_sub(1).ok_or(NbError::DocumentNotFound)? as usize;
        let interna = self.paginas.get(indice).ok_or(NbError::DocumentNotFound)?;

        let extension = Path::new(interna)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("bin");

        let destino = self
            .cache
            .join(format!("{}-{page:05}.{extension}", self.identidad));

        if destino.exists() {
            return Ok(destino);
        }

        let bytes = {
            let mut contenedor = self
                .contenedor
                .lock()
                .map_err(|_| NbError::DocumentCorrupted)?;
            contenedor.read(interna)?
        };

        // Atómica: `destino.exists()` unas líneas más arriba es lo que decide si
        // la página se reutiliza, y con una escritura directa otro hilo podría
        // encontrarla creada y a medio llenar.
        crate::paths::write_atomic(&destino, |temporal| {
            std::fs::write(temporal, &bytes).map_err(|_| NbError::StorageFailure)
        })?;

        Ok(destino)
    }

    /// Tamaño intrínseco de una página, leído de la cabecera de la imagen.
    ///
    /// De la cabecera y no decodificando: para encajar la página hacen falta dos
    /// números, y decodificar un JPEG de veinte megapíxeles para averiguarlos
    /// costaría más que pintarlo. La interfaz necesita esto **antes** de tener
    /// la imagen, para reservar el hueco y no dar el salto de maquetación.
    ///
    /// # Errors
    ///
    /// - [`NbError::DocumentNotFound`] si la página no existe.
    /// - [`NbError::FormatUnsupported`] si la imagen es de un tipo cuyo tamaño
    ///   este lector no sabe leer. Se dice, en lugar de devolver un tamaño
    ///   inventado con el que la página se pintaría deformada.
    pub fn page_dimensions(&self, page: u16) -> NbResult<PageSize> {
        let indice = page.checked_sub(1).ok_or(NbError::DocumentNotFound)? as usize;
        let interna = self.paginas.get(indice).ok_or(NbError::DocumentNotFound)?;

        let bytes = {
            let mut contenedor = self
                .contenedor
                .lock()
                .map_err(|_| NbError::DocumentCorrupted)?;
            contenedor.read(interna)?
        };

        image_size(&bytes).ok_or(NbError::FormatUnsupported)
    }
}

impl DocumentProvider for ComicDocument {
    fn media_type(&self) -> &str {
        MEDIA_TYPE
    }

    fn navigation(&self) -> NbResult<Navigation> {
        let entries = (1..=self.page_count())
            .map(|pagina| {
                Ok(NavigationEntry {
                    title: format!("Página {pagina}"),
                    locator: self.locator_at(&NativePosition::Page(u32::from(pagina)))?,
                    children: Vec::new(),
                })
            })
            .collect::<NbResult<Vec<_>>>()?;

        Ok(Navigation { entries })
    }

    fn locator_at(&self, position: &NativePosition) -> NbResult<Locator> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };
        let pagina = u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?;
        if pagina == 0 || pagina > self.page_count() {
            return Err(NbError::PathNotAllowed);
        }

        Locator::new(
            RECURSO,
            MEDIA_TYPE,
            Locations {
                fragments: vec![format!("page={pagina}")],
                progression: Some(0.0),
                total_progression: Some(f64::from(pagina - 1) / f64::from(self.page_count())),
                position: Some(u32::from(pagina)),
            },
            // Sin texto no hay cita, y sin cita no hay segundo escalón. Es lo que
            // el formato da de sí; inventar una cita sería peor.
            None,
        )
        .map(|l| l.with_title(&format!("Página {pagina}")))
    }

    fn resolve(&self, locator: &Locator) -> NbResult<Resolution> {
        if let Some(pagina) = locator
            .locations
            .position
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p >= 1 && *p <= self.page_count())
        {
            return Ok(Resolution {
                position: NativePosition::Page(u32::from(pagina)),
                precision: Precision::Exact,
            });
        }

        // La página ya no existe: el cómic se recortó o es otra edición. Queda la
        // progresión, y se marca.
        if let Some(total) = locator.locations.total_progression {
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let pagina = ((total * f64::from(self.page_count())) as u16 + 1).min(self.page_count());
            return Ok(Resolution {
                position: NativePosition::Page(u32::from(pagina)),
                precision: Precision::Approximate,
            });
        }

        Err(NbError::DocumentNotFound)
    }

    fn text_range(&self, _locator: &Locator, _len: usize) -> NbResult<String> {
        // Un cómic es imagen. Decirlo permite a la búsqueda marcarlo como no
        // indexable y a la interfaz explicar por qué, en lugar de devolver vacío
        // y que parezca un documento sin contenido.
        Err(NbError::FormatUnsupported)
    }

    fn render(&self, position: &NativePosition) -> NbResult<Rendered> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };
        let ruta = self.page_image(u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?)?;

        let media_type = match Path::new(&ruta)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
        {
            "png" => "image/png",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "avif" => "image/avif",
            "bmp" => "image/bmp",
            _ => "image/jpeg",
        };

        Ok(Rendered::Image {
            path: ruta.to_string_lossy().into_owned(),
            media_type: media_type.to_owned(),
        })
    }

    fn page_size(&self, position: &NativePosition) -> NbResult<PageSize> {
        let NativePosition::Page(pagina) = position else {
            return Err(NbError::PathNotAllowed);
        };
        self.page_dimensions(u16::try_from(*pagina).map_err(|_| NbError::PathNotAllowed)?)
    }

    fn capabilities(&self) -> ReaderCapabilities {
        ReaderCapabilities {
            // Todo falso, y eso es información: la interfaz de un cómic no
            // muestra controles de tipografía ni caja de búsqueda. Ofrecerlos
            // sería prometer algo que no va a pasar.
            text_selection: false,
            internal_search: false,
            reflow: false,
            typography: false,
            synchronized_audio: false,
            text_extraction: false,
        }
    }
}

/// Fábrica del proveedor de cómic.
pub struct ComicFactory {
    cache: PathBuf,
}

impl ComicFactory {
    /// Crea la fábrica con el directorio donde extraer las páginas.
    #[must_use]
    pub fn new(cache_dir: PathBuf) -> Self {
        Self { cache: cache_dir }
    }
}

impl ProviderFactory for ComicFactory {
    fn media_type(&self) -> &'static str {
        MEDIA_TYPE
    }

    fn open(&self, path: &Path) -> NbResult<Box<dyn DocumentProvider>> {
        Ok(Box::new(ComicDocument::open(path, &self.cache)?))
    }
}

/// Metadatos de un cómic: los de `ComicInfo.xml` si lo trae, y su primera
/// página como portada.
///
/// `ComicInfo.xml` es la convención de facto de los CBZ (la escriben ComicRack,
/// Kavita y Komga). Se leen los campos que el catálogo sabe guardar; el resto se
/// ignora. Sin ese archivo solo hay portada, que también es algo.
///
/// # Errors
///
/// Los de [`Archive::open`], o [`NbError::DocumentCorrupted`] si no hay ninguna
/// imagen.
pub fn read_metadata(path: &Path) -> NbResult<crate::epub::EpubMetadata> {
    let mut contenedor = Archive::open(path)?;
    let mut imagenes: Vec<String> = contenedor
        .entries()
        .iter()
        .map(|e| e.name.clone())
        .filter(|n| es_imagen(n))
        .collect();
    imagenes.sort_by(|a, b| orden_natural(a, b));
    let portada = imagenes
        .into_iter()
        .next()
        .ok_or(NbError::DocumentCorrupted)?;

    let interno = contenedor
        .entries()
        .iter()
        .map(|e| e.name.clone())
        .find(|n| {
            n.rsplit('/')
                .next()
                .is_some_and(|b| b.eq_ignore_ascii_case("ComicInfo.xml"))
        });
    let mut datos = match interno {
        Some(nombre) => contenedor
            .read(&nombre)
            .map(|bytes| comic_info(&bytes))
            .unwrap_or_default(),
        None => crate::epub::EpubMetadata::default(),
    };
    datos.cover_path = Some(portada);
    Ok(datos)
}

/// Lee los campos de `ComicInfo.xml` que tienen sitio en el catálogo.
fn comic_info(bytes: &[u8]) -> crate::epub::EpubMetadata {
    use crate::epub::{Creador, Papel};
    use quick_xml::events::Event;

    let mut datos = crate::epub::EpubMetadata::default();
    let mut lector = quick_xml::Reader::from_reader(bytes);
    let mut actual: Option<String> = None;
    let mut buf = Vec::new();
    let (mut ano, mut mes): (Option<String>, Option<String>) = (None, None);
    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                actual = Some(String::from_utf8_lossy(e.local_name().as_ref()).into_owned());
            }
            Ok(Event::Text(texto)) => {
                let Some(campo) = actual.as_deref() else {
                    continue;
                };
                let valor = texto
                    .decode()
                    .map(|v| v.trim().to_owned())
                    .unwrap_or_default();
                if valor.is_empty() {
                    continue;
                }
                let personas = |papel: Papel, datos: &mut crate::epub::EpubMetadata| {
                    for nombre in valor.split(',').map(str::trim).filter(|n| !n.is_empty()) {
                        datos.creators.push(Creador {
                            name: nombre.to_owned(),
                            role: papel,
                        });
                    }
                };
                match campo {
                    "Title" => datos.title = Some(valor.clone()),
                    "Series" => datos.series = Some(valor.clone()),
                    "Number" => datos.series_index = Some(valor.clone()),
                    "Summary" => datos.description = Some(valor.clone()),
                    "Publisher" => datos.publisher = Some(valor.clone()),
                    "LanguageISO" => datos.language = Some(valor.clone()),
                    "Year" => ano = Some(valor.clone()),
                    "Month" => mes = Some(valor.clone()),
                    "Writer" => personas(Papel::Autor, &mut datos),
                    "Penciller" | "Inker" | "Colorist" | "CoverArtist" => {
                        personas(Papel::Ilustrador, &mut datos);
                    }
                    "Editor" => personas(Papel::Editor, &mut datos),
                    "Translator" => personas(Papel::Traductor, &mut datos),
                    "Genre" => datos.subjects.extend(
                        valor
                            .split(',')
                            .map(str::trim)
                            .filter(|g| !g.is_empty())
                            .map(str::to_owned),
                    ),
                    _ => {}
                }
            }
            Ok(Event::End(_)) => actual = None,
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    // Sin título propio, un número suelto se llama por su serie.
    if datos.title.is_none() {
        datos.title = datos.series.clone();
    }
    let ano = ano.filter(|a| a.len() == 4 && a.chars().all(|c| c.is_ascii_digit()));
    let mes = mes
        .and_then(|m| m.parse::<u8>().ok())
        .filter(|m| (1..=12).contains(m));
    datos.date = match (ano, mes) {
        (Some(a), Some(m)) => Some(format!("{a}-{m:02}")),
        (Some(a), None) => Some(a),
        (None, _) => None,
    };
    datos
}

fn es_imagen(nombre: &str) -> bool {
    // Los archivos ocultos y los metadatos que deja macOS al comprimir no son
    // páginas, por mucho que su extensión lo parezca.
    let base = nombre.rsplit('/').next().unwrap_or(nombre);
    if base.starts_with('.') || nombre.contains("__MACOSX/") {
        return false;
    }

    Path::new(nombre)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .is_some_and(|e| IMAGENES.contains(&e.as_str()))
}

/// Compara dos nombres tratando los números como números.
///
/// Sin esto, `10.jpg` va antes que `9.jpg` y el cómic se lee desordenado a
/// partir de la página diez. Es el defecto más aburrido de este formato y el que
/// más se nota.
fn orden_natural(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ia = a.chars().peekable();
    let mut ib = b.chars().peekable();

    loop {
        match (ia.peek().copied(), ib.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(ca), Some(cb)) => {
                if ca.is_ascii_digit() && cb.is_ascii_digit() {
                    let na = tomar_numero(&mut ia);
                    let nb = tomar_numero(&mut ib);
                    match na.cmp(&nb) {
                        std::cmp::Ordering::Equal => {}
                        otro => return otro,
                    }
                } else {
                    let (ca, cb) = (ca.to_ascii_lowercase(), cb.to_ascii_lowercase());
                    match ca.cmp(&cb) {
                        std::cmp::Ordering::Equal => {
                            ia.next();
                            ib.next();
                        }
                        otro => return otro,
                    }
                }
            }
        }
    }
}

fn tomar_numero(iter: &mut std::iter::Peekable<std::str::Chars<'_>>) -> u64 {
    let mut valor: u64 = 0;
    while let Some(c) = iter.peek().copied() {
        if !c.is_ascii_digit() {
            break;
        }
        // Un número absurdamente largo en un nombre de archivo no puede
        // desbordar: se satura y se ordena como muy grande.
        valor = valor
            .saturating_mul(10)
            .saturating_add(u64::from(c as u8 - b'0'));
        iter.next();
    }
    valor
}

/// Lee el tamaño de una imagen de su cabecera, sin decodificarla.
///
/// Público porque la prueba comprueba los cinco formatos y meter uno
/// de cada dentro de un contenedor solo para eso sería un fixture por byte.
///
/// Cada formato lo guarda en un sitio distinto y ninguno de ellos exige leer los
/// píxeles. AVIF no está: su cabecera vive dentro de un contenedor ISOBMFF y
/// sacarla de ahí es un analizador entero, así que se declara desconocido en
/// lugar de adivinarlo.
#[must_use]
pub fn image_size(bytes: &[u8]) -> Option<PageSize> {
    let u32_be = |i: usize| -> Option<u32> {
        Some(u32::from_be_bytes(bytes.get(i..i + 4)?.try_into().ok()?))
    };
    let u16_le = |i: usize| -> Option<u32> {
        Some(u32::from(u16::from_le_bytes(
            bytes.get(i..i + 2)?.try_into().ok()?,
        )))
    };

    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(PageSize {
            width: u32_be(16)?,
            height: u32_be(20)?,
        });
    }

    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some(PageSize {
            width: u16_le(6)?,
            height: u16_le(8)?,
        });
    }

    if bytes.starts_with(b"BM") {
        // Cabecera de información de Windows: ancho y alto con signo, y el alto
        // negativo significa filas de arriba abajo.
        let ancho = i32::from_le_bytes(bytes.get(18..22)?.try_into().ok()?);
        let alto = i32::from_le_bytes(bytes.get(22..26)?.try_into().ok()?);
        return Some(PageSize {
            width: u32::try_from(ancho).ok()?,
            height: u32::try_from(alto.abs()).ok()?,
        });
    }

    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return match bytes.get(12..16)? {
            b"VP8 " => Some(PageSize {
                width: u16_le(26)? & 0x3fff,
                height: u16_le(28)? & 0x3fff,
            }),
            b"VP8L" => {
                let empaquetado = u32::from_le_bytes(bytes.get(21..25)?.try_into().ok()?);
                Some(PageSize {
                    width: (empaquetado & 0x3fff) + 1,
                    height: ((empaquetado >> 14) & 0x3fff) + 1,
                })
            }
            // VP8X guarda ancho y alto menos uno, en tres bytes cada uno.
            b"VP8X" => Some(PageSize {
                width: u24_le(bytes, 24)? + 1,
                height: u24_le(bytes, 27)? + 1,
            }),
            _ => None,
        };
    }

    if bytes.starts_with(b"\xff\xd8") {
        return jpeg(bytes);
    }

    None
}

fn u24_le(bytes: &[u8], i: usize) -> Option<u32> {
    let t = bytes.get(i..i + 3)?;
    Some(u32::from(t[0]) | (u32::from(t[1]) << 8) | (u32::from(t[2]) << 16))
}

/// Recorre los segmentos de un JPEG hasta el que declara el tamaño.
///
/// Hay que recorrerlos porque el tamaño no está en una posición fija: va en el
/// marcador de inicio de fotograma, que puede estar detrás de los datos de
/// color, de miniaturas y de metadatos de cámara.
fn jpeg(bytes: &[u8]) -> Option<PageSize> {
    let mut i = 2;
    // `i + 8 < len` y no `i + 9`: el marcador de tamaño ocupa nueve bytes desde
    // `i`, o sea hasta `i + 8` incluido. Con `i + 9` no se leería un JPEG cuyo
    // marcador fuese lo último del archivo.
    while i + 8 < bytes.len() {
        if bytes[i] != 0xff {
            i += 1;
            continue;
        }

        let marcador = bytes[i + 1];

        // Relleno entre segmentos: la ley del formato permite repetir 0xff.
        if marcador == 0xff {
            i += 1;
            continue;
        }

        // Marcadores sin campo de longitud. Leerles uno desalinearía el resto
        // del recorrido y devolvería un tamaño de otro sitio del archivo.
        if marcador == 0x01 || (0xd0..=0xd9).contains(&marcador) {
            i += 2;
            continue;
        }
        // Inicio de fotograma, en cualquiera de sus variantes; se excluyen los
        // que reutilizan el rango para otras cosas.
        if (0xc0..=0xcf).contains(&marcador) && !matches!(marcador, 0xc4 | 0xc8 | 0xcc) {
            return Some(PageSize {
                height: u32::from(u16::from_be_bytes([bytes[i + 5], bytes[i + 6]])),
                width: u32::from(u16::from_be_bytes([bytes[i + 7], bytes[i + 8]])),
            });
        }

        let longitud = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if longitud < 2 {
            return None;
        }
        i += 2 + longitud;
    }
    None
}

#[cfg(test)]
mod pruebas {
    use super::comic_info;
    use crate::epub::Papel;

    #[test]
    fn comic_info_da_titulo_serie_autores_y_fecha() {
        let datos = comic_info(
            br#"<?xml version="1.0"?><ComicInfo><Title>Un sueno</Title><Series>Little Nemo</Series>
            <Number>3</Number><Writer>Winsor McCay</Writer><Penciller>Winsor McCay</Penciller>
            <Year>1905</Year><Month>10</Month><LanguageISO>en</LanguageISO>
            <Genre>Fantasy, Strip</Genre></ComicInfo>"#,
        );
        assert_eq!(datos.title.as_deref(), Some("Un sueno"));
        assert_eq!(datos.series.as_deref(), Some("Little Nemo"));
        assert_eq!(datos.series_index.as_deref(), Some("3"));
        assert_eq!(datos.date.as_deref(), Some("1905-10"));
        assert_eq!(datos.language.as_deref(), Some("en"));
        assert_eq!(datos.subjects, vec!["Fantasy", "Strip"]);
        assert_eq!(datos.creators.len(), 2);
        assert_eq!(datos.creators[0].role, Papel::Autor);
        assert_eq!(datos.creators[1].role, Papel::Ilustrador);
    }

    #[test]
    fn un_numero_sin_titulo_se_llama_por_su_serie() {
        let datos =
            comic_info(b"<ComicInfo><Series>Little Nemo</Series><Year>19x5</Year></ComicInfo>");
        assert_eq!(datos.title.as_deref(), Some("Little Nemo"));
        assert_eq!(datos.date, None);
    }

    #[test]
    fn un_comic_info_roto_no_tumba_nada() {
        let datos = comic_info(b"<ComicInfo><Title>sin cerrar");
        assert!(datos.creators.is_empty());
    }
}
