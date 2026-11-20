//! Saneado del marcado de un documento antes de que llegue al webview.
//!
//! Un EPUB es HTML que escribió un desconocido, y el webview lo va a ejecutar.
//! El modelo de amenazas lo dice sin rodeos: "sin ejecución de scripts, sin
//! carga de recursos remotos, sin navegación fuera del documento".
//!
//! # Por qué una lista de lo permitido y no de lo prohibido
//!
//! Una lista de lo prohibido hay que mantenerla al día de cada elemento y de
//! cada atributo que se inventen, y basta con olvidar uno. Una lista de lo
//! permitido falla al revés: si aparece algo nuevo que debería pasar, no pasa, y
//! el fallo es visible —falta una etiqueta en la pantalla— en lugar de silencioso.
//!
//! La política de contenido de Tauri es la segunda barrera, no la primera:
//! depende de que el webview la respete, y esto no.
//!
//! Contrato: `docs/audit/threat-model.md`, sección 3.1.

use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::error::{NbError, NbResult};

/// Elementos que se dejan pasar.
///
/// Lo que hace falta para leer un libro. Nada de formularios, ni de contenido
/// incrustado, ni de nada que pueda navegar o ejecutar.
const PERMITIDOS: &[&str] = &[
    "html",
    "head",
    "title",
    "body",
    "div",
    "p",
    "span",
    "br",
    "hr",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "em",
    "strong",
    "i",
    "b",
    "u",
    "s",
    "small",
    "sub",
    "sup",
    "a",
    "img",
    "figure",
    "figcaption",
    "ul",
    "ol",
    "li",
    "dl",
    "dt",
    "dd",
    "blockquote",
    "cite",
    "q",
    "pre",
    "code",
    "table",
    "thead",
    "tbody",
    "tfoot",
    "tr",
    "td",
    "th",
    "caption",
    "col",
    "colgroup",
    "section",
    "article",
    "header",
    "footer",
    "nav",
    "aside",
    "main",
    "ruby",
    "rt",
    "rp",
    "abbr",
    "time",
    "mark",
    "del",
    "ins",
    "wbr",
];

/// Los elementos de MathML que se dejan pasar.
///
/// Antes ninguno: un libro con fórmulas se leía con las fórmulas
/// convertidas en letras sueltas, porque el saneado quitaba cada etiqueta y
/// conservaba su texto. Para un producto que apunta a universidades eso no era un
/// hueco de catálogo, era contenido perdido en silencio.
///
/// Es la presentación de MathML Core más lo que WebKit sabe pintar además
/// (`menclose`, `mfenced`) y lo que acompaña a una fórmula sin pintarse
/// (`semantics`, `annotation`). **No está `mglyph`**, que carga una imagen por su
/// cuenta, ni `annotation-xml`, que puede llevar HTML o SVG dentro y es justo el
/// punto por el que un analizador y otro dejan de estar de acuerdo sobre qué es
/// marcado y qué es texto: ver [`CON_CONTENIDO`].
const MATEMATICAS: &[&str] = &[
    "math",
    "maction",
    "annotation",
    "menclose",
    "merror",
    "mfenced",
    "mfrac",
    "mi",
    "mlabeledtr",
    "mmultiscripts",
    "mn",
    "mo",
    "mover",
    "mpadded",
    "mphantom",
    "mprescripts",
    "mroot",
    "mrow",
    "ms",
    "mspace",
    "msqrt",
    "mstyle",
    "msub",
    "msubsup",
    "msup",
    "mtable",
    "mtd",
    "mtext",
    "mtr",
    "munder",
    "munderover",
    "none",
    "semantics",
];

