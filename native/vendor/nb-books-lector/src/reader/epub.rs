//! Proveedor de EPUB: el formato donde el modelo de Locator se pone a prueba.
//!
//! Un EPUB reflowable no tiene páginas. Su contenido se re-pagina cada vez que
//! alguien cambia el tamaño de letra o el ancho de la ventana, y eso es
//! exactamente lo que destruye cualquier modelo de posición basado en un número.
//!
//! # Por qué cambiar la tipografía no mueve nada
//!
//! **Este proveedor no sabe qué tipografía usa el lector, y no puede saberlo.**
//! No hay ningún parámetro por el que entre. Las posiciones que produce son
//! desplazamientos en el **texto del documento**, no en la página pintada, y el
//! texto del documento no cambia porque alguien agrande la letra.
//!
//! La tipografía la aplica el webview con variables de CSS sobre el marcado que
//! sale de aquí. Es una decisión de arquitectura y no una casualidad: mientras
//! la tipografía no sea una entrada de este módulo, no puede afectar a lo que
//! guarda.
//!
//! Contratos: `docs/architecture/reader-contracts.md` y
//! `docs/audit/threat-model.md`, sección 3.1.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use quick_xml::events::Event;
use quick_xml::Reader;

use super::locator::{contexto_de, Locations, Locator, TextContext};
use super::provider::{
    DocumentProvider, NativePosition, Navigation, NavigationEntry, Precision, ProviderFactory,
    ReaderCapabilities, Rendered, Resolution, SynchronizedAudio,
};
use crate::error::{NbError, NbResult};
use crate::reader::sanitize::sanitize_with;
use crate::zip::Archive;

/// Tipo de medio que sirve este proveedor.
pub const MEDIA_TYPE: &str = "application/epub+zip";

/// Cuántos caracteres de cita se guardan en un locator.
///
/// Suficiente para encontrar el sitio otra vez y poco para no duplicar el libro
/// dentro de sus propias anotaciones.
const CITA: usize = 48;

/// Contexto anterior y posterior a la cita.
const CONTEXTO: usize = 24;

/// Un recurso del lomo, con su texto plano ya extraído.
struct Recurso {
    href: String,
    titulo: Option<String>,
    /// Texto plano, que es el sistema de coordenadas de este formato.
    texto: String,
    /// Dónde empieza cada bloque —párrafo, elemento de lista, encabezado— en
    /// caracteres de `texto`. Es lo que permite trocear sin partir un párrafo
    ///.
    fronteras: Vec<usize>,
}

/// Un EPUB abierto.
pub struct EpubDocument {
    ruta: PathBuf,
    /// Recursos en el orden del lomo, que es el orden de lectura.
    lomo: Vec<Recurso>,
    navegacion: Navigation,
    /// Dónde se dejan las imágenes del libro para que el webview las cargue.
    ///
    /// Vacío en las pruebas que solo miran el texto: sin sitio donde extraer, el
    /// marcado sale con sus referencias originales, que es lo que había antes.
    recursos: Option<PathBuf>,
    /// La superposición de cada capítulo que la trae, por su ruta dentro del
    /// contenedor. Vacía en casi todos los libros, y entonces el lector
    /// no ofrece nada nuevo.
    superposiciones: HashMap<String, String>,
}

impl EpubDocument {
    /// Abre un EPUB y prepara su índice de lectura.
    ///
    /// # Errors
    ///
    /// - [`NbError::FileNotFound`] si la ruta no existe.
    /// - [`NbError::DocumentCorrupted`] si el contenedor o el paquete no se
    ///   dejan leer, o si el lomo está vacío: un libro sin nada que leer no es
    ///   un libro.
    /// - [`NbError::PathNotAllowed`] si alguna entrada intenta escapar.
    pub fn open(path: &Path) -> NbResult<Self> {
        Self::open_con_recursos(path, None)
    }

    /// Abre un EPUB diciendo dónde extraer sus imágenes.
    ///
    /// # Errors
    ///
    /// Los de [`Self::open`].
    pub fn open_con_recursos(path: &Path, recursos: Option<PathBuf>) -> NbResult<Self> {
        let mut documento = Self::abrir(path)?;
        documento.recursos = recursos;
        Ok(documento)
    }

    fn abrir(path: &Path) -> NbResult<Self> {
        let mut contenedor = Archive::open(path)?;
        let ruta_opf = crate::epub::ruta_del_paquete_de(&mut contenedor)?;
        let opf = contenedor.read_text(&ruta_opf)?;

        let (manifiesto, orden) = leer_lomo(&opf)?;
        let base = ruta_opf.rsplit_once('/').map_or("", |(dir, _)| dir);

        let mut lomo = Vec::new();
        for id in &orden {
            let Some(href) = manifiesto
                .iter()
                .find(|(i, _, _)| i == id)
                .map(|(_, href, _)| href)
            else {
                continue;
            };
            let Some(interna) = resolver(base, href) else {
                continue;
            };
            let Ok(xhtml) = contenedor.read_text(&interna) else {
                // Un capítulo que no se deja leer no puede tumbar el libro: se
                // omite y los demás siguen. La alternativa es no poder abrir un
                // libro de cuatrocientas páginas por una que está mal.
                tracing::warn!("un recurso del lomo no se pudo leer; se omite");
                continue;
            };

            let (texto, fronteras) = texto_plano(&xhtml);
            lomo.push(Recurso {
                titulo: None,
                texto,
                fronteras,
                href: interna,
            });
        }

        if lomo.is_empty() {
            tracing::warn!("el documento no tiene ningún recurso legible en su lomo");
            return Err(NbError::DocumentCorrupted);
        }

        let superposiciones = superposiciones_de(&manifiesto, base, &opf);
        let mut documento = Self {
            ruta: path.to_path_buf(),
            lomo,
            navegacion: Navigation::default(),
            recursos: None,
            superposiciones,
        };
        documento.navegacion = documento.construir_navegacion(&mut contenedor, &manifiesto, base);
        Ok(documento)
    }

    /// Marcado saneado de un recurso, listo para el webview.
    ///
    /// # Errors
    ///
    /// [`NbError::FileNotFound`] si el recurso no está en el lomo, o
    /// [`NbError::DocumentCorrupted`] si su marcado no se deja analizar.
    pub fn markup(&self, href: &str) -> NbResult<String> {
        self.saneado(href).map(|s| s.html)
    }

    /// El marcado saneado **con su informe**, que dice qué contenido se quitó.
    fn saneado(&self, href: &str) -> NbResult<crate::reader::sanitize::Sanitized> {
        if !self.lomo.iter().any(|r| r.href == href) {
            return Err(NbError::FileNotFound);
        }

        let mut contenedor = Archive::open(&self.ruta)?;
        let xhtml = contenedor.read_text(href)?;

        // Las referencias del capítulo se resuelven contra el propio contenedor
        // y se extraen a la caché. Sin esto, `<img src="images/x.jpg">` lo
        // resolvía el webview contra la dirección de la aplicación, donde no hay
        // nada: **ninguna imagen de ningún EPUB se veía**, y un libro ilustrado
        // se leía como un libro sin ilustrar.
        let base = href.rsplit_once('/').map_or("", |(dir, _)| dir);
        let destino = self.recursos.clone();
        let saneado = sanitize_with(&xhtml, |referencia| {
            let carpeta = destino.as_deref()?;
            extraer_recurso(&mut contenedor, base, referencia, carpeta)
        })?;

        if saneado.report.blocks_dropped > 0 || saneado.report.remote_references_dropped > 0 {
            // Se cuenta, no se detalla: el detalle sería el contenido del libro.
            tracing::info!(
                bloques = saneado.report.blocks_dropped,
                remotos = saneado.report.remote_references_dropped,
                atributos = saneado.report.attributes_dropped,
                "se saneó marcado de un documento"
            );
        }

        Ok(saneado)
    }

