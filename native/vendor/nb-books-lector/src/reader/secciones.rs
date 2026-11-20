//! Un documento hecho de secciones con título y texto.
//!
//! Es la forma que comparten todos los formatos que se leen como texto
//! corrido: cada sección tiene un identificador, un título y su contenido, y el
//! documento entero es su suma en orden.
//!
//! # Por qué vive aquí y no en cada formato
//!
//! Porque lo que hace difícil un proveedor **no es el formato**: es la cascada
//! de anclaje de [ADR-004], la progresión acumulada, la extracción de texto y
//! la negociación de capacidades. Escrito una vez, un formato nuevo solo tiene
//! que decir cuáles son sus secciones.
//!
//! Nació como el proveedor simulado, que es el que ejercitó todo eso
//! antes de que existiera un formato real. Después se separó de él para
//! que una extensión pudiera aportar un formato **sin traer su propio lector**:
//! el lector es nuestro, y por eso el modelo de Locator y el saneado no
//! dependen de código de terceros.
//!
//! [ADR-004]: ../../../docs/adr/decisions/ADR-004-reader-locator-model.md

use super::locator::{Locations, Locator, TextContext};
use super::provider::{
    DocumentProvider, NativePosition, Navigation, NavigationEntry, Precision, ReaderCapabilities,
    Rendered, Resolution,
};
use crate::error::{NbError, NbResult};

/// Un seccion del documento simulado: un capítulo con su texto.
#[derive(Debug, Clone)]
pub struct Seccion {
    pub href: String,
    pub title: String,
    pub text: String,
}

/// Documento simulado.
pub struct DocumentoDeSecciones {
    secciones: Vec<Seccion>,
    capacidades: ReaderCapabilities,
    tipo_de_medio: String,
}

impl DocumentoDeSecciones {
    /// Construye un documento a medida.
    #[must_use]
    pub fn new(
        tipo_de_medio: impl Into<String>,
        secciones: Vec<Seccion>,
        capacidades: ReaderCapabilities,
    ) -> Self {
        Self {
            secciones,
            capacidades,
            tipo_de_medio: tipo_de_medio.into(),
        }
    }

    /// Sustituye el texto de un seccion, simulando que el documento cambió de
    /// edición.
    ///
    /// Es lo que hace observable la degradación: un fragmento que deja de
    /// resolver, una cita que sigue estando, o ninguna de las dos.
    pub fn reescribir(&mut self, href: &str, texto: &str) {
        if let Some(seccion) = self.secciones.iter_mut().find(|r| r.href == href) {
            seccion.text = texto.to_owned();
        }
    }

    /// Elimina un seccion, simulando que un capítulo desapareció.
    pub fn eliminar(&mut self, href: &str) {
        self.secciones.retain(|r| r.href != href);
    }

    fn total(&self) -> usize {
        self.secciones.iter().map(|r| r.text.chars().count()).sum()
    }

    fn seccion(&self, href: &str) -> Option<&Seccion> {
        self.secciones.iter().find(|r| r.href == href)
    }

    /// Progresión total acumulada hasta el principio de un seccion.
    fn acumulado_hasta(&self, href: &str) -> Option<usize> {
        let mut acumulado = 0;
        for seccion in &self.secciones {
            if seccion.href == href {
                return Some(acumulado);
            }
            acumulado += seccion.text.chars().count();
        }
        None
    }
}

impl DocumentProvider for DocumentoDeSecciones {
    fn media_type(&self) -> &str {
        &self.tipo_de_medio
    }

    fn navigation(&self) -> NbResult<Navigation> {
        let entries = self
            .secciones
            .iter()
            .map(|r| {
                Ok(NavigationEntry {
                    title: r.title.clone(),
                    locator: self.locator_at(&NativePosition::Fragment {
                        href: r.href.clone(),
                        offset: 0,
                    })?,
                    children: Vec::new(),
                })
            })
            .collect::<NbResult<Vec<_>>>()?;

        Ok(Navigation { entries })
    }