/// Los elementos de SVG que se dejan pasar.
///
/// Antes ninguno, y sin decirlo en ningún contrato: una ilustración
/// vectorial desaparecía, y con ella la portada de los libros que la componen como
/// un `<svg>` con la imagen dentro, que son muchos. Es lo que hace falta para
/// **dibujar**: formas, trazos, texto, degradados, recortes y marcadores.
///
/// Lo que no está, y por qué, en [`CON_CONTENIDO`] y en la sección 4.3.2 de
/// `reader-contracts.md`: `script`; `foreignObject`, que mete HTML dentro del
/// dibujo; las animaciones, porque `set` y `animate` pueden cambiar un `href` a
/// `javascript:` después de sanear; y los filtros, porque `feImage` carga lo que se
/// le pida. Los nombres van en minúsculas: el analizador de HTML les devuelve la
/// forma de SVG -`linearGradient`- al leerlos dentro de un `svg`.
const DIBUJO: &[&str] = &[
    "svg",
    "g",
    "defs",
    "symbol",
    "use",
    "switch",
    "path",
    "rect",
    "circle",
    "ellipse",
    "line",
    "polyline",
    "polygon",
    "text",
    "tspan",
    "textpath",
    "lineargradient",
    "radialgradient",
    "stop",
    "clippath",
    "mask",
    "pattern",
    "marker",
    "image",
    "desc",
];

/// Los atributos de geometría y presentación de SVG, que solo valen en un dibujo.
///
/// Los que aceptan una referencia -`fill`, `stroke`, `clip-path`, `mask`,
/// `marker-*`- se comprueban aparte: solo `url(#algo)` de este mismo documento.
/// Con `url(https://…)` un relleno sería una petición a un servidor.
const ATRIBUTOS_DE_DIBUJO: &[&str] = &[
    "d",
    "x",
    "y",
    "x1",
    "y1",
    "x2",
    "y2",
    "cx",
    "cy",
    "r",
    "rx",
    "ry",
    "fx",
    "fy",
    "dx",
    "dy",
    "points",
    "viewbox",
    "preserveaspectratio",
    "transform",
    "fill",
    "fill-opacity",
    "fill-rule",
    "stroke",
    "stroke-width",
    "stroke-opacity",
    "stroke-linecap",
    "stroke-linejoin",
    "stroke-dasharray",
    "stroke-dashoffset",
    "stroke-miterlimit",
    "opacity",
    "font-family",
    "font-size",
    "font-weight",
    "font-style",
    "text-anchor",
    "dominant-baseline",
    "letter-spacing",
    "rotate",
    "textlength",
    "lengthadjust",
    "gradientunits",
    "gradienttransform",
    "spreadmethod",
    "offset",
    "stop-color",
    "stop-opacity",
    "clip-path",
    "clip-rule",
    "clippathunits",
    "mask",
    "maskunits",
    "maskcontentunits",
    "patternunits",
    "patterncontentunits",
    "patterntransform",
    "marker-start",
    "marker-mid",
    "marker-end",
    "markerwidth",
    "markerheight",
    "markerunits",
    "refx",
    "refy",
    "orient",
    "visibility",
    "display",
    "vector-effect",
    "color",
    "version",
];

/// Los atributos de presentación de MathML, que solo valen dentro de una fórmula.
///
/// Ninguno carga nada ni ejecuta nada: dicen cómo se coloca y se dibuja cada pieza.
/// `mathcolor` y `mathbackground` admiten solo colores, no `url()`. El `href` que
/// MathML permite en cualquier elemento pasa por la misma comprobación que el de un
/// enlace: fuera todo lo que lleve esquema.
const ATRIBUTOS_MATEMATICOS: &[&str] = &[
    "accent",
    "accentunder",
    "align",
    "alttext",
    "bevelled",
    "close",
    "columnalign",
    "columnlines",
    "columnspacing",
    "columnspan",
    "denomalign",
    "depth",
    "display",
    "displaystyle",
    "encoding",
    "fence",
    "form",
    "frame",
    "framespacing",
    "largeop",
    "linethickness",
    "lspace",
    "mathbackground",
    "mathcolor",
    "mathsize",
    "mathvariant",
    "maxsize",
    "minsize",
    "movablelimits",
    "notation",
    "numalign",
    "open",
    "rowalign",
    "rowlines",
    "rowspacing",
    "rspace",
    "scriptlevel",
    "separator",
    "separators",
    "stretchy",
    "subscriptshift",
    "superscriptshift",
    "symmetric",
    "voffset",
];