    /// Texto plano de un recurso del lomo, sin marcado.
    ///
    /// Es el sistema de coordenadas del formato: los desplazamientos de los
    /// locators son sobre esto. Se expone porque la búsqueda y las
    /// pruebas de reanclaje necesitan hablar el mismo idioma que la resolución,
    /// y calcularlo por su cuenta sería tener dos versiones de la misma cuenta.
    #[must_use]
    pub fn plain_text(&self, href: &str) -> Option<&str> {
        self.recurso(href).map(|r| r.texto.as_str())
    }

    /// Recursos en orden de lectura.
    #[must_use]
    pub fn spine(&self) -> Vec<&str> {
        self.lomo.iter().map(|r| r.href.as_str()).collect()
    }

    fn recurso(&self, href: &str) -> Option<&Recurso> {
        self.lomo.iter().find(|r| r.href == href)
    }

    fn total(&self) -> usize {
        self.lomo.iter().map(|r| r.texto.chars().count()).sum()
    }

    fn acumulado_hasta(&self, href: &str) -> Option<usize> {
        let mut acumulado = 0;
        for recurso in &self.lomo {
            if recurso.href == href {
                return Some(acumulado);
            }
            acumulado += recurso.texto.chars().count();
        }
        None
    }

    fn construir_navegacion(
        &self,
        contenedor: &mut Archive,
        manifiesto: &[ItemDelManifiesto],
        base: &str,
    ) -> Navigation {
        // El índice de EPUB 3 va en un recurso con `properties="nav"`; el de
        // EPUB 2, en un `toc.ncx`. Si no hay ninguno, el lomo sirve de índice:
        // un libro sin tabla de contenidos se sigue pudiendo recorrer.
        let entradas = manifiesto
            .iter()
            .find(|(_, _, props)| {
                props
                    .as_deref()
                    .is_some_and(|p| p.split_whitespace().any(|v| v == "nav"))
            })
            .and_then(|(_, href, _)| resolver(base, href))
            .and_then(|interna| contenedor.read_text(&interna).ok())
            .map(|xhtml| self.entradas_de_nav(&xhtml, base))
            .filter(|e| !e.is_empty());

        // Sin `nav`, el `toc.ncx` de EPUB 2. **Antes este comentario
        // lo prometía y el código no lo leía**: casi todo el corpus de epublibre es
        // EPUB 2, así que esos libros enseñaban "Sección 1…N" en lugar de su índice
        //. Sus rutas son relativas al propio `.ncx`, no al paquete.
        let entradas = entradas.or_else(|| {
            let (_, href, _) = manifiesto
                .iter()
                .find(|(_, href, _)| href.to_ascii_lowercase().ends_with(".ncx"))?;
            let interna = resolver(base, href)?;
            let ncx = contenedor.read_text(&interna).ok()?;
            let base_ncx = interna
                .rsplit_once('/')
                .map_or("", |(dir, _)| dir)
                .to_owned();
            Some(self.entradas_de_ncx(&ncx, &base_ncx)).filter(|e| !e.is_empty())
        });

        Navigation {
            entries: entradas.unwrap_or_else(|| self.entradas_del_lomo()),
        }
    }

    /// El índice de un `toc.ncx`, con su jerarquía: un `navPoint` dentro de otro
    /// es un hijo, como "Escena II" dentro de "Acto III".
    fn entradas_de_ncx(&self, ncx: &str, base: &str) -> Vec<NavigationEntry> {
        struct Punto {
            titulo: String,
            src: Option<String>,
            hijos: Vec<NavigationEntry>,
        }
        let mut lector = Reader::from_str(ncx);
        lector.config_mut().check_end_names = false;
        let mut buf = Vec::new();
        let mut pila: Vec<Punto> = Vec::new();
        let mut raiz: Vec<NavigationEntry> = Vec::new();
        let mut en_texto = false;
        let local = |nombre: &[u8]| -> Vec<u8> {
            nombre
                .rsplit(|b| *b == b':')
                .next()
                .unwrap_or(nombre)
                .to_vec()
        };
        loop {
            match lector.read_event_into(&mut buf) {
                Ok(Event::Start(e)) => match local(e.name().as_ref()).as_slice() {
                    b"navPoint" => pila.push(Punto {
                        titulo: String::new(),
                        src: None,
                        hijos: Vec::new(),
                    }),
                    b"text" => en_texto = true,
                    b"content" => {
                        if let Some(p) = pila.last_mut() {
                            p.src = atributo_src(&e);
                        }
                    }
                    _ => {}
                },
                Ok(Event::Empty(e)) => {
                    if local(e.name().as_ref()) == b"content" {
                        if let Some(p) = pila.last_mut() {
                            p.src = atributo_src(&e);
                        }
                    }
                }
                Ok(Event::Text(t)) => {
                    if en_texto {
                        if let (Some(p), Ok(texto)) = (pila.last_mut(), t.decode()) {
                            p.titulo.push_str(&texto);
                        }
                    }
                }
                Ok(Event::End(e)) => match local(e.name().as_ref()).as_slice() {
                    b"text" => en_texto = false,
                    b"navPoint" => {
                        let Some(punto) = pila.pop() else { continue };
                        let titulo = punto
                            .titulo
                            .split_whitespace()
                            .collect::<Vec<_>>()
                            .join(" ");
                        let locator = punto
                            .src
                            .as_deref()
                            .and_then(|src| resolver(base, src.split('#').next().unwrap_or(src)))
                            .and_then(|interna| {
                                self.locator_at(&NativePosition::Fragment {
                                    href: interna,
                                    offset: 0,
                                })
                                .ok()
                            });
                        let destino = match pila.last_mut() {
                            Some(padre) => &mut padre.hijos,
                            None => &mut raiz,
                        };
                        match locator {
                            Some(locator) if !titulo.is_empty() => destino.push(NavigationEntry {
                                title: titulo,
                                locator,
                                children: punto.hijos,
                            }),
                            // Un punto sin destino legible no se inventa, pero sus
                            // hijos sí cuentan: suben un nivel.
                            _ => destino.extend(punto.hijos),
                        }
                    }
                    _ => {}
                },
                Ok(Event::Eof) | Err(_) => break,
                _ => {}
            }
            buf.clear();
        }
        raiz
    }

    /// Índice de emergencia: un capítulo por recurso del lomo.
    fn entradas_del_lomo(&self) -> Vec<NavigationEntry> {
        self.lomo
            .iter()
            .enumerate()
            .filter_map(|(i, recurso)| {
                let locator = self
                    .locator_at(&NativePosition::Fragment {
                        href: recurso.href.clone(),
                        offset: 0,
                    })
                    .ok()?;
                Some(NavigationEntry {
                    title: recurso
                        .titulo
                        .clone()
                        .unwrap_or_else(|| format!("Sección {}", i + 1)),
                    locator,
                    children: Vec::new(),
                })
            })
            .collect()
    }

