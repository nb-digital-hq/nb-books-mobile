//! Lectura de los metadatos internos de un EPUB.
//!
//! Un EPUB declara su título, sus autores, su idioma y sus identificadores en un
//! archivo OPF que el contenedor señala. Extraerlos es lo que convierte "el
//! nombre del archivo" en un catálogo de verdad.
//!
//! # El analizador no resuelve entidades externas
//!
//! El corpus trae `entidad-externa.epub`, cuyo OPF declara una entidad que
//! apunta a `/etc/passwd`. Un analizador que la resolviera leería ese archivo y
//! lo metería en el catálogo del usuario, y de ahí a una exportación o a una
//! sincronización. Aquí no se resuelve ninguna entidad externa, y hay una prueba
//! que lo comprueba contra ese archivo concreto.
//!
//! Contratos: `docs/architecture/metadata-model.md` y
//! `docs/audit/threat-model.md`.

use std::path::Path;

use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;

use crate::error::{NbError, NbResult};
use crate::zip::Archive;

/// Ruta fija que la especificación de EPUB obliga a tener.
const CONTENEDOR: &str = "META-INF/container.xml";

/// Tope de texto que se acepta de un solo campo.
///
/// Un título de diez megabytes no es un título: es un intento de llenar la base
/// de datos con un solo documento.
const MAX_CAMPO: usize = 4 * 1024;

/// Quién participó en el libro, y **con qué papel**.
///
/// # Por qué el papel no se supone
///
/// Antes se leían `dc:creator` y `dc:contributor` en la misma lista y
/// todos se enlazaban como **autores**. En el corpus real eso llenó el panel de
/// autores de herramientas: Calibre estampa
/// `<dc:contributor opf:role="bkp">calibre (x.y.z)</dc:contributor>` en cada
/// EPUB que produce, así que sus versiones aparecían entre los autores con más
/// obras de la biblioteca, por delante de cualquier persona.
///
/// El papel viene declarado en el propio archivo -`opf:role`, con los códigos de
/// relator de MARC-, así que no hay que adivinarlo: hay que leerlo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Creador {
    pub name: String,
    pub role: Papel,
}

/// Los papeles que el catálogo sabe guardar.
///
/// Es la misma lista cerrada que `edition_contributors.role` en V2. Lo que no
/// encaja en ella **no se guarda**: un productor de libro -`bkp`- no es alguien
/// que participara en la obra, es la herramienta que la empaquetó, y meterlo
/// como persona ensucia la biblioteca de quien la usa.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Papel {
    Autor,
    Editor,
    Traductor,
    Ilustrador,
}

impl Papel {
    /// El papel que declara un `opf:role`, o `None` si no es de los cuatro.
    ///
    /// Los códigos son los de relator de MARC, que es lo que usa EPUB.
    fn de_codigo(codigo: &str) -> Option<Self> {
        match codigo.trim().to_ascii_lowercase().as_str() {
            "aut" | "cre" => Some(Self::Autor),
            "edt" => Some(Self::Editor),
            "trl" => Some(Self::Traductor),
            "ill" => Some(Self::Ilustrador),
            _ => None,
        }
    }

    /// Cómo se llama en el catálogo.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Autor => "author",
            Self::Editor => "editor",
            Self::Traductor => "translator",
            Self::Ilustrador => "illustrator",
        }
    }
}

/// Metadatos leídos del propio documento.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EpubMetadata {
    pub title: Option<String>,
    /// Quién participó, con su papel y en el orden en que aparecen.
    pub creators: Vec<Creador>,
    pub language: Option<String>,
    pub publisher: Option<String>,
    /// Fecha tal y como venga; se normaliza al guardarla.
    pub date: Option<String>,
    /// Identificadores externos con su esquema, cuando lo declaran.
    pub identifiers: Vec<(String, String)>,
    pub subjects: Vec<String>,
    /// Ruta interna de la portada dentro del contenedor.
    pub cover_path: Option<String>,
    /// La serie, de `calibre:series` (EPUB 2) o `belongs-to-collection` (EPUB 3).
    pub series: Option<String>,
    /// Su número dentro de la serie, como texto: "1", "2.5".
    pub series_index: Option<String>,
    /// La sinopsis, de `dc:description`, sin el marcado que algunos traen dentro.
    pub description: Option<String>,
}