/// Elementos cuyo **contenido** también se descarta.
///
/// Con quitar la etiqueta de un `<script>` no basta: su texto quedaría suelto en
/// la página. Y el de un `<style>` puede traer `@import` de un servidor.
///
/// `annotation-xml` va aquí y no entre los desconocidos, que conservan lo de
/// dentro: puede traer HTML dentro de una fórmula, y el navegador lo trata como un
/// punto donde el marcado vuelve a ser HTML. Es la puerta de las confusiones de
/// espacio de nombres con las que se han saltado saneadores de verdad, y lo que
/// lleva no se pinta en ningún caso: es una forma alternativa de la fórmula.
///
/// `foreignObject` por lo mismo dentro de un dibujo, y las animaciones de SVG
/// porque no dibujan nada y sí pueden reescribir un atributo cuando ya se saneó.
const CON_CONTENIDO: &[&str] = &[
    "script",
    "style",
    "iframe",
    "object",
    "embed",
    "template",
    "annotation-xml",
    "foreignobject",
    "animate",
    "animatemotion",
    "animatetransform",
    "set",
    "filter",
];

/// Si un elemento se deja pasar.
fn permitido(nombre: &str) -> bool {
    PERMITIDOS.contains(&nombre) || MATEMATICAS.contains(&nombre) || DIBUJO.contains(&nombre)
}

/// Los atributos de dibujo que pueden llevar `url(...)`.
const CON_REFERENCIA: &[&str] = &[
    "fill",
    "stroke",
    "clip-path",
    "mask",
    "marker-start",
    "marker-mid",
    "marker-end",
];

/// Si un valor de dibujo solo se refiere a este documento.
///
/// `url(#degradado)` sí; `url(https://…)`, `url(data:…)` o cualquier otra cosa
/// dentro de `url()`, no. Un valor sin `url()` -un color, un número- pasa.
fn referencia_local(valor: &str) -> bool {
    let minusculas = valor.to_ascii_lowercase();
    let mut resto = minusculas.as_str();
    while let Some(inicio) = resto.find("url(") {
        let dentro = resto[inicio + 4..]
            .trim_start()
            .trim_start_matches(['"', '\'']);
        if !dentro.starts_with('#') {
            return false;
        }
        resto = &resto[inicio + 4..];
    }
    true
}

/// Atributos que se dejan pasar.
///
/// Ni uno solo de los `on*`, que son la puerta de la ejecución, y ni `style`,
/// que puede traer `url()` remota.
const ATRIBUTOS: &[&str] = &[
    "id",
    "class",
    "href",
    "src",
    "alt",
    "title",
    "lang",
    "dir",
    "colspan",
    "rowspan",
    "width",
    "height",
    "type",
    "epub:type",
    "role",
    "aria-label",
    "aria-labelledby",
    "aria-describedby",
    "aria-hidden",
    "datetime",
];

/// Elementos que se cierran solos y no llevan etiqueta de cierre.
const VACIOS: &[&str] = &["br", "hr", "img", "col", "wbr"];

/// Contenido que el libro trae y el lector no pinta, y que por eso **se dice**
///.
///
/// No es todo lo que se quita: un `script` o un `style` no son contenido que
/// alguien vaya a echar en falta, son comportamiento y aspecto, y el lector pone
/// los suyos. Lo que está aquí es lo que alguien sí echaría en falta sin saber por
/// qué: un vídeo, una grabación, un documento incrustado, un formulario.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub enum OmittedContent {
    Audio,
    Video,
    /// Otro documento o un programa dentro de la página: `iframe`, `object`,
    /// `embed`, `canvas`.
    Embedded,
    /// Campos para rellenar: un libro de ejercicios los trae, y aquí no se envían
    /// a ninguna parte.
    Form,
}