    fn locator_at(&self, position: &NativePosition) -> NbResult<Locator> {
        let NativePosition::Fragment { href, offset } = position else {
            // Este formato es reflowable: no tiene páginas ni línea temporal.
            return Err(NbError::PathNotAllowed);
        };

        let seccion = self.seccion(href).ok_or(NbError::PathNotAllowed)?;
        let caracteres = seccion.text.chars().count();
        let offset = (*offset as usize).min(caracteres);

        let progresion = if caracteres == 0 {
            0.0
        } else {
            offset as f64 / caracteres as f64
        };
        let total = self.total();
        let total_progresion = if total == 0 {
            0.0
        } else {
            (self.acumulado_hasta(href).unwrap_or(0) + offset) as f64 / total as f64
        };

        // La cita con su contexto: sin ella, un fragmento que deja de resolver
        // se lleva la anotación por delante.
        let texto: Vec<char> = seccion.text.chars().collect();
        let fin = (offset + 32).min(texto.len());
        let cita: String = texto[offset..fin].iter().collect();
        let antes: String = texto[offset.saturating_sub(16)..offset].iter().collect();
        let despues: String = texto[fin..(fin + 16).min(texto.len())].iter().collect();

        let contexto = TextContext::new(
            (!antes.is_empty()).then_some(antes.as_str()),
            if cita.is_empty() { "-" } else { &cita },
            (!despues.is_empty()).then_some(despues.as_str()),
        )
        .ok();

        Locator::new(
            href,
            "application/xhtml+xml",
            Locations {
                fragments: vec![format!("#char={offset}")],
                progression: Some(progresion),
                total_progression: Some(total_progresion),
                position: None,
            },
            contexto,
        )
        .map(|l| l.with_title(&seccion.title))
    }

    fn resolve(&self, locator: &Locator) -> NbResult<Resolution> {
        let seccion = self.seccion(&locator.href);

        // --- 1. Fragmento canónico, **corroborado** ---
        //
        // Que un desplazamiento esté dentro de rango no prueba que siga
        // señalando lo mismo: si al documento le añaden un prólogo, el
        // desplazamiento sigue siendo válido y apunta a otra frase. Por eso,
        // cuando hay cita, el fragmento solo cuenta como exacto si el texto que
        // hay ahí es el que se guardó. Sin esa corroboración, la cascada nunca
        // llegaría al segundo escalón y las anotaciones se desplazarían en
        // silencio, que es justo lo que ADR-004 existe para impedir.
        if let Some(seccion) = seccion {
            if let Some(offset) = locator.locations.fragments.iter().find_map(|f| {
                f.strip_prefix("#char=")
                    .and_then(|n| n.parse::<usize>().ok())
            }) {
                let caracteres = seccion.text.chars().count();
                let corrobora = match locator.text.as_ref() {
                    Some(contexto) => {
                        seccion
                            .text
                            .chars()
                            .skip(offset)
                            .take(contexto.highlight.chars().count())
                            .collect::<String>()
                            == contexto.highlight
                    }
                    // Sin cita no hay nada con lo que corroborar: se acepta el
                    // fragmento, que es lo único que hay.
                    None => offset <= caracteres,
                };

                if corrobora && offset <= caracteres {
                    return Ok(Resolution {
                        position: NativePosition::Fragment {
                            href: seccion.href.clone(),
                            offset: u32::try_from(offset).unwrap_or(u32::MAX),
                        },
                        precision: Precision::Exact,
                    });
                }
            }
        }

        // --- 2. Cita textual, en cualquier seccion ---
        //
        // Se busca en todos y no solo en el original: un capítulo puede haberse
        // dividido o renombrado entre ediciones, y la cita sigue estando.
        if let Some(cita) = locator.text.as_ref().map(|t| t.highlight.as_str()) {
            for candidato in &self.secciones {
                if let Some(byte) = candidato.text.find(cita) {
                    let offset = candidato.text[..byte].chars().count();
                    return Ok(Resolution {
                        position: NativePosition::Fragment {
                            href: candidato.href.clone(),
                            offset: u32::try_from(offset).unwrap_or(u32::MAX),
                        },
                        precision: Precision::Quote,
                    });
                }
            }
        }

        // --- 3. Progresión aproximada ---
        //
        // Último seccion, y **se marca**: es preferible una anotación señalada
        // como incierta que una anotación mal situada en silencio.
        if let (Some(seccion), Some(progresion)) = (seccion, locator.locations.progression) {
            let caracteres = seccion.text.chars().count();
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let offset = (progresion * caracteres as f64) as usize;
            return Ok(Resolution {
                position: NativePosition::Fragment {
                    href: seccion.href.clone(),
                    offset: u32::try_from(offset.min(caracteres)).unwrap_or(u32::MAX),
                },
                precision: Precision::Approximate,
            });
        }

        // Ni fragmento, ni cita, ni seccion. No se inventa una posición.
        tracing::info!("un locator no se pudo situar ni siquiera aproximadamente");
        Err(NbError::DocumentNotFound)
    }