/// Lee los metadatos internos de un EPUB.
///
/// # Errors
///
/// - [`NbError::FileNotFound`] si la ruta no existe.
/// - [`NbError::DocumentCorrupted`] si el contenedor no se puede abrir, si le
///   falta el archivo que la especificación exige, o si el XML está mal formado.
/// - [`NbError::PathNotAllowed`] si alguna entrada del contenedor intenta
///   escapar.
pub fn read_metadata(path: &Path) -> NbResult<EpubMetadata> {
    let mut contenedor = Archive::open(path)?;
    let ruta_opf = ruta_del_paquete_de(&mut contenedor)?;

    let opf = contenedor.read_text(&ruta_opf)?;
    let mut metadatos = leer_paquete(&opf)?;

    // La portada se declara relativa al OPF, no a la raíz del contenedor.
    metadatos.cover_path = metadatos
        .cover_path
        .and_then(|href| resolver_relativo(&ruta_opf, &href))
        .filter(|ruta| contenedor.contains(ruta));

    Ok(metadatos)
}

/// Localiza y valida la ruta del paquete de un contenedor ya abierto.
///
/// # Errors
///
/// [`NbError::DocumentCorrupted`] si el contenedor no declara paquete, o
/// [`NbError::PathNotAllowed`] si la ruta que declara intenta escapar: sale del
/// propio archivo, así que es entrada no confiable como cualquier otra.
pub fn ruta_del_paquete_de(contenedor: &mut Archive) -> NbResult<String> {
    let ruta = ruta_del_paquete(&contenedor.read_text(CONTENEDOR)?)?;
    crate::security::validate_archive_entry(&ruta)?;
    Ok(ruta)
}

/// Extrae la ruta del paquete OPF que declara el contenedor.
fn ruta_del_paquete(xml: &str) -> NbResult<String> {
    let mut lector = preparar(xml);
    let mut buf = Vec::new();

    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Empty(e) | Event::Start(e)) if local(e.name().as_ref()) == b"rootfile" => {
                if let Some(ruta) = atributo(&e, b"full-path") {
                    return Ok(ruta);
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(NbError::DocumentCorrupted),
            _ => {}
        }
        buf.clear();
    }

    tracing::warn!("el contenedor no declara ningún paquete");
    Err(NbError::DocumentCorrupted)
}