impl OmittedContent {
    fn de(nombre: &str) -> Option<Self> {
        match nombre {
            "audio" => Some(Self::Audio),
            "video" => Some(Self::Video),
            "iframe" | "object" | "embed" | "canvas" => Some(Self::Embedded),
            "form" | "input" | "textarea" | "select" | "button" => Some(Self::Form),
            _ => None,
        }
    }
}

/// Qué se quitó al sanear.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SanitizeReport {
    /// Elementos que no estaban permitidos.
    pub elements_dropped: usize,
    /// Elementos cuyo contenido se descartó entero.
    pub blocks_dropped: usize,
    /// Atributos retirados, incluidos todos los manejadores de eventos.
    pub attributes_dropped: usize,
    /// Enlaces o recursos que apuntaban fuera del documento.
    pub remote_references_dropped: usize,
    /// Lo que se quitó y alguien echaría en falta, sin repetir y en orden.
    pub omitted: Vec<OmittedContent>,
}

impl SanitizeReport {
    fn omitir(&mut self, nombre: &str) {
        if let Some(clase) = OmittedContent::de(nombre) {
            if let Err(sitio) = self.omitted.binary_search(&clase) {
                self.omitted.insert(sitio, clase);
            }
        }
    }
}

/// Marcado saneado y el informe de lo que se quitó.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sanitized {
    pub html: String,
    pub report: SanitizeReport,
}

/// Sanea el marcado de un recurso.
///
/// # Errors
///
/// [`NbError::DocumentCorrupted`] si el marcado no se deja analizar. Un
/// documento que no se entiende no se pinta a medias: pintar la mitad de un XML
/// roto es pintar lo que un atacante dejó antes de romperlo.
pub fn sanitize(xhtml: &str) -> NbResult<Sanitized> {
    sanitize_with(xhtml, |_| None)
}