    fn text_range(&self, locator: &Locator, len: usize) -> NbResult<String> {
        if !self.capacidades.text_extraction {
            return Err(NbError::FormatUnsupported);
        }

        let resolucion = self.resolve(locator)?;
        let NativePosition::Fragment { href, offset } = resolucion.position else {
            return Err(NbError::DocumentCorrupted);
        };

        let seccion = self.seccion(&href).ok_or(NbError::DocumentNotFound)?;
        Ok(seccion
            .text
            .chars()
            .skip(offset as usize)
            .take(len)
            .collect())
    }

    /// El texto en trozos anclados, que es de lo que vive el índice.
    ///
    /// Un trozo por sección mientras quepa, y si una sección no cabe se parte
    /// **por caracteres y no por bytes**: cortar por bytes rompería un carácter
    /// multibyte por la mitad, y el índice guardaría basura donde había una
    /// palabra. Ahora además, por párrafo —una línea en blanco—, por frase
    /// o por espacio, en ese orden: ver `segmentos`.
    ///
    /// Cada trozo va anclado al principio del tramo del que salió, así que un
    /// resultado de búsqueda lleva a donde estaba y no al principio de la
    /// sección.
    fn text_chunks(&self, max_chars: usize) -> NbResult<Vec<(Locator, String)>> {
        let mut salida = Vec::new();

        for seccion in &self.secciones {
            let caracteres: Vec<char> = seccion.text.chars().collect();
            let fronteras = super::segmentos::fronteras_por_linea_en_blanco(&caracteres);
            for tramo in super::segmentos::segmentar(&caracteres, &fronteras, max_chars) {
                let offset = tramo.start;
                let texto: String = caracteres[tramo].iter().collect();
                if texto.trim().is_empty() {
                    continue;
                }
                let locator = self.locator_at(&NativePosition::Fragment {
                    href: seccion.href.clone(),
                    offset: u32::try_from(offset).unwrap_or(u32::MAX),
                })?;
                salida.push((locator, texto));
            }
        }
        Ok(salida)
    }

    fn render(&self, position: &NativePosition) -> NbResult<Rendered> {
        let NativePosition::Fragment { href, .. } = position else {
            return Err(NbError::PathNotAllowed);
        };
        let seccion = self.seccion(href).ok_or(NbError::PathNotAllowed)?;

        Ok(Rendered::Markup {
            html: format!("<p>{}</p>", seccion.text),
            media_type: "application/xhtml+xml".to_owned(),
            omitted: Vec::new(),
        })
    }

    fn capabilities(&self) -> ReaderCapabilities {
        self.capacidades
    }
}