/// Lee el paquete OPF.
#[allow(clippy::too_many_lines)]
fn leer_paquete(xml: &str) -> NbResult<EpubMetadata> {
    let mut lector = preparar(xml);
    let mut buf = Vec::new();
    let mut metadatos = EpubMetadata::default();

    // Qué elemento se está leyendo, con qué esquema, y el texto acumulado.
    //
    // Se acumula en lugar de tomar el primer trozo porque el analizador parte el
    // texto en cada referencia a entidad: "Marx &amp; Engels" llega en tres
    // eventos, y quedarse con el primero daría "Marx".
    let mut campo: Option<Vec<u8>> = None;
    let mut esquema: Option<String> = None;
    let mut papel: Option<String> = None;
    let mut propiedad: Option<String> = None;
    let mut acumulado = String::new();
    // Una entidad que no es de las cinco predefinidas invalida el campo entero.
    let mut contaminado = false;

    // La portada se declara de dos formas según la versión de EPUB, y hay
    // archivos que usan las dos o ninguna.
    let mut id_portada: Option<String> = None;
    let mut manifiesto: Vec<(String, String, Option<String>)> = Vec::new();

    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                esquema = atributo(&e, b"scheme");
                papel = atributo(&e, b"role");
                // EPUB 3: <meta property="belongs-to-collection">Serie</meta> y
                // <meta refines="…" property="group-position">2</meta>.
                propiedad = atributo(&e, b"property");
                campo = Some(local(e.name().as_ref()).to_vec());
                acumulado.clear();
                contaminado = false;
            }
            Ok(Event::Empty(e)) => {
                let nombre_completo = e.name();
                let nombre = local(nombre_completo.as_ref());
                if nombre == b"meta" {
                    // EPUB 2: <meta name="cover" content="id-de-la-portada"/>
                    match atributo(&e, b"name").as_deref() {
                        Some("cover") => id_portada = atributo(&e, b"content"),
                        // La serie como la escribe Calibre, que es como la trae
                        // casi todo el corpus.
                        Some("calibre:series") if metadatos.series.is_none() => {
                            metadatos.series = atributo(&e, b"content")
                                .map(|v| recortar(&v))
                                .filter(|v| !v.is_empty());
                        }
                        Some("calibre:series_index") if metadatos.series_index.is_none() => {
                            metadatos.series_index = atributo(&e, b"content")
                                .map(|v| recortar(&v))
                                .filter(|v| v.parse::<f64>().is_ok());
                        }
                        _ => {}
                    }
                } else if nombre == b"item" {
                    if let (Some(id), Some(href)) = (atributo(&e, b"id"), atributo(&e, b"href")) {
                        manifiesto.push((id, href, atributo(&e, b"properties")));
                    }
                }
            }
            Ok(Event::Text(t)) => {
                if campo.is_some() {
                    if let Ok(texto) = t.decode() {
                        acumulado.push_str(&texto);
                    }
                }
            }
            // **Aquí está la defensa contra la entidad externa.**
            //
            // El analizador no resuelve ninguna entidad: entrega su nombre y
            // deja la decisión aquí. Solo se resuelven las cinco predefinidas de
            // XML y las referencias numéricas, que son parte del formato.
            // Cualquier otra, como la que apunta a `/etc/passwd` en el corpus,
            // **invalida el campo entero**: no se resuelve, y tampoco se deja
            // pasar el texto que la rodea, porque un valor a medias es un valor
            // que nadie sabe interpretar.
            Ok(Event::GeneralRef(r)) => {
                if campo.is_none() {
                    continue;
                }
                match resolver_entidad(&r) {
                    Some(c) => acumulado.push(c),
                    None => {
                        tracing::warn!(
                            "el documento declara una entidad que este lector no resuelve"
                        );
                        contaminado = true;
                    }
                }
            }
            Ok(Event::End(_)) => {
                let (Some(actual), false) = (campo.take(), contaminado) else {
                    acumulado.clear();
                    contaminado = false;
                    continue;
                };

                let texto = recortar(&acumulado);
                acumulado.clear();
                if texto.is_empty() {
                    continue;
                }

                match actual.as_slice() {
                    b"title" if metadatos.title.is_none() => metadatos.title = Some(texto),
                    /*
                     * `dc:creator` sin papel declarado es el autor: es lo que
                     * significa "creator" en Dublin Core, y la inmensa mayoría de
                     * los EPUB no declaran `opf:role`.
                     *
                     * `dc:contributor` sin papel **no se guarda**. No es que sea
                     * menos importante: es que el catálogo solo sabe guardar
                     * cuatro papeles y ninguno es "alguien que ayudó", así que
                     * inventarle uno sería escribir en la biblioteca del usuario
                     * algo que su archivo no dice.
                     */
                    b"creator" => metadatos.creators.push(Creador {
                        name: texto,
                        role: papel
                            .as_deref()
                            .and_then(Papel::de_codigo)
                            .unwrap_or(Papel::Autor),
                    }),
                    b"contributor" => {
                        if let Some(role) = papel.as_deref().and_then(Papel::de_codigo) {
                            metadatos.creators.push(Creador { name: texto, role });
                        }
                    }
                    b"language" if metadatos.language.is_none() => {
                        metadatos.language = Some(texto);
                    }
                    b"publisher" if metadatos.publisher.is_none() => {
                        metadatos.publisher = Some(texto);
                    }
                    b"date" if metadatos.date.is_none() => metadatos.date = Some(texto),
                    b"identifier" => metadatos
                        .identifiers
                        .push((esquema.clone().unwrap_or_else(|| "local".to_owned()), texto)),
                    b"subject" => metadatos.subjects.push(texto),
                    b"description" if metadatos.description.is_none() => {
                        let limpia = sin_marcado(&texto);
                        if !limpia.is_empty() {
                            metadatos.description = Some(limpia);
                        }
                    }
                    b"meta" => match propiedad.as_deref() {
                        Some("belongs-to-collection") if metadatos.series.is_none() => {
                            metadatos.series = Some(texto);
                        }
                        Some("group-position")
                            if metadatos.series_index.is_none() && texto.parse::<f64>().is_ok() =>
                        {
                            metadatos.series_index = Some(texto);
                        }
                        _ => {}
                    },
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => {
                tracing::warn!("el paquete del documento está mal formado");
                return Err(NbError::DocumentCorrupted);
            }
            _ => {}
        }
        buf.clear();
    }

    metadatos.cover_path = manifiesto
        .iter()
        // EPUB 3 la marca en el manifiesto.
        .find(|(_, _, props)| {
            props
                .as_deref()
                .is_some_and(|p| p.split_whitespace().any(|v| v == "cover-image"))
        })
        // EPUB 2, por referencia desde `<meta>`.
        .or_else(|| {
            id_portada
                .as_deref()
                .and_then(|id| manifiesto.iter().find(|(i, _, _)| i == id))
        })
        .map(|(_, href, _)| href.clone());

    Ok(metadatos)
}