/// Sanea el marcado **y resuelve sus referencias internas**.
///
/// `resolver` recibe el valor de cada `src` interno y devuelve con qué
/// sustituirlo, o `None` para dejarlo tal cual.
///
/// # Por qué aquí y no reescribiendo el resultado
///
/// Porque aquí los atributos ya están analizados. Reescribir el HTML de salida
/// con una expresión regular significaría analizarlo por segunda vez, con otro
/// analizador y otras reglas, y dos análisis del mismo documento acaban
/// discrepando justo en el caso raro.
///
/// # Para qué existe
///
/// Un `<img src="images/portada.jpg">` de un EPUB apunta a un archivo **dentro
/// del contenedor**. El webview lo resuelve contra la dirección de la propia
/// aplicación, donde no hay nada, así que **ninguna imagen de ningún EPUB se
/// veía**: un libro ilustrado se leía como un libro sin ilustrar. Con el
/// resolver, quien pinta puede extraer el recurso y dar una ruta que el
/// protocolo de assets sepa servir.
///
/// # Errors
///
/// Los de [`sanitize`].
pub fn sanitize_with(
    xhtml: &str,
    resolver: impl FnMut(&str) -> Option<String>,
) -> NbResult<Sanitized> {
    let mut resolver = resolver;
    let mut lector = Reader::from_str(xhtml);
    lector.config_mut().check_end_names = false;

    let mut salida = String::with_capacity(xhtml.len());
    let mut informe = SanitizeReport::default();
    let mut buf = Vec::new();
    // Cuántos niveles de un elemento descartado con su contenido llevamos.
    let mut descartando: usize = 0;
    let mut pila_descartada: Vec<String> = Vec::new();

    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let nombre = nombre_de(&e);
                if descartando > 0 {
                    if CON_CONTENIDO.contains(&nombre.as_str()) {
                        descartando += 1;
                    }
                    continue;
                }
                if CON_CONTENIDO.contains(&nombre.as_str()) {
                    informe.blocks_dropped += 1;
                    informe.omitir(&nombre);
                    descartando = 1;
                    continue;
                }
                if !permitido(&nombre) {
                    // Se quita la etiqueta pero se conserva lo que hay dentro:
                    // un `<font>` desconocido no debe llevarse el texto.
                    informe.elements_dropped += 1;
                    informe.omitir(&nombre);
                    pila_descartada.push(nombre);
                    continue;
                }
                salida.push_str(&abrir(&e, &nombre, &mut informe, &mut resolver));
            }
            Ok(Event::Empty(e)) => {
                if descartando > 0 {
                    continue;
                }
                let nombre = nombre_de(&e);
                if CON_CONTENIDO.contains(&nombre.as_str()) {
                    informe.blocks_dropped += 1;
                    informe.omitir(&nombre);
                    continue;
                }
                if !permitido(&nombre) {
                    informe.elements_dropped += 1;
                    informe.omitir(&nombre);
                    continue;
                }
                let etiqueta = abrir(&e, &nombre, &mut informe, &mut resolver);
                salida.push_str(etiqueta.trim_end_matches('>'));
                salida.push_str("/>");
            }
            Ok(Event::End(e)) => {
                // En minúsculas, como al abrir: sin esto `</linearGradient>` no
                // cerraba el `lineargradient` que se había abierto, y el resto del
                // dibujo quedaba dentro del degradado.
                let nombre = String::from_utf8_lossy(local(e.name().as_ref())).to_ascii_lowercase();
                if descartando > 0 {
                    if CON_CONTENIDO.contains(&nombre.as_str()) {
                        descartando -= 1;
                    }
                    continue;
                }
                if pila_descartada.last() == Some(&nombre) {
                    pila_descartada.pop();
                    continue;
                }
                if permitido(&nombre) && !VACIOS.contains(&nombre.as_str()) {
                    salida.push_str(&format!("</{nombre}>"));
                }
            }
            Ok(Event::Text(t)) => {
                if descartando > 0 {
                    continue;
                }
                if let Ok(texto) = t.decode() {
                    salida.push_str(&escapar(&texto));
                }
            }
            // Una referencia a entidad se resuelve solo si es de las cinco del
            // formato. La misma defensa que en el extractor de metadatos.
            Ok(Event::GeneralRef(r)) => {
                if descartando > 0 {
                    continue;
                }
                if let Some(c) = crate::epub::resolver_entidad_publica(&r) {
                    salida.push_str(&escapar(&c.to_string()));
                }
            }
            // Comentarios, instrucciones de proceso y declaraciones se
            // descartan enteros: no aportan nada que leer y sí pueden esconder
            // cosas.
            Ok(Event::Comment(_) | Event::PI(_) | Event::Decl(_) | Event::DocType(_)) => {}
            Ok(Event::CData(_)) => {}
            Ok(Event::Eof) => break,
            Err(_) => {
                tracing::warn!("el marcado de un recurso no se deja analizar");
                return Err(NbError::DocumentCorrupted);
            }
        }
        buf.clear();
    }

    Ok(Sanitized {
        html: salida,
        report: informe,
    })
}

fn nombre_de(e: &BytesStart<'_>) -> String {
    String::from_utf8_lossy(local(e.name().as_ref()))
        .to_ascii_lowercase()
        .to_string()
}

fn local(nombre: &[u8]) -> &[u8] {
    match nombre.iter().rposition(|b| *b == b':') {
        // `epub:type` es el único atributo con prefijo que se conserva, y se
        // trata aparte; para los elementos, el prefijo no cambia cuál es.
        Some(i) => &nombre[i + 1..],
        None => nombre,
    }
}