    fn entradas_de_nav(&self, xhtml: &str, base: &str) -> Vec<NavigationEntry> {
        let mut lector = Reader::from_str(xhtml);
        lector.config_mut().check_end_names = false;
        let mut buf = Vec::new();
        let mut entradas = Vec::new();
        let mut href_actual: Option<String> = None;
        let mut titulo = String::new();

        loop {
            match lector.read_event_into(&mut buf) {
                Ok(Event::Start(e)) => {
                    if e.name().as_ref().ends_with(b"a") {
                        href_actual = e.attributes().flatten().find_map(|a| {
                            (a.key.as_ref() == b"href")
                                .then(|| String::from_utf8_lossy(&a.value).into_owned())
                        });
                        titulo.clear();
                    }
                }
                Ok(Event::Text(t)) => {
                    if href_actual.is_some() {
                        if let Ok(texto) = t.decode() {
                            titulo.push_str(&texto);
                        }
                    }
                }
                Ok(Event::End(e)) => {
                    if e.name().as_ref().ends_with(b"a") {
                        if let Some(href) = href_actual.take() {
                            // El ancla se descarta: la posición la fija el
                            // locator, no el fragmento del enlace.
                            let sin_ancla = href.split('#').next().unwrap_or(&href).to_owned();
                            if let Some(interna) = resolver(base, &sin_ancla) {
                                if let Ok(locator) = self.locator_at(&NativePosition::Fragment {
                                    href: interna,
                                    offset: 0,
                                }) {
                                    let etiqueta = titulo.trim();
                                    if !etiqueta.is_empty() {
                                        entradas.push(NavigationEntry {
                                            title: etiqueta.to_owned(),
                                            locator,
                                            children: Vec::new(),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
                Ok(Event::Eof) | Err(_) => break,
                _ => {}
            }
            buf.clear();
        }

        entradas
    }
}

impl DocumentProvider for EpubDocument {
    fn media_type(&self) -> &str {
        MEDIA_TYPE
    }

    fn navigation(&self) -> NbResult<Navigation> {
        Ok(self.navegacion.clone())
    }

    fn locator_at(&self, position: &NativePosition) -> NbResult<Locator> {
        // Un EPUB reflowable **no tiene páginas**. Aceptar `Page` aquí sería
        // aceptar el modelo que ADR-004 descarta, con otro nombre.
        let NativePosition::Fragment { href, offset } = position else {
            return Err(NbError::PathNotAllowed);
        };

        let recurso = self.recurso(href).ok_or(NbError::PathNotAllowed)?;
        let caracteres: Vec<char> = recurso.texto.chars().collect();
        let offset = (*offset as usize).min(caracteres.len());

        let progresion = if caracteres.is_empty() {
            0.0
        } else {
            offset as f64 / caracteres.len() as f64
        };
        let total = self.total();
        let total_progresion = if total == 0 {
            0.0
        } else {
            (self.acumulado_hasta(href).unwrap_or(0) + offset) as f64 / total as f64
        };

        let fin = (offset + CITA).min(caracteres.len());
        let cita: String = caracteres[offset..fin].iter().collect();
        let antes: String = caracteres[offset.saturating_sub(CONTEXTO)..offset]
            .iter()
            .collect();
        let despues: String = caracteres[fin..(fin + CONTEXTO).min(caracteres.len())]
            .iter()
            .collect();

        let contexto = if cita.trim().is_empty() {
            None
        } else {
            TextContext::new(
                (!antes.is_empty()).then_some(antes.as_str()),
                &cita,
                (!despues.is_empty()).then_some(despues.as_str()),
            )
            .ok()
        };

        let mut locator = Locator::new(
            href,
            "application/xhtml+xml",
            Locations {
                // El desplazamiento es en el **texto del documento**, no en la
                // página pintada: por eso agrandar la letra no lo mueve.
                fragments: vec![format!("#char={offset}")],
                progression: Some(progresion),
                total_progression: Some(total_progresion),
                position: None,
            },
            contexto,
        )?;

        if let Some(titulo) = self.titulo_de(href) {
            locator = locator.with_title(&titulo);
        }
        Ok(locator)
    }

    fn resolve(&self, locator: &Locator) -> NbResult<Resolution> {
        let recurso = self.recurso(&locator.href);

        // 1. Fragmento, corroborado con la cita. Que un desplazamiento esté
        //    dentro de rango no prueba que siga señalando lo mismo.
        if let Some(recurso) = recurso {
            if let Some(offset) = locator.locations.fragments.iter().find_map(|f| {
                f.strip_prefix("#char=")
                    .and_then(|n| n.parse::<usize>().ok())
            }) {
                let caracteres = recurso.texto.chars().count();
                let corrobora = locator.text.as_ref().is_none_or(|contexto| {
                    recurso
                        .texto
                        .chars()
                        .skip(offset)
                        .take(contexto.highlight.chars().count())
                        .collect::<String>()
                        == contexto.highlight
                });

                if corrobora && offset <= caracteres {
                    return Ok(Resolution {
                        position: NativePosition::Fragment {
                            href: recurso.href.clone(),
                            offset: u32::try_from(offset).unwrap_or(u32::MAX),
                        },
                        precision: Precision::Exact,
                    });
                }
            }
        }

        // 2. La cita, en cualquier recurso: un capítulo puede haberse dividido o
        //    renombrado entre ediciones y el texto sigue estando.
        if let Some(cita) = locator.text.as_ref().map(|t| t.highlight.as_str()) {
            for candidato in &self.lomo {
                if let Some(byte) = candidato.texto.find(cita) {
                    return Ok(Resolution {
                        position: NativePosition::Fragment {
                            href: candidato.href.clone(),
                            offset: u32::try_from(candidato.texto[..byte].chars().count())
                                .unwrap_or(u32::MAX),
                        },
                        precision: Precision::Quote,
                    });
                }
            }
        }

        // 3. La progresión, y **se marca**.
        if let (Some(recurso), Some(progresion)) = (recurso, locator.locations.progression) {
            let caracteres = recurso.texto.chars().count();
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let offset = ((progresion * caracteres as f64) as usize).min(caracteres);
            return Ok(Resolution {
                position: NativePosition::Fragment {
                    href: recurso.href.clone(),
                    offset: u32::try_from(offset).unwrap_or(u32::MAX),
                },
                precision: Precision::Approximate,
            });
        }

        Err(NbError::DocumentNotFound)
    }

    fn text_range(&self, locator: &Locator, len: usize) -> NbResult<String> {
        let resolucion = self.resolve(locator)?;
        let NativePosition::Fragment { href, offset } = resolucion.position else {
            return Err(NbError::DocumentCorrupted);
        };
        let recurso = self.recurso(&href).ok_or(NbError::DocumentNotFound)?;

        Ok(recurso
            .texto
            .chars()
            .skip(offset as usize)
            .take(len)
            .collect())
    }

    fn render(&self, position: &NativePosition) -> NbResult<Rendered> {
        let NativePosition::Fragment { href, .. } = position else {
            return Err(NbError::PathNotAllowed);
        };

        let saneado = self.saneado(href)?;
        Ok(Rendered::Markup {
            html: saneado.html,
            media_type: "application/xhtml+xml".to_owned(),
            omitted: saneado.report.omitted,
        })
    }

    fn text_chunks(&self, max_chars: usize) -> NbResult<Vec<(Locator, String)>> {
        let mut salida = Vec::new();

        for recurso in &self.lomo {
            let caracteres: Vec<char> = recurso.texto.chars().collect();
            // Por párrafo, por frase o por espacio, en ese orden. Ver
            // `segmentos`.
            for tramo in super::segmentos::segmentar(&caracteres, &recurso.fronteras, max_chars) {
                let inicio = tramo.start;
                let texto: String = caracteres[tramo].iter().collect();
                if texto.trim().is_empty() {
                    continue;
                }
                // El locator lo construye `locator_at`, no este método. Así el que
                // se guarda en el índice es **el mismo** que produce la
                // navegación, con su cita y su contexto; dos formas de
                // construirlo serían dos formas de que dejaran de coincidir.
                let locator = self.locator_at(&NativePosition::Fragment {
                    href: recurso.href.clone(),
                    offset: u32::try_from(inicio).unwrap_or(u32::MAX),
                })?;
                salida.push((locator, texto));
            }
        }

        Ok(salida)
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
            return Err(NbError::PathNotAllowed);
        }

        let total = self.total();
        let objetivo = hint.unwrap_or(0.0);

        // Se elige la aparición más cercana a donde el usuario estaba leyendo, no
        // la primera del libro: una frase repetida en dos capítulos anclaría
        // siempre al primero, que casi nunca es el que se acaba de seleccionar.
        let mut mejor: Option<(&Recurso, usize, usize, f64)> = None;
        let mut acumulado = 0_usize;
        for recurso in &self.lomo {
            let caracteres = recurso.texto.chars().count();
            // Todas las apariciones, no la primera: una palabra que se repite en
            // el capítulo se anclaba siempre a su primera vez, lejos de donde se
            // había seleccionado.
            for (byte, fin) in buscar_cita(&recurso.texto, cita) {
                let offset = recurso.texto[..byte].chars().count();
                let progresion = if total == 0 {
                    0.0
                } else {
                    (acumulado + offset) as f64 / total as f64
                };
                let distancia = (progresion - objetivo).abs();
                if mejor.is_none_or(|(_, _, _, anterior)| distancia < anterior) {
                    mejor = Some((recurso, byte, fin, distancia));
                }
            }
            acumulado += caracteres;
        }

        let (recurso, byte, fin, _) = mejor.ok_or(NbError::DocumentNotFound)?;
        let offset = recurso.texto[..byte].chars().count();
        let caracteres = recurso.texto.chars().count();
        let contexto = contexto_de(&recurso.texto, byte, &recurso.texto[byte..fin])?;

        let progresion = if caracteres == 0 {
            0.0
        } else {
            offset as f64 / caracteres as f64
        };
        let total_progresion = if total == 0 {
            0.0
        } else {
            (self.acumulado_hasta(&recurso.href).unwrap_or(0) + offset) as f64 / total as f64
        };

        Locator::new(
            &recurso.href,
            "application/xhtml+xml",
            Locations {
                fragments: vec![format!("#char={offset}")],
                progression: Some(progresion.clamp(0.0, 1.0)),
                total_progression: Some(total_progresion.clamp(0.0, 1.0)),
                position: None,
            },
            Some(contexto),
        )
    }

    fn capabilities(&self) -> ReaderCapabilities {
        ReaderCapabilities {
            text_selection: true,
            internal_search: true,
            // Lo que hace a este formato distinto de un PDF, y lo que obliga a
            // que la posición no sea un número de página.
            reflow: true,
            typography: true,
            // Solo si el libro trae su narración: un EPUB sin superposiciones
            // se comporta exactamente como.
            synchronized_audio: !self.superposiciones.is_empty(),
            text_extraction: true,
        }
    }

    fn synchronized_audio(&self, href: &str) -> NbResult<Option<SynchronizedAudio>> {
        let Some(smil) = self.superposiciones.get(href) else {
            return Ok(None);
        };
        let mut contenedor = Archive::open(&self.ruta)?;
        let base_smil = smil.rsplit_once('/').map_or("", |(dir, _)| dir);
        let pares: Vec<Par> = pares_de(&contenedor.read_text(smil)?, base_smil)?
            .into_iter()
            .filter(|p| p.texto == href)
            .collect();
        // Un capítulo con su narración repartida entre varios archivos se escucha
        // hasta donde llega el primero: el reproductor sigue un archivo por
        // capítulo, y es como los publican casi todos. Se dice en el contrato.
        let Some(audio) = pares.first().map(|p| p.audio.clone()) else {
            return Ok(None);
        };
        let pares: Vec<Par> = pares.into_iter().filter(|p| p.audio == audio).collect();

        let ids: HashSet<String> = pares.iter().filter_map(|p| p.fragmento.clone()).collect();
        let (_, _, anclas) = texto_plano_con_anclas(&contenedor.read_text(href)?, &ids);
        let mut marcas = Vec::with_capacity(pares.len());
        for par in &pares {
            // Un fragmento que no está en el capítulo cae al principio: el tramo se
            // oye igual, y el lector no se va a otro sitio.
            let offset = par
                .fragmento
                .as_ref()
                .and_then(|f| anclas.get(f))
                .copied()
                .unwrap_or(0);
            marcas.push(crate::reader::provider::Marca {
                start_ms: par.inicio_ms,
                end_ms: par.fin_ms,
                locator: self.locator_at(&NativePosition::Fragment {
                    href: href.to_owned(),
                    offset: u32::try_from(offset).unwrap_or(u32::MAX),
                })?,
            });
        }

        let destino = self.recursos.as_deref().ok_or(NbError::FormatUnsupported)?;
        let ruta = extraer_recurso(&mut contenedor, "", &audio, destino)
            .ok_or(NbError::DocumentCorrupted)?;
        Ok(Some(SynchronizedAudio {
            href: href.to_owned(),
            path: ruta,
            duration_ms: marcas.iter().map(|m| m.end_ms).max().unwrap_or(0),
            marks: marcas,
        }))
    }
}

impl EpubDocument {
    fn titulo_de(&self, href: &str) -> Option<String> {
        self.navegacion
            .entries
            .iter()
            .find(|e| e.locator.href == href)
            .map(|e| e.title.clone())
    }
}

/// Fábrica del proveedor de EPUB.
pub struct EpubFactory {
    /// Dónde extraer las imágenes del libro para que el webview las cargue.
    recursos: Option<PathBuf>,
}

impl EpubFactory {
    /// Fábrica que extrae los recursos del libro a `recursos`.
    #[must_use]
    pub fn new(recursos: PathBuf) -> Self {
        Self {
            recursos: Some(recursos),
        }
    }

    /// Fábrica sin sitio donde extraer. Solo texto: para pruebas y para el
    /// indexador, que no pinta nada.
    #[must_use]
    pub const fn solo_texto() -> Self {
        Self { recursos: None }
    }
}

impl ProviderFactory for EpubFactory {
    fn media_type(&self) -> &'static str {
        MEDIA_TYPE
    }

    fn open(&self, path: &Path) -> NbResult<Box<dyn DocumentProvider>> {
        Ok(Box::new(EpubDocument::open_con_recursos(
            path,
            self.recursos.clone(),
        )?))
    }
}

/// Extrae un recurso del contenedor a la caché y devuelve su ruta.
///
/// Devuelve `None` cuando no se puede: un recurso que falta, una referencia que
/// se sale del contenedor o una escritura que no cabe. En todos esos casos el
/// marcado se queda con su referencia original, que no cargará nada; eso es
/// mejor que no pintar el capítulo por una imagen.
///
/// El nombre en la caché sale del **contenido**, no del nombre original: dos
/// libros pueden traer `images/cover.jpg` y no ser la misma imagen, y un nombre
/// tomado del documento sería un nombre elegido por un desconocido.
fn extraer_recurso(
    contenedor: &mut Archive,
    base: &str,
    referencia: &str,
    destino: &Path,
) -> Option<String> {
    let interna = resolver_ruta(base, referencia)?;
    let bytes = contenedor.read(&interna).ok()?;

    let extension = Path::new(&interna)
        .extension()
        .and_then(|e| e.to_str())
        .filter(|e| e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or("bin");

    // La identidad sale del contenido: dos libros pueden traer `images/cover.jpg`
    // y no ser la misma imagen, y un nombre tomado del documento sería un nombre
    // elegido por un desconocido.
    let (huella, _) = crate::library::hash_reader(bytes.as_slice()).ok()?;
    // El prefijo del algoritmo lleva dos puntos, y eso no es un nombre de
    // archivo válido en Windows. Se queda solo el resumen, que es lo que
    // distingue una imagen de otra.
    let nombre = huella.as_str().rsplit(":").next().unwrap_or_default();
    let archivo = destino.join(format!("{nombre}.{extension}"));

    if !archivo.exists() {
        std::fs::create_dir_all(destino).ok()?;
        crate::paths::write_atomic(&archivo, |temporal| {
            std::fs::write(temporal, &bytes).map_err(|_| NbError::StorageFailure)
        })
        .ok()?;
    }

    Some(archivo.to_string_lossy().into_owned())
}

/// Resuelve una referencia relativa contra la carpeta del capítulo.
///
/// Devuelve `None` si se sale del contenedor. Un `../../../etc/passwd` dentro de
/// un EPUB no es una imagen: es un intento, y el contenedor no tiene por qué
/// haberlo puesto ahí sin querer.
fn resolver_ruta(base: &str, referencia: &str) -> Option<String> {
    let limpia = referencia.split(['?', '#']).next()?.trim();
    if limpia.is_empty() {
        return None;
    }

    let mut partes: Vec<&str> = if limpia.starts_with('/') {
        Vec::new()
    } else {
        base.split('/').filter(|p| !p.is_empty()).collect()
    };

    for parte in limpia.split('/') {
        match parte {
            "" | "." => {}
            ".." => {
                // Salirse del contenedor no se corrige: se rechaza.
                partes.pop()?;
            }
            otro => partes.push(otro),
        }
    }

    Some(partes.join("/"))
}

/// Las superposiciones del paquete: qué SMIL acompaña a cada capítulo.
///
/// Un `item` del manifiesto lo dice con `media-overlay`, que es el identificador de
/// otro `item`. Se lee aparte del lomo porque solo lo necesitan los libros que la
/// traen, y leerlo junto habría cambiado la forma de lo que usan todos los demás.
fn superposiciones_de(
    manifiesto: &[ItemDelManifiesto],
    base: &str,
    opf: &str,
) -> HashMap<String, String> {
    let mut lector = Reader::from_str(opf);
    lector.config_mut().check_end_names = false;
    let mut buf = Vec::new();
    let mut salida = HashMap::new();
    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Empty(e) | Event::Start(e)) if e.name().as_ref().ends_with(b"item") => {
                let atributo = |k: &[u8]| {
                    e.attributes().flatten().find_map(|a| {
                        (a.key.as_ref() == k)
                            .then(|| String::from_utf8_lossy(&a.value).into_owned())
                    })
                };
                let (Some(href), Some(superposicion)) =
                    (atributo(b"href"), atributo(b"media-overlay"))
                else {
                    buf.clear();
                    continue;
                };
                let smil = manifiesto
                    .iter()
                    .find(|(id, _, _)| *id == superposicion)
                    .and_then(|(_, ruta, _)| resolver(base, ruta));
                if let (Some(capitulo), Some(smil)) = (resolver(base, &href), smil) {
                    salida.insert(capitulo, smil);
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    salida
}

/// Un `par` de una superposición: un trozo de texto y el tramo de audio que lo lee.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Par {
    /// El capítulo, dentro del contenedor.
    texto: String,
    /// El identificador del elemento, sin `#`.
    fragmento: Option<String>,
    /// El audio, dentro del contenedor.
    audio: String,
    inicio_ms: u64,
    fin_ms: u64,
}

/// Los `par` de un SMIL, en el orden en que suenan.
///
/// Un `par` sin `text` o sin `audio`, o con un audio sin final, se omite: no hay
/// nada que seguir con él. Las rutas se resuelven contra la carpeta del SMIL y se
/// validan como cualquier otra del contenedor.
fn pares_de(smil: &str, base: &str) -> NbResult<Vec<Par>> {
    let mut lector = Reader::from_str(smil);
    lector.config_mut().check_end_names = false;
    let mut buf = Vec::new();
    let mut pares = Vec::new();
    let mut texto: Option<(String, Option<String>)> = None;
    let mut audio: Option<(String, u64, Option<u64>)> = None;
    let mut dentro = false;

    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Start(e) | Event::Empty(e)) => {
                let atributo = |k: &[u8]| {
                    e.attributes().flatten().find_map(|a| {
                        (a.key.as_ref() == k)
                            .then(|| String::from_utf8_lossy(&a.value).into_owned())
                    })
                };
                match e.local_name().as_ref() {
                    b"par" => {
                        dentro = true;
                        texto = None;
                        audio = None;
                    }
                    b"text" if dentro => {
                        texto = atributo(b"src").and_then(|src| {
                            let fragmento = src.split_once('#').map(|(_, f)| f.to_owned());
                            resolver_ruta(base, &src).map(|ruta| (ruta, fragmento))
                        });
                    }
                    b"audio" if dentro => {
                        audio = atributo(b"src").and_then(|src| {
                            let inicio = atributo(b"clipBegin").map_or(Some(0), |v| reloj(&v))?;
                            let fin = atributo(b"clipEnd").and_then(|v| reloj(&v));
                            resolver_ruta(base, &src).map(|ruta| (ruta, inicio, fin))
                        });
                    }
                    _ => {}
                }
            }
            Ok(Event::End(e)) if e.local_name().as_ref() == b"par" => {
                dentro = false;
                if let (Some((texto, fragmento)), Some((audio, inicio, Some(fin)))) =
                    (texto.take(), audio.take())
                {
                    if fin > inicio {
                        pares.push(Par {
                            texto,
                            fragmento,
                            audio,
                            inicio_ms: inicio,
                            fin_ms: fin,
                        });
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(NbError::DocumentCorrupted),
            _ => {}
        }
        buf.clear();
    }
    Ok(pares)
}

/// Un valor de reloj de SMIL, en milisegundos.
///
/// Admite las tres formas de la especificación: `1:02:03.5` (con horas),
/// `02:03.5` (sin horas) y un número con su unidad -`3.5s`, `350ms`, `2min`,
/// `1h`-, o sin unidad, que son segundos.
fn reloj(valor: &str) -> Option<u64> {
    let valor = valor.trim();
    let segundos = if valor.contains(':') {
        let partes: Vec<&str> = valor.split(':').collect();
        let numeros: Option<Vec<f64>> = partes.iter().map(|p| p.parse::<f64>().ok()).collect();
        match numeros?.as_slice() {
            [h, m, s] => h * 3600.0 + m * 60.0 + s,
            [m, s] => m * 60.0 + s,
            _ => return None,
        }
    } else {
        let (numero, factor) = if let Some(n) = valor.strip_suffix("ms") {
            (n, 0.001)
        } else if let Some(n) = valor.strip_suffix("min") {
            (n, 60.0)
        } else if let Some(n) = valor.strip_suffix('h') {
            (n, 3600.0)
        } else if let Some(n) = valor.strip_suffix('s') {
            (n, 1.0)
        } else {
            (valor, 1.0)
        };
        numero.trim().parse::<f64>().ok()? * factor
    };
    (segundos.is_finite() && segundos >= 0.0).then(|| (segundos * 1000.0).round() as u64)
}

/// Una entrada del manifiesto: identificador, ruta y propiedades declaradas.
type ItemDelManifiesto = (String, String, Option<String>);

/// Lee el manifiesto y el orden del lomo del paquete.
fn leer_lomo(opf: &str) -> NbResult<(Vec<ItemDelManifiesto>, Vec<String>)> {
    let mut lector = Reader::from_str(opf);
    lector.config_mut().check_end_names = false;
    let mut buf = Vec::new();

    let mut manifiesto = Vec::new();
    let mut orden = Vec::new();

    loop {
        match lector.read_event_into(&mut buf) {
            Ok(Event::Empty(e) | Event::Start(e)) => {
                let nombre_completo = e.name();
                let nombre = nombre_completo.as_ref();
                if nombre.ends_with(b"item") && !nombre.ends_with(b"itemref") {
                    let atributo = |k: &[u8]| {
                        e.attributes().flatten().find_map(|a| {
                            (a.key.as_ref() == k)
                                .then(|| String::from_utf8_lossy(&a.value).into_owned())
                        })
                    };
                    if let (Some(id), Some(href)) = (atributo(b"id"), atributo(b"href")) {
                        manifiesto.push((id, href, atributo(b"properties")));
                    }
                } else if nombre.ends_with(b"itemref") {
                    if let Some(idref) = e.attributes().flatten().find_map(|a| {
                        (a.key.as_ref() == b"idref")
                            .then(|| String::from_utf8_lossy(&a.value).into_owned())
                    }) {
                        orden.push(idref);
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(NbError::DocumentCorrupted),
            _ => {}
        }
        buf.clear();
    }

    Ok((manifiesto, orden))
}

/// Resuelve una ruta relativa al paquete y la valida.
/// El `src` de un `content` de NCX.
fn atributo_src(e: &quick_xml::events::BytesStart<'_>) -> Option<String> {
    e.attributes().flatten().find_map(|a| {
        (a.key.as_ref() == b"src").then(|| String::from_utf8_lossy(&a.value).into_owned())
    })
}

fn resolver(base: &str, href: &str) -> Option<String> {
    // Se normaliza antes de validar: un `../Text/c1.xhtml` legítimo -el NCX en
    // su propia carpeta, el lomo en otra- se pegaba tal cual a la base y la
    // validación lo rechazaba como recorrido de directorios. Eran 3.836 avisos en
    // la instalación real y capítulos que no se leían. Lo que de verdad se
    // sale del contenedor lo sigue rechazando `resolver_ruta`.
    let completa = resolver_ruta(base, href)?;
    crate::security::validate_archive_entry(&completa)
        .ok()
        .map(|_| completa)
}

/// Marca de fin de bloque en el texto sin normalizar.
///
/// Hace de espacio al normalizar —como el salto de línea que ponía la versión
/// anterior, así que el texto que sale es **idéntico**— y además dice dónde acaba
/// un bloque. No puede aparecer en un XHTML: el carácter nulo no es válido en XML.
const FIN_DE_BLOQUE: char = '\0';

/// Extrae el texto plano de un XHTML, con dónde empieza cada bloque.
///
/// Es el sistema de coordenadas de este formato: los desplazamientos de los
/// locators son sobre esto, y esto no cambia porque alguien agrande la letra.
///
/// # Por qué los bloques se apuntan aparte y no con saltos de línea
///
/// Porque el texto **no puede cambiar**: cada anotación, cada posición de lectura
/// y cada fragmento indexado guardan desplazamientos sobre él. Antes los
/// bloques se marcaban con un salto de línea que la normalización convertía en
/// espacio, y con él se perdía dónde acababa un párrafo. Ahora se marcan con
/// [`FIN_DE_BLOQUE`], que se normaliza igual, y se anota su posición. Una prueba
/// compara el texto con el de la versión anterior sobre libros reales.
fn texto_plano(xhtml: &str) -> (String, Vec<usize>) {
    let (texto, fronteras, _) = texto_plano_con_anclas(xhtml, &HashSet::new());
    (texto, fronteras)
}

/// Marca de dónde empieza un elemento con identificador, en el texto sin
/// normalizar. Como [`FIN_DE_BLOQUE`], no puede aparecer en un XHTML.
const ANCLA: char = '\u{1}';

/// El texto plano, y además **en qué carácter empieza** cada elemento cuyo
/// identificador se pida.
///
/// Lo necesita la narración del propio libro: una superposición de EPUB 3 dice
/// "este audio va con `capitulo.xhtml#f12`", y un fragmento por identificador no es
/// un Locator. Se calcula en la misma pasada que el texto, con una marca que la
/// normalización quita sin dejar rastro, para que el desplazamiento sea sobre
/// **exactamente** el mismo texto que usan las anotaciones y la posición de
/// lectura. Calcularlo aparte sería una segunda cuenta que tarde o temprano
/// discreparía de la primera.
fn texto_plano_con_anclas(
    xhtml: &str,
    anclas: &HashSet<String>,
) -> (String, Vec<usize>, HashMap<String, usize>) {
    let mut lector = Reader::from_str(xhtml);
    lector.config_mut().check_end_names = false;
    let mut buf = Vec::new();
    let mut salida = String::new();
    let mut descartando = 0_usize;
    let mut en_orden = Vec::new();

    loop {
        let evento = lector.read_event_into(&mut buf);
        if let Ok(Event::Start(e) | Event::Empty(e)) = &evento {
            let sin_texto = matches!(e.name().as_ref(), b"script" | b"style");
            if !anclas.is_empty() && descartando == 0 && !sin_texto {
                let id = e.attributes().flatten().find_map(|a| {
                    (a.key.as_ref() == b"id")
                        .then(|| String::from_utf8_lossy(&a.value).into_owned())
                });
                if let Some(id) = id.filter(|id| anclas.contains(id)) {
                    salida.push(ANCLA);
                    en_orden.push(id);
                }
            }
        }
        match evento {
            Ok(Event::Start(e)) => {
                let n = e.name();
                if matches!(n.as_ref(), b"script" | b"style") {
                    descartando += 1;
                }
            }
            Ok(Event::End(e)) => {
                let n = e.name();
                if matches!(n.as_ref(), b"script" | b"style") {
                    descartando = descartando.saturating_sub(1);
                } else if matches!(
                    n.as_ref(),
                    b"p" | b"div" | b"br" | b"li" | b"h1" | b"h2" | b"h3" | b"h4" | b"h5" | b"h6"
                ) {
                    salida.push(FIN_DE_BLOQUE);
                }
            }
            Ok(Event::Text(t)) => {
                if descartando == 0 {
                    if let Ok(texto) = t.decode() {
                        salida.push_str(&texto);
                    }
                }
            }
            Ok(Event::GeneralRef(r)) => {
                if descartando == 0 {
                    if let Some(c) = crate::epub::resolver_entidad_publica(&r) {
                        salida.push(c);
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }

    normalizar_con_anclas(&salida, &en_orden)
}

/// Colapsa el espacio en blanco como `split_whitespace` seguido de unir con un
/// espacio —sin espacio al principio ni al final, y una racha de espacio en uno—,
/// y apunta dónde empieza la palabra que sigue a un [`FIN_DE_BLOQUE`].
///
/// El espacio en blanco del marcado no es contenido: normalizarlo hace que los
/// desplazamientos no dependan de cómo indentó el archivo su generador.
/// Caracteres que no se ven y que algunos libros ponen entre palabras: el
/// "word joiner" y el BOM que impiden un corte de línea, los espacios de ancho
/// cero y el guion blando.
fn es_invisible(c: char) -> bool {
    matches!(
        c,
        '\u{feff}' | '\u{2060}' | '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{ad}'
    )
}

/// Dónde aparece la cita en el texto, cada vez, en bytes de inicio y fin.
///
/// Primero tal cual; si no aparece, sin contar los caracteres invisibles de los
/// dos lados ni los espacios. La cita llega de la página que se ve, y la página no siempre
/// conserva esos caracteres: sin esto, un párrafo con "May.\u{feff}—" no se
/// anclaba y la posición dejaba de avanzar al leer. El resultado señala el
/// tramo del texto original, así que el `#char` es el de siempre.
fn buscar_cita(texto: &str, cita: &str) -> Vec<(usize, usize)> {
    let exactas: Vec<(usize, usize)> = texto
        .match_indices(cita)
        .map(|(byte, _)| (byte, byte + cita.len()))
        .collect();
    if !exactas.is_empty() {
        return exactas;
    }
    // Sin espacios tampoco: un salto de línea (`<br>`) llega de la página
    // pegado y en el texto es un espacio.
    let ignorar = |c: char| es_invisible(c) || c.is_whitespace();
    let objetivo: String = cita.chars().filter(|c| !ignorar(*c)).collect();
    if objetivo.is_empty() {
        return Vec::new();
    }
    let mut plegado = String::with_capacity(texto.len());
    let mut origen: Vec<usize> = Vec::with_capacity(texto.len());
    for (byte, c) in texto.char_indices() {
        if ignorar(c) {
            continue;
        }
        for _ in 0..c.len_utf8() {
            origen.push(byte);
        }
        plegado.push(c);
    }
    plegado
        .match_indices(&objetivo)
        .filter_map(|(i, _)| {
            let inicio = *origen.get(i)?;
            let fin_byte = *origen.get(i + objetivo.len() - 1)?;
            let fin = fin_byte + texto[fin_byte..].chars().next()?.len_utf8();
            Some((inicio, fin))
        })
        .collect()
}

#[cfg(test)]
fn normalizar(bruto: &str) -> (String, Vec<usize>) {
    let (texto, fronteras, _) = normalizar_con_anclas(bruto, &[]);
    (texto, fronteras)
}

/// La normalización, apuntando además dónde cae cada [`ANCLA`]: en el carácter que
/// la sigue, que es donde empieza el texto del elemento que la llevaba. Un ancla
/// no es espacio ni texto, así que el texto sale igual que sin ella.
fn normalizar_con_anclas(
    bruto: &str,
    nombres: &[String],
) -> (String, Vec<usize>, HashMap<String, usize>) {
    let mut texto = String::with_capacity(bruto.len());
    let mut fronteras = Vec::new();
    let mut caracteres = 0_usize;
    let mut en_blanco = false;
    let mut bloque_cerrado = false;
    let mut nombres = nombres.iter();
    let mut pendientes: Vec<&String> = Vec::new();
    let mut anclas = HashMap::new();

    for c in bruto.chars() {
        if c == ANCLA {
            if let Some(nombre) = nombres.next() {
                pendientes.push(nombre);
            }
            continue;
        }
        if c == FIN_DE_BLOQUE || c.is_whitespace() {
            en_blanco = true;
            bloque_cerrado |= c == FIN_DE_BLOQUE;
            continue;
        }
        if en_blanco && caracteres > 0 {
            texto.push(' ');
            caracteres += 1;
            if bloque_cerrado {
                fronteras.push(caracteres);
            }
        }
        en_blanco = false;
        bloque_cerrado = false;
        for nombre in pendientes.drain(..) {
            anclas.insert(nombre.clone(), caracteres);
        }
        texto.push(c);
        caracteres += 1;
    }
    // Un elemento vacío al final del capítulo cae en su final.
    for nombre in pendientes {
        anclas.insert(nombre.clone(), caracteres);
    }
    (texto, fronteras, anclas)
}

#[cfg(test)]
mod pruebas_de_recursos {

    #[test]
    fn una_cita_se_ancla_aunque_la_pagina_pierda_los_caracteres_invisibles() {
        let texto = "Fin del día. 4 May.\u{feff}—I found that my landlord";
        let (i, f) = super::buscar_cita(texto, "May.—I found")[0];
        assert_eq!(&texto[i..f], "May.\u{feff}—I found");
        let b = texto.find("landlord").expect("está");
        assert_eq!(super::buscar_cita(texto, "landlord"), vec![(b, b + 8)]);
        assert!(super::buscar_cita(texto, "no está").is_empty());
        let verso = "“Your friend, “Dracula.” 4 May.";
        let (i, f) = super::buscar_cita(verso, "“Your friend,“Dracula.”")[0];
        assert_eq!(&verso[i..f], "“Your friend, “Dracula.”");
    }

    #[test]
    fn una_palabra_repetida_se_ancla_en_todas_sus_apariciones() {
        let texto = "have one, have two, have three";
        assert_eq!(super::buscar_cita(texto, "have").len(), 3);
    }

    use super::{resolver, resolver_ruta};

    /// **Un `../` legítimo dentro del contenedor se resuelve**. Se pegaba a
    /// la base sin normalizar y se rechazaba como recorrido de directorios: 3.836
    /// avisos y capítulos sin leer en la instalación real.
    #[test]
    fn un_href_con_subida_dentro_del_contenedor_se_resuelve() {
        assert_eq!(
            resolver("OEBPS/toc", "../Text/c1.xhtml#a"),
            Some("OEBPS/Text/c1.xhtml".to_owned())
        );
        assert_eq!(resolver("OEBPS", "../../fuera.xhtml"), None);
    }

    /// Las referencias de un capítulo se resuelven contra **su** carpeta.
    ///
    /// Sin esto no había imágenes: `<img src="../Images/x.jpg">` lo resolvía el
    /// webview contra la dirección de la aplicación, donde no hay nada, y un
    /// libro ilustrado se leía como un libro sin ilustrar.
    #[test]
    fn una_referencia_relativa_se_resuelve_contra_el_capitulo() {
        assert_eq!(
            resolver_ruta("OEBPS/Text", "../Images/portada.jpg"),
            Some("OEBPS/Images/portada.jpg".to_owned())
        );
        assert_eq!(
            resolver_ruta("OEBPS", "images/x.png"),
            Some("OEBPS/images/x.png".to_owned())
        );
        assert_eq!(
            resolver_ruta("OEBPS/Text", "./mismo.jpg"),
            Some("OEBPS/Text/mismo.jpg".to_owned())
        );
    }

    /// Una referencia que se sale del contenedor **no se corrige: se rechaza**.
    ///
    /// Un `../../../etc/passwd` dentro de un EPUB no es una imagen mal escrita:
    /// es un intento. Recortarlo hasta que quepa lo convertiría en una lectura
    /// de archivo con otro nombre, que es peor que no pintar la imagen.
    #[test]
    fn una_referencia_que_se_sale_del_contenedor_se_rechaza() {
        assert_eq!(resolver_ruta("OEBPS", "../../../etc/passwd"), None);
        assert_eq!(resolver_ruta("", ".."), None);
        assert_eq!(resolver_ruta("OEBPS/Text", "../../../../x"), None);
    }

    /// La consulta y el ancla no forman parte del nombre del archivo.
    #[test]
    fn la_consulta_y_el_ancla_no_entran_en_el_nombre() {
        assert_eq!(
            resolver_ruta("OEBPS", "img.svg#capa"),
            Some("OEBPS/img.svg".to_owned())
        );
        assert_eq!(
            resolver_ruta("OEBPS", "img.png?v=2"),
            Some("OEBPS/img.png".to_owned())
        );
        assert_eq!(resolver_ruta("OEBPS", "   "), None);
    }

    /// Una ruta absoluta dentro del contenedor cuelga de su raíz, no del
    /// capítulo.
    #[test]
    fn una_ruta_absoluta_cuelga_de_la_raiz_del_contenedor() {
        assert_eq!(
            resolver_ruta("OEBPS/Text", "/OEBPS/Images/x.jpg"),
            Some("OEBPS/Images/x.jpg".to_owned())
        );
    }
}

#[cfg(test)]
mod pruebas_de_bloques {
    use super::{normalizar, texto_plano, texto_plano_con_anclas, FIN_DE_BLOQUE};
    use quick_xml::events::Event;
    use quick_xml::Reader;

    /// La extracción **tal como era**, copiada aquí para poder
    /// compararla. Si alguna vez dejan de coincidir, se han movido todas las
    /// anotaciones y posiciones guardadas sobre libros EPUB.
    fn texto_plano_anterior(xhtml: &str) -> String {
        let mut lector = Reader::from_str(xhtml);
        lector.config_mut().check_end_names = false;
        let mut buf = Vec::new();
        let mut salida = String::new();
        let mut descartando = 0_usize;
        loop {
            match lector.read_event_into(&mut buf) {
                Ok(Event::Start(e)) => {
                    if matches!(e.name().as_ref(), b"script" | b"style") {
                        descartando += 1;
                    }
                }
                Ok(Event::End(e)) => {
                    let n = e.name();
                    if matches!(n.as_ref(), b"script" | b"style") {
                        descartando = descartando.saturating_sub(1);
                    } else if matches!(
                        n.as_ref(),
                        b"p" | b"div"
                            | b"br"
                            | b"li"
                            | b"h1"
                            | b"h2"
                            | b"h3"
                            | b"h4"
                            | b"h5"
                            | b"h6"
                    ) && !salida.ends_with('\n')
                    {
                        salida.push('\n');
                    }
                }
                Ok(Event::Text(t)) => {
                    if descartando == 0 {
                        if let Ok(texto) = t.decode() {
                            salida.push_str(&texto);
                        }
                    }
                }
                Ok(Event::GeneralRef(r)) => {
                    if descartando == 0 {
                        if let Some(c) = crate::epub::resolver_entidad_publica(&r) {
                            salida.push(c);
                        }
                    }
                }
                Ok(Event::Eof) | Err(_) => break,
                _ => {}
            }
            buf.clear();
        }
        salida.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    const MUESTRAS: &[&str] = &[
        "<html><body><h1>Capítulo uno</h1><p>Era una   vez\n un reino.</p><p>Y otro.</p></body></html>",
        "<p>a</p><p></p><p>b</p>",
        "<div><p>dentro</p></div>después<br/>verso<br/>otro verso",
        "  <p>\u{a0}con espacio duro\u{a0}</p>\t<p>y tabulador\t</p>  ",
        "<ul><li>uno</li><li>dos</li></ul><table><tr><td>a</td><td>b</td></tr></table>",
        "<p>con &amp; entidades &eacute; y <em>énfasis</em> dentro</p><script>no</script><p>fin</p>",
        "texto sin ningún bloque",
        "",
        "<p></p><p></p>",
    ];

    /// **El texto no cambia.** Es la condición para poder apuntar los bloques: las
    /// anotaciones guardan desplazamientos sobre este texto.
    #[test]
    fn el_texto_es_el_mismo_que_antes_de_apuntar_los_bloques() {
        for muestra in MUESTRAS {
            assert_eq!(
                texto_plano(muestra).0,
                texto_plano_anterior(muestra),
                "{muestra}"
            );
        }
    }

    /// Pedir dónde empieza cada elemento **no cambia el texto**: cada
    /// anotación y cada posición guardan desplazamientos sobre él.
    #[test]
    fn buscar_las_anclas_no_mueve_ni_un_caracter_del_texto() {
        let xhtml = r#"<html><body><h1 id="t">Título</h1>
            <p id="a">Uno  <span id="dentro">dos</span></p>
            <p id="b"/><p>tres <br id="br"/> cuatro</p><p id="c">cinco</p>
            <script id="s">no</script></body></html>"#;
        let ids: std::collections::HashSet<String> =
            ["t", "a", "dentro", "b", "br", "c", "s", "no-existe"]
                .iter()
                .map(|s| (*s).to_owned())
                .collect();
        let (con, fronteras_con, anclas) = texto_plano_con_anclas(xhtml, &ids);
        let (sin, fronteras_sin) = texto_plano(xhtml);
        assert_eq!(con, sin);
        assert_eq!(fronteras_con, fronteras_sin);

        let empieza = |id: &str| con.chars().skip(anclas[id]).take(5).collect::<String>();
        assert_eq!(empieza("t"), "Títul");
        assert_eq!(empieza("a"), "Uno d");
        assert_eq!(empieza("dentro"), "dos t");
        // Un elemento vacío cae donde empieza lo siguiente, y un `br` en medio de
        // una frase, en la palabra que lo sigue.
        assert_eq!(empieza("b"), "tres ");
        assert_eq!(empieza("br"), "cuatr");
        assert_eq!(empieza("c"), "cinco");
        // Lo que está dentro de un script no es texto, y lo que no está, no está.
        assert!(!anclas.contains_key("s"));
        assert!(!anclas.contains_key("no-existe"));
    }

    /// Cada frontera es el comienzo de una palabra que sigue a un bloque cerrado,
    /// y solo esas: no hay frontera donde no acaba ningún bloque.
    #[test]
    fn las_fronteras_marcan_donde_empieza_cada_bloque() {
        let (texto, fronteras) = texto_plano(
            "<h1>Título</h1><p>Primer párrafo con <em>énfasis</em>.</p><p>Segundo.</p>fuera",
        );
        let empiezan: Vec<String> = fronteras
            .iter()
            .map(|&f| texto.chars().skip(f).take(6).collect())
            .collect();
        assert_eq!(empiezan, vec!["Primer", "Segund", "fuera"]);
        assert_eq!(
            normalizar(&format!("{FIN_DE_BLOQUE}  a")).1,
            Vec::<usize>::new()
        );
    }

    /// Lo mismo sobre **libros reales**, capítulo a capítulo, con el corpus de la
    /// máquina de desarrollo. Se salta sin `NB_BOOKS_CORPUS`. No imprime nada de
    /// los libros: solo cuántos capítulos se compararon.
    #[test]
    fn el_texto_de_libros_reales_es_el_mismo_que_antes() {
        let Some(raiz) = std::env::var_os("NB_BOOKS_CORPUS").map(std::path::PathBuf::from) else {
            return;
        };
        let mut libros = 0;
        let mut capitulos = 0;
        let mut autores: Vec<_> = std::fs::read_dir(&raiz)
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .map(|e| e.path())
            .collect();
        autores.sort();
        'fuera: for autor in autores {
            let mut archivos: Vec<_> = std::fs::read_dir(&autor)
                .into_iter()
                .flatten()
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| {
                    p.extension()
                        .is_some_and(|x| x.eq_ignore_ascii_case("epub"))
                })
                .collect();
            archivos.sort();
            for archivo in archivos {
                let Ok(mut contenedor) = crate::zip::Archive::open(&archivo) else {
                    continue;
                };
                let nombres: Vec<String> = contenedor
                    .entries()
                    .iter()
                    .map(|e| e.name.clone())
                    .filter(|n| {
                        let n = n.to_ascii_lowercase();
                        n.ends_with(".xhtml") || n.ends_with(".html") || n.ends_with(".htm")
                    })
                    .collect();
                for nombre in nombres {
                    let Ok(xhtml) = contenedor.read_text(&nombre) else {
                        continue;
                    };
                    assert_eq!(
                        texto_plano(&xhtml).0,
                        texto_plano_anterior(&xhtml),
                        "un capítulo real cambió de texto (libro {libros}, capítulo {capitulos})"
                    );
                    capitulos += 1;
                }
                libros += 1;
                if libros >= 40 {
                    break 'fuera;
                }
            }
        }
        eprintln!("{libros} libros reales, {capitulos} capítulos con el mismo texto");
    }
}