/// Prepara el lector de XML.
///
/// `check_end_names` hace que un XML mal formado falle en lugar de producir
/// datos a medias, que es lo que el corpus exige para `xml-malformado.epub`.
fn preparar(xml: &str) -> Reader<&[u8]> {
    let mut lector = Reader::from_str(xml);
    lector.config_mut().check_end_names = true;
    lector
}

/// Igual que [`resolver_entidad`], para quien lo necesite desde otro módulo.
///
/// Lo necesita el saneador del marcado: la misma defensa tiene que aplicarse al
/// contenido que se pinta, no solo a los metadatos que se guardan.
#[must_use]
pub fn resolver_entidad_publica(r: &quick_xml::events::BytesRef<'_>) -> Option<char> {
    resolver_entidad(r)
}

/// Resuelve una referencia a entidad, y **solo** las que son parte del formato.
///
/// Las cinco predefinidas de XML y las referencias numéricas. Nada más: una
/// entidad declarada en un DOCTYPE no se resuelve, que es lo que impide que un
/// documento haga leer un archivo del sistema.
fn resolver_entidad(r: &quick_xml::events::BytesRef<'_>) -> Option<char> {
    if let Ok(Some(c)) = r.resolve_char_ref() {
        return Some(c);
    }
    match r.decode().ok()?.as_ref() {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => None,
    }
}

fn local(nombre: &[u8]) -> &[u8] {
    // `dc:title` y `title` son el mismo campo; el prefijo depende de cómo haya
    // declarado el espacio de nombres cada generador de EPUB.
    match nombre.iter().rposition(|b| *b == b':') {
        Some(i) => &nombre[i + 1..],
        None => nombre,
    }
}

fn atributo(e: &BytesStart<'_>, nombre: &[u8]) -> Option<String> {
    e.attributes().flatten().find_map(|a| {
        (local(a.key.as_ref()) == local(nombre))
            .then(|| sin_entidades(&String::from_utf8_lossy(&a.value)))
    })
}

/// Resuelve las entidades que quedan escritas dentro de un valor.
///
/// El valor de un atributo llega sin resolver, y la sinopsis suele traer HTML
/// escapado **dos veces**. Sin esto, la serie "Áncora &amp; Delfín" se guardaba
/// con el `&amp;` a la vista -492 series así en la biblioteca real, medido el
/// 2026-11-13- y las sinopsis enseñaban `&#160;`. Solo las predefinidas de XML,
/// el espacio duro y las numéricas: nada que venga de un DOCTYPE.
#[must_use]
pub fn sin_entidades(texto: &str) -> String {
    if !texto.contains('&') {
        return texto.to_owned();
    }
    let mut salida = String::with_capacity(texto.len());
    let mut resto = texto;
    while let Some(inicio) = resto.find('&') {
        salida.push_str(&resto[..inicio]);
        let cola = &resto[inicio + 1..];
        let resuelta = cola.find(';').filter(|fin| *fin <= 10).and_then(|fin| {
            let nombre = &cola[..fin];
            let c = match nombre {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some(' '),
                _ => nombre
                    .strip_prefix("#x")
                    .or_else(|| nombre.strip_prefix("#X"))
                    .map(|h| u32::from_str_radix(h, 16))
                    .or_else(|| nombre.strip_prefix('#').map(str::parse::<u32>))
                    .and_then(Result::ok)
                    .and_then(char::from_u32)
                    // El espacio duro, como espacio: es texto para leer.
                    .map(|c| if c == '\u{a0}' { ' ' } else { c }),
            };
            c.map(|c| (c, fin))
        });
        match resuelta {
            Some((c, fin)) => {
                salida.push(c);
                resto = &cola[fin + 1..];
            }
            None => {
                salida.push('&');
                resto = cola;
            }
        }
    }
    salida.push_str(resto);
    salida
}