fn abrir(
    e: &BytesStart<'_>,
    nombre: &str,
    informe: &mut SanitizeReport,
    resolver: &mut impl FnMut(&str) -> Option<String>,
) -> String {
    let mut etiqueta = format!("<{nombre}");

    for atributo in e.attributes().flatten() {
        let clave = String::from_utf8_lossy(atributo.key.as_ref()).to_ascii_lowercase();
        let valor = String::from_utf8_lossy(&atributo.value).into_owned();

        // Todo `on*` fuera, sin excepciones y sin mirar qué contiene.
        if clave.starts_with("on") {
            informe.attributes_dropped += 1;
            continue;
        }
        // `xlink:href` es la forma de SVG 1.1 de `href`, y la de casi todos los
        // libros. Se escribe como `href`, que es la de SVG 2, y pasa la misma
        // comprobación que cualquier enlace.
        let clave = if clave == "xlink:href" && DIBUJO.contains(&nombre) {
            "href".to_owned()
        } else {
            clave
        };
        let de_formula =
            MATEMATICAS.contains(&nombre) && ATRIBUTOS_MATEMATICOS.contains(&clave.as_str());
        let de_dibujo = DIBUJO.contains(&nombre) && ATRIBUTOS_DE_DIBUJO.contains(&clave.as_str());
        if !ATRIBUTOS.contains(&clave.as_str()) && !de_formula && !de_dibujo {
            informe.attributes_dropped += 1;
            continue;
        }
        if de_dibujo && CON_REFERENCIA.contains(&clave.as_str()) && !referencia_local(&valor) {
            informe.remote_references_dropped += 1;
            continue;
        }
        // Dentro de un dibujo, un `href` que no es de una imagen -`use`, un
        // degradado que hereda de otro, un texto sobre un trazo- solo puede apuntar a
        // algo de este mismo documento. Otro archivo del libro no se puede resolver
        // ahí, y lo que no se resuelve no tiene por qué salir a buscarse.
        if clave == "href"
            && DIBUJO.contains(&nombre)
            && nombre != "image"
            && !valor.trim_start().starts_with('#')
        {
            informe.remote_references_dropped += 1;
            continue;
        }
        if matches!(clave.as_str(), "href" | "src") && !es_referencia_interna(&valor) {
            informe.remote_references_dropped += 1;
            continue;
        }

        // Un `src` interno se resuelve a algo que el webview sepa cargar. Solo
        // `src`: un `href` interno es un enlace dentro del libro y lo gobierna la
        // navegación, no el protocolo de assets.
        // Y la imagen de un dibujo, igual: su `href` es el `src` de un `img`.
        let es_recurso = clave == "src" || (clave == "href" && nombre == "image");
        let valor = if es_recurso && !valor.trim_start().starts_with('#') {
            resolver(&valor).unwrap_or(valor)
        } else {
            valor
        };

        etiqueta.push_str(&format!(" {clave}=\"{}\"", escapar_atributo(&valor)));
    }

    etiqueta.push('>');
    etiqueta
}

/// Una referencia es interna si no lleva esquema ni empieza por `//`.
///
/// Se rechaza todo lo que tenga esquema, incluido `data:`: una imagen en línea
/// puede ser un SVG, y un SVG puede traer script. Lo único que se acepta es una
/// ruta relativa dentro del propio libro y un ancla local.
fn es_referencia_interna(valor: &str) -> bool {
    let limpio = valor.trim();
    if limpio.is_empty() || limpio.starts_with("//") {
        return false;
    }
    if limpio.starts_with('#') {
        return true;
    }
    // Un esquema es lo que va antes de `:` sin barras por medio.
    match limpio.split_once(':') {
        Some((antes, _)) => antes.contains('/'),
        None => true,
    }
}

fn escapar(texto: &str) -> String {
    texto
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn escapar_atributo(valor: &str) -> String {
    escapar(valor).replace('"', "&quot;")
}