/// Recorta y acota un valor de texto.
/// La sinopsis sin etiquetas: muchas traen `<p>` escapado dentro del campo, y
/// enseñarlo tal cual sería enseñar marcado como texto.
fn sin_marcado(texto: &str) -> String {
    // Dos vueltas: lo que venía escapado dos veces enseña etiquetas y entidades
    // nuevas al resolver la primera capa.
    let una = sin_entidades(&sin_etiquetas(texto));
    sin_entidades(&sin_etiquetas(&una))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn sin_etiquetas(texto: &str) -> String {
    let mut salida = String::with_capacity(texto.len());
    let mut inicio = None;
    let mut caracteres = texto.char_indices().peekable();
    while let Some((indice, c)) = caracteres.next() {
        match c {
            '<' if inicio.is_none()
                && caracteres.peek().is_some_and(|(_, siguiente)| {
                    siguiente.is_ascii_alphabetic() || matches!(*siguiente, '/' | '!')
                }) =>
            {
                inicio = Some(indice);
            }
            '>' if inicio.is_some() => {
                inicio = None;
                salida.push(' ');
            }
            _ if inicio.is_none() => salida.push(c),
            _ => {}
        }
    }
    // Un marcador sin cierre es texto; descartarlo perdería parte de la sinopsis.
    if let Some(indice) = inicio {
        salida.push_str(&texto[indice..]);
    }
    salida
}

/// Lo mismo que se le hace a una sinopsis al leerla, para lo ya guardado.
#[must_use]
pub fn sinopsis_limpia(texto: &str) -> String {
    sin_marcado(texto)
}

fn recortar(texto: &str) -> String {
    let limpio = texto.trim();
    if limpio.len() <= MAX_CAMPO {
        return limpio.to_owned();
    }
    // Se corta en un límite de carácter: partir un UTF-8 por la mitad produciría
    // una cadena que no se puede guardar.
    let corte = (0..=MAX_CAMPO)
        .rev()
        .find(|i| limpio.is_char_boundary(*i))
        .unwrap_or(0);
    tracing::warn!("un campo de metadatos excede el tamaño admitido; se recorta");
    limpio[..corte].to_owned()
}

/// Resuelve una ruta declarada como relativa al OPF.
fn resolver_relativo(ruta_opf: &str, href: &str) -> Option<String> {
    let base = ruta_opf.rsplit_once('/').map_or("", |(dir, _)| dir);
    let completa = if base.is_empty() {
        href.to_owned()
    } else {
        format!("{base}/{href}")
    };

    // La ruta viene del documento: se valida antes de usarla para nada.
    crate::security::validate_archive_entry(&completa)
        .ok()
        .map(|_| completa)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **La serie y la sinopsis salen del paquete**. Hasta el
    /// 2026-11-12 ninguna de las 152.080 ediciones tenía serie, aunque casi todo
    /// el corpus la declara con `calibre:series`, y la sinopsis no se leía.
    #[test]
    fn la_serie_y_la_sinopsis_salen_del_paquete() {
        let epub2 = r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata
            xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fundación</dc:title>
            <dc:description>&lt;p&gt;Hari Seldon   predice&lt;/p&gt; la caída.</dc:description>
            <meta name="calibre:series" content="Trilogía de la Fundación"/>
            <meta name="calibre:series_index" content="1.0"/></metadata></package>"#;
        let m = leer_paquete(epub2).expect("paquete");
        assert_eq!(m.series.as_deref(), Some("Trilogía de la Fundación"));
        assert_eq!(m.series_index.as_deref(), Some("1.0"));
        assert_eq!(
            m.description.as_deref(),
            Some("Hari Seldon predice la caída.")
        );

        let epub3 = r##"<package xmlns="http://www.idpf.org/2007/opf"><metadata
            xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Segunda</dc:title>
            <meta property="belongs-to-collection" id="c">Tres mundos</meta>
            <meta refines="#c" property="group-position">2</meta></metadata></package>"##;
        let m = leer_paquete(epub3).expect("paquete");
        assert_eq!(m.series.as_deref(), Some("Tres mundos"));
        assert_eq!(m.series_index.as_deref(), Some("2"));
    }

    /// Una entidad escrita dentro del valor no se guarda tal cual.
    #[test]
    fn las_entidades_de_un_valor_se_resuelven() {
        assert_eq!(sin_entidades("Áncora &amp; Delfín"), "Áncora & Delfín");
        assert_eq!(
            sin_entidades("siglo&#160;XX &#x41; &quot;x&quot;"),
            "siglo XX A \"x\""
        );
        assert_eq!(sin_entidades("Tom & Jerry; fin"), "Tom & Jerry; fin");
        assert_eq!(
            sin_marcado("&lt;p&gt;Uno&amp;nbsp;dos&lt;/p&gt;"),
            "Uno dos"
        );
        assert_eq!(
            sin_marcado("<p>Uno&amp;#160;dos &amp;amp; tres</p>"),
            "Uno dos & tres"
        );
    }

    #[test]
    fn la_sinopsis_conserva_comparaciones_y_marcadores_sin_cierre() {
        assert_eq!(sinopsis_limpia("2 &lt; 3 y 5 &gt; 4"), "2 < 3 y 5 > 4");
        assert_eq!(sinopsis_limpia("2&lt;3 y 5&gt;4"), "2<3 y 5>4");
        assert_eq!(
            sinopsis_limpia("Antes <texto sin cierre"),
            "Antes <texto sin cierre"
        );
        assert_eq!(sinopsis_limpia("<p>Uno</p><p>Dos</p>"), "Uno Dos");
    }

    fn fixture(nombre: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../tests/fixtures")
            .join(nombre)
    }

    #[test]
    fn lee_los_metadatos_de_un_epub_valido() {
        let metadatos = read_metadata(&fixture("minimo-valido.epub")).expect("metadatos");

        assert_eq!(
            metadatos.title.as_deref(),
            Some("Documento de prueba de NB Books")
        );
        assert_eq!(
            metadatos.creators,
            vec![Creador {
                name: "The NB Books Authors".to_owned(),
                role: Papel::Autor
            }]
        );
        assert_eq!(metadatos.language.as_deref(), Some("es"));
        assert_eq!(
            metadatos.identifiers,
            vec![(
                "local".to_owned(),
                "urn:uuid:nb-books-fixture-0001".to_owned()
            )]
        );
        // Este documento no trae portada, y eso no es un error.
        assert_eq!(metadatos.cover_path, None);
    }

    /// **La defensa contra la entidad externa.**
    ///
    /// El OPF de este archivo declara `<!ENTITY xxe SYSTEM "file:///etc/passwd">`
    /// y lo usa dentro de `<metadata>`. Si el analizador la resolviera, el
    /// contenido de `/etc/passwd` entraría en el catálogo del usuario y de ahí a
    /// una exportación o a una sincronización.
    #[test]
    fn una_entidad_externa_no_se_resuelve_jamas() {
        let resultado = read_metadata(&fixture("entidad-externa.epub"));

        // Da igual si falla o si devuelve metadatos vacíos: lo que no puede
        // pasar es que aparezca nada del archivo al que apunta la entidad.
        if let Ok(metadatos) = resultado {
            let todo = format!("{metadatos:?}");
            assert!(!todo.contains("root:"), "se filtró /etc/passwd: {todo}");
            assert!(!todo.contains("/bin/"), "se filtró /etc/passwd: {todo}");
            assert!(!todo.contains("passwd"), "se filtró la ruta: {todo}");
        }
    }

    /// Las entidades predefinidas de XML sí se resuelven: son parte del formato,
    /// no una puerta a nada.
    #[test]
    fn las_entidades_predefinidas_de_xml_si_se_resuelven() {
        let opf = r#"<?xml version="1.0"?>
            <package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>Marx &amp; Engels &lt;completo&gt;</dc:title>
            </metadata></package>"#;

        let metadatos = leer_paquete(opf).expect("paquete");
        assert_eq!(metadatos.title.as_deref(), Some("Marx & Engels <completo>"));
    }

    /// El corpus lo pide con nombre: "error controlado al analizar el capítulo".
    /// Un XML mal formado no puede producir metadatos a medias que parezcan
    /// buenos.
    #[test]
    fn un_paquete_mal_formado_se_rechaza_en_lugar_de_producir_datos_a_medias() {
        let roto = r#"<?xml version="1.0"?>
            <package><metadata><dc:title>Sin cerrar</metadata></package>"#;

        assert_eq!(leer_paquete(roto), Err(NbError::DocumentCorrupted));
    }

    /// El prefijo del espacio de nombres depende del generador: `dc:title` y
    /// `title` son el mismo campo, y un lector que solo entienda uno se pierde
    /// media biblioteca.
    #[test]
    fn el_prefijo_del_espacio_de_nombres_no_cambia_el_campo() {
        let con_prefijo = r#"<package><metadata><dc:title>Con</dc:title></metadata></package>"#;
        let sin_prefijo = r#"<package><metadata><title>Sin</title></metadata></package>"#;

        assert_eq!(
            leer_paquete(con_prefijo).expect("con").title.as_deref(),
            Some("Con")
        );
        assert_eq!(
            leer_paquete(sin_prefijo).expect("sin").title.as_deref(),
            Some("Sin")
        );
    }

    /// **El defecto que ensució el panel de autores del corpus real.**
    ///
    /// Calibre estampa su propia versión como `dc:contributor` con
    /// `opf:role="bkp"` -productor de libro- en cada EPUB que produce. Con los
    /// contribuidores entrando como autores, las versiones de Calibre estaban
    /// entre los "autores" con más obras de la biblioteca, por delante de
    /// cualquier persona que hubiera escrito algo.
    #[test]
    fn la_herramienta_que_empaqueto_el_libro_no_es_uno_de_sus_autores() {
        let opf = r#"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:opf="http://www.idpf.org/2007/opf">
              <dc:creator>Quien Lo Escribio</dc:creator>
              <dc:contributor opf:role="bkp">calibre (7.16.0) [https://calibre-ebook.com]</dc:contributor>
            </metadata></package>"#;

        let m = leer_paquete(opf).expect("paquete");

        assert_eq!(
            m.creators,
            vec![Creador {
                name: "Quien Lo Escribio".to_owned(),
                role: Papel::Autor
            }]
        );
    }

    /// El papel que el archivo declara se respeta, no se sustituye por autor.
    #[test]
    fn quien_traduce_o_ilustra_se_guarda_con_su_papel_y_no_como_autor() {
        let opf = r#"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:opf="http://www.idpf.org/2007/opf">
              <dc:creator opf:role="aut">La Autora</dc:creator>
              <dc:creator opf:role="ill">Quien Ilustra</dc:creator>
              <dc:contributor opf:role="trl">Quien Traduce</dc:contributor>
              <dc:contributor opf:role="edt">Quien Edita</dc:contributor>
            </metadata></package>"#;

        let m = leer_paquete(opf).expect("paquete");

        assert_eq!(
            m.creators,
            vec![
                Creador {
                    name: "La Autora".to_owned(),
                    role: Papel::Autor
                },
                Creador {
                    name: "Quien Ilustra".to_owned(),
                    role: Papel::Ilustrador
                },
                Creador {
                    name: "Quien Traduce".to_owned(),
                    role: Papel::Traductor
                },
                Creador {
                    name: "Quien Edita".to_owned(),
                    role: Papel::Editor
                }
            ]
        );
    }

    #[test]
    fn se_leen_varios_autores_en_su_orden_y_los_identificadores_con_su_esquema() {
        let opf = r#"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:opf="http://www.idpf.org/2007/opf">
              <dc:creator>Primera Autora</dc:creator>
              <dc:creator>Segundo Autor</dc:creator>
              <dc:contributor>La Traductora</dc:contributor>
              <dc:identifier opf:scheme="ISBN">9788437604947</dc:identifier>
              <dc:identifier>urn:uuid:algo</dc:identifier>
              <dc:subject>Novela</dc:subject>
              <dc:subject>Siglo XX</dc:subject>
              <dc:publisher>Editorial</dc:publisher>
              <dc:date>1967-05-30</dc:date>
            </metadata></package>"#;

        let m = leer_paquete(opf).expect("paquete");

        // La traductora **no** entra sin declarar su papel: `dc:contributor` sin
        // `opf:role` no dice qué hizo, y el catálogo solo guarda cuatro papeles.
        assert_eq!(
            m.creators,
            vec![
                Creador {
                    name: "Primera Autora".to_owned(),
                    role: Papel::Autor
                },
                Creador {
                    name: "Segundo Autor".to_owned(),
                    role: Papel::Autor
                }
            ]
        );
        assert_eq!(
            m.identifiers,
            vec![
                ("ISBN".to_owned(), "9788437604947".to_owned()),
                ("local".to_owned(), "urn:uuid:algo".to_owned())
            ]
        );
        assert_eq!(m.subjects, vec!["Novela".to_owned(), "Siglo XX".to_owned()]);
        assert_eq!(m.publisher.as_deref(), Some("Editorial"));
        assert_eq!(m.date.as_deref(), Some("1967-05-30"));
    }

    /// Las dos formas de declarar la portada, según la versión de EPUB.
    #[test]
    fn la_portada_se_encuentra_en_sus_dos_formas() {
        let epub3 = r#"<package><manifest>
              <item id="c" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            </manifest></package>"#;
        assert_eq!(
            leer_paquete(epub3).expect("epub3").cover_path.as_deref(),
            Some("images/cover.jpg")
        );

        let epub2 = r#"<package><metadata>
              <meta name="cover" content="portada"/>
            </metadata><manifest>
              <item id="portada" href="cover.png" media-type="image/png"/>
            </manifest></package>"#;
        assert_eq!(
            leer_paquete(epub2).expect("epub2").cover_path.as_deref(),
            Some("cover.png")
        );
    }

    /// Un título de diez megabytes no es un título: es un intento de llenar la
    /// base de datos con un solo documento.
    #[test]
    fn un_campo_desmedido_se_recorta_sin_partir_un_caracter() {
        let largo = "á".repeat(MAX_CAMPO);
        let opf = format!("<package><metadata><dc:title>{largo}</dc:title></metadata></package>");

        let titulo = leer_paquete(&opf).expect("paquete").title.expect("título");

        assert!(titulo.len() <= MAX_CAMPO);
        // Si hubiera partido un carácter, la cadena no sería UTF-8 válido y no
        // habría llegado hasta aquí; esto fija además que no se corta a ciegas.
        assert!(titulo.chars().all(|c| c == 'á'));
    }

    /// La ruta del paquete sale del propio archivo, así que es entrada no
    /// confiable como cualquier otra.
    #[test]
    fn una_ruta_de_paquete_que_escapa_se_rechaza() {
        let contenedor = r#"<container><rootfiles>
              <rootfile full-path="../../../etc/passwd"
                        media-type="application/oebps-package+xml"/>
            </rootfiles></container>"#;

        let ruta = ruta_del_paquete(contenedor).expect("la lee");
        assert_eq!(
            crate::security::validate_archive_entry(&ruta),
            Err(NbError::PathNotAllowed)
        );
    }

    #[test]
    fn una_portada_que_escapa_del_contenedor_se_descarta() {
        assert_eq!(
            resolver_relativo("OEBPS/content.opf", "../../../../etc/passwd"),
            None
        );
        assert_eq!(
            resolver_relativo("OEBPS/content.opf", "images/cover.jpg").as_deref(),
            Some("OEBPS/images/cover.jpg")
        );
        assert_eq!(
            resolver_relativo("content.opf", "cover.jpg").as_deref(),
            Some("cover.jpg")
        );
    }
}
