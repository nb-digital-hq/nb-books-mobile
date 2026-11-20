//! Modelo de posición: el `Locator`.
//!
//! Una posición de lectura no puede ser un entero. Un EPUB reflowable no tiene
//! páginas fijas: su posición depende del tamaño de letra y de la ventana, así
//! que un número se desplaza en cuanto el usuario cambia la tipografía y arrastra
//! con él todas las anotaciones ancladas a él. Es la forma más silenciosa de
//! destruir el trabajo de alguien.
//!
//! El `Locator` ancla por varias vías a la vez, para que la pérdida de una no
//! sea la pérdida de la posición: identificador de fragmento del formato,
//! progresión relativa, posición absoluta cuando el formato la tiene, y la cita
//! textual con su contexto. La resolución en cascada que las usa es de `annotations::anchor`; aquí
//! está el modelo y su serialización.
//!
//! Contratos: `docs/architecture/reader-contracts.md` y
//! `docs/adr/004-reader-locator-model.md`.
//!
//! # Alineación con Readium
//!
//! La forma serializada es la del `Locator` de Readium, deliberadamente y no por
//! casualidad: reduce el riesgo de longevidad y hace interoperable la
//! exportación de anotaciones. La única adición es el campo `version`, que
//! Readium no tiene y que aquí hace falta porque este objeto se exporta, se
//! sincroniza y lo puede leer una versión distinta de la que lo escribió. Un
//! locator de Readium sin `version` se acepta como versión 1.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::error::{NbError, NbResult};

/// Versión del formato serializado que esta compilación escribe y entiende.
///
/// Se sube cuando el significado de un campo existente cambia, nunca por añadir
/// uno opcional: `docs/architecture/versioning.md` fija que los
/// payloads solo crecen con campos opcionales.
pub const LOCATOR_VERSION: u32 = 1;

const fn version_por_defecto() -> u32 {
    LOCATOR_VERSION
}

/// Posición dentro de una publicación, independiente del dispositivo y de la
/// configuración de lectura.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct Locator {
    /// Versión del formato serializado.
    #[serde(default = "version_por_defecto")]
    pub version: u32,
    /// Referencia al recurso dentro de la publicación: capítulo, archivo
    /// interno, pista de audio. Es la única parte obligatoria.
    pub href: String,
    /// Tipo de medio del recurso referenciado.
    pub media_type: String,
    /// Título legible, para mostrárselo al usuario en una lista de anotaciones.
    /// No participa en la resolución.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Las vías de anclaje. Al menos una tiene que existir.
    pub locations: Locations,
    /// La cita y su contexto. Es lo que permite reanclar cuando el fragmento
    /// canónico deja de resolver.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<TextContext>,
}

/// Vías alternativas de anclaje dentro del recurso.
///
/// Todas son opcionales por separado y ninguna lo es en conjunto: un locator sin
/// ninguna no ancla nada, y guardarlo sería guardar la ilusión de una posición.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct Locations {
    /// Identificadores de fragmento canónicos del formato: `epubcfi(...)`,
    /// `#id`, `page=12`. Varios porque un mismo punto puede expresarse de más de
    /// una forma y conviene guardarlas todas.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fragments: Vec<String>,
    /// Progresión dentro del recurso, de 0 a 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progression: Option<f64>,
    /// Progresión dentro de la publicación completa, de 0 a 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_progression: Option<f64>,
    /// Posición absoluta cuando el formato la tiene: página de PDF, número de
    /// posición estable. Empieza en 1, como en Readium.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<u32>,
}

/// Cita textual con su contexto.
///
/// No es decorativo: es la vía de reanclaje cuando el documento cambia de
/// edición, de motor de renderizado o de versión.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct TextContext {
    /// Fragmento inmediatamente anterior a la cita.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    /// La cita exacta. Es lo que se busca al reanclar, así que no puede estar
    /// vacía.
    pub highlight: String,
    /// Fragmento inmediatamente posterior a la cita.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
}

impl TextContext {
    /// Construye un contexto a partir de la cita.
    ///
    /// # Errors
    ///
    /// [`NbError::Internal`] si la cita está vacía: una cita vacía encuentra
    /// cualquier punto del documento, que es peor que no encontrar ninguno.
    pub fn new(before: Option<&str>, highlight: &str, after: Option<&str>) -> NbResult<Self> {
        if highlight.trim().is_empty() {
            return Err(NbError::Internal);
        }
        Ok(Self {
            before: before.map(str::to_owned),
            highlight: highlight.to_owned(),
            after: after.map(str::to_owned),
        })
    }
}

/// Cuántos caracteres de contexto se guardan a cada lado de una cita.
///
/// Suficiente para desempatar entre dos apariciones parecidas y poco para que
/// una biblioteca entera de anotaciones no arrastre párrafos enteros.
pub const CONTEXTO: usize = 32;

/// Construye el contexto de una cita a partir del texto donde se encontró.
///
/// Vive aquí y no en cada proveedor porque el recorte por caracteres —y no por
/// bytes— es la clase de detalle que se escribe bien una vez y mal las demás:
/// cortar por bytes en mitad de un carácter multibyte revienta, y ninguna
/// prueba de un libro en inglés lo descubriría.
///
/// # Errors
///
/// [`NbError::Internal`] si la cita está vacía o `byte` no cae en un límite de
/// carácter dentro de `texto`.
pub fn contexto_de(texto: &str, byte: usize, cita: &str) -> NbResult<TextContext> {
    let fin = byte + cita.len();
    if !texto.is_char_boundary(byte) || fin > texto.len() || !texto.is_char_boundary(fin) {
        return Err(NbError::Internal);
    }

    let antes: String = texto[..byte]
        .chars()
        .rev()
        .take(CONTEXTO)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let despues: String = texto[fin..].chars().take(CONTEXTO).collect();

    TextContext::new(
        (!antes.is_empty()).then_some(antes.as_str()),
        cita,
        (!despues.is_empty()).then_some(despues.as_str()),
    )
}

impl Locations {
    /// Indica si hay alguna vía de anclaje.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.fragments.is_empty()
            && self.progression.is_none()
            && self.total_progression.is_none()
            && self.position.is_none()
    }

    fn validar(&self) -> NbResult<()> {
        for (nombre, valor) in [
            ("progression", self.progression),
            ("totalProgression", self.total_progression),
        ] {
            if let Some(v) = valor {
                // `NaN` pasaría cualquier comparación de rango escrita al revés
                // y se propagaría hasta la interfaz como una posición imposible.
                if !v.is_finite() || !(0.0..=1.0).contains(&v) {
                    tracing::warn!(campo = nombre, "progresión fuera de rango");
                    return Err(NbError::Internal);
                }
            }
        }

        if self.position == Some(0) {
            // Readium numera las posiciones desde 1. Un 0 casi siempre significa
            // que alguien tradujo un índice de array sin darse cuenta.
            return Err(NbError::Internal);
        }

        if self.fragments.iter().any(|f| f.trim().is_empty()) {
            return Err(NbError::Internal);
        }

        Ok(())
    }
}

impl Locator {
    /// Construye un locator y comprueba sus invariantes.
    ///
    /// # Errors
    ///
    /// [`NbError::Internal`] si el recurso o el tipo de medio están vacíos, si
    /// una progresión queda fuera de `0..=1`, o si el locator no ancla por
    /// ninguna vía. Esto último es deliberado: un locator sin fragmento, sin
    /// progresión, sin posición y sin cita no representa una posición, y
    /// aceptarlo convertiría el modelo en el entero que ADR-004 descarta, solo
    /// que con más ceremonia.
    pub fn new(
        href: &str,
        media_type: &str,
        locations: Locations,
        text: Option<TextContext>,
    ) -> NbResult<Self> {
        if href.trim().is_empty() || media_type.trim().is_empty() {
            return Err(NbError::Internal);
        }
        locations.validar()?;

        if locations.is_empty() && text.is_none() {
            tracing::warn!("se rechazó un locator que no ancla por ninguna vía");
            return Err(NbError::Internal);
        }

        Ok(Self {
            version: LOCATOR_VERSION,
            href: href.to_owned(),
            media_type: media_type.to_owned(),
            title: None,
            locations,
            text,
        })
    }

    /// Añade el título legible.
    #[must_use]
    pub fn with_title(mut self, title: &str) -> Self {
        self.title = Some(title.to_owned());
        self
    }

    /// Serializa el locator para guardarlo o exportarlo.
    ///
    /// # Errors
    ///
    /// [`NbError::Internal`] si la serialización falla, lo que solo puede
    /// ocurrir por un fallo de asignación de memoria.
    pub fn to_json(&self) -> NbResult<String> {
        serde_json::to_string(self).map_err(|error| {
            tracing::error!(error = %error, "no se pudo serializar un locator");
            NbError::Internal
        })
    }

    /// Lee un locator serializado.
    ///
    /// Acepta un locator de Readium sin campo `version`, tratándolo como
    /// versión 1.
    ///
    /// # Errors
    ///
    /// - [`NbError::SchemaMismatch`] si el locator lo escribió una versión
    ///   posterior de la aplicación. Interpretarlo con reglas antiguas colocaría
    ///   la anotación en un sitio equivocado, que es peor que no abrirla.
    /// - [`NbError::DocumentCorrupted`] si el JSON no tiene la forma esperada o
    ///   incumple una invariante.
    pub fn from_json(json: &str) -> NbResult<Self> {
        let locator: Self = serde_json::from_str(json).map_err(|error| {
            // El mensaje de serde cita el fragmento que falló y ese fragmento
            // puede ser texto del libro del usuario: no se registra.
            tracing::warn!(
                linea = error.line(),
                columna = error.column(),
                "locator con forma inesperada"
            );
            NbError::DocumentCorrupted
        })?;

        if locator.version > LOCATOR_VERSION {
            tracing::error!(
                version = locator.version,
                soportada = LOCATOR_VERSION,
                "locator escrito por una versión posterior de la aplicación"
            );
            return Err(NbError::SchemaMismatch);
        }

        locator.validar()?;
        Ok(locator)
    }

    fn validar(&self) -> NbResult<()> {
        if self.href.trim().is_empty() || self.media_type.trim().is_empty() {
            return Err(NbError::DocumentCorrupted);
        }
        self.locations
            .validar()
            .map_err(|_| NbError::DocumentCorrupted)?;

        if let Some(text) = &self.text {
            if text.highlight.trim().is_empty() {
                return Err(NbError::DocumentCorrupted);
            }
        }

        if self.locations.is_empty() && self.text.is_none() {
            return Err(NbError::DocumentCorrupted);
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn locations_completas() -> Locations {
        Locations {
            fragments: vec!["epubcfi(/6/14[chap05ref]!/4[body01]/10[para05]/3:10)".to_owned()],
            progression: Some(0.42),
            total_progression: Some(0.17),
            position: Some(233),
        }
    }

    fn texto() -> TextContext {
        TextContext::new(
            Some("Muchos años después, "),
            "frente al pelotón de fusilamiento",
            Some(", el coronel Aureliano Buendía"),
        )
        .expect("contexto")
    }

    fn locator() -> Locator {
        Locator::new(
            "OEBPS/chapter05.xhtml",
            "application/xhtml+xml",
            locations_completas(),
            Some(texto()),
        )
        .expect("locator")
        .with_title("Capítulo 5")
    }

    // --- Ida y vuelta -------------------------------------------------------

    /// **Criterio de aceptación.** Serializar y volver a leer no puede
    /// perder ni alterar nada: un locator que cambia al guardarse es una
    /// anotación que se mueve sola.
    #[test]
    fn un_locator_completo_sobrevive_a_la_ida_y_vuelta() {
        let original = locator();

        let json = original.to_json().expect("serializable");
        let recuperado = Locator::from_json(&json).expect("legible");

        assert_eq!(recuperado, original);
    }

    /// El caso mínimo: solo cita, sin fragmento ni progresión. Es lo que queda
    /// cuando el formato no ofrece identificadores estables, y tiene que bastar.
    #[test]
    fn un_locator_solo_con_cita_sobrevive_a_la_ida_y_vuelta() {
        let original = Locator::new(
            "OEBPS/chapter01.xhtml",
            "application/xhtml+xml",
            Locations::default(),
            Some(texto()),
        )
        .expect("locator");

        let recuperado = Locator::from_json(&original.to_json().expect("json")).expect("legible");

        assert_eq!(recuperado, original);
    }

    /// El otro caso mínimo: solo posición absoluta, que es lo que da un PDF.
    #[test]
    fn un_locator_solo_con_posicion_sobrevive_a_la_ida_y_vuelta() {
        let original = Locator::new(
            "documento.pdf",
            "application/pdf",
            Locations {
                position: Some(42),
                ..Locations::default()
            },
            None,
        )
        .expect("locator");

        let recuperado = Locator::from_json(&original.to_json().expect("json")).expect("legible");

        assert_eq!(recuperado, original);
        assert_eq!(recuperado.locations.position, Some(42));
    }

    /// La progresión es el campo con más riesgo de perder precisión al pasar por
    /// texto, y una anotación desplazada un 0,1 % es una anotación desplazada.
    #[test]
    fn la_progresion_no_pierde_precision_al_serializar() {
        let original = Locator::new(
            "c.xhtml",
            "application/xhtml+xml",
            Locations {
                progression: Some(0.123_456_789_012_345_67),
                total_progression: Some(0.987_654_321_098_765_4),
                ..Locations::default()
            },
            None,
        )
        .expect("locator");

        let recuperado = Locator::from_json(&original.to_json().expect("json")).expect("legible");

        assert_eq!(
            recuperado.locations.progression,
            original.locations.progression
        );
        assert_eq!(
            recuperado.locations.total_progression,
            original.locations.total_progression
        );
    }

    // --- Forma serializada, que es contrato --------------------------------

    /// La forma es la de Readium, en `camelCase`, y eso es contrato con el
    /// frontend y con cualquier herramienta que lea una exportación.
    #[test]
    fn la_forma_serializada_es_la_de_readium() {
        let json = locator().to_json().expect("json");

        for esperado in [
            r#""href":"OEBPS/chapter05.xhtml""#,
            r#""mediaType":"application/xhtml+xml""#,
            r#""totalProgression":0.17"#,
            r#""highlight":"frente al pelotón de fusilamiento""#,
            r#""version":1"#,
        ] {
            assert!(json.contains(esperado), "falta {esperado} en {json}");
        }
        assert!(!json.contains("total_progression"), "json: {json}");
    }

    /// Los campos ausentes no se serializan como `null`: un locator de PDF no
    /// tiene que arrastrar seis nulos por cada anotación, multiplicados por una
    /// biblioteca entera.
    #[test]
    fn los_campos_ausentes_no_ocupan_sitio() {
        let json = Locator::new(
            "documento.pdf",
            "application/pdf",
            Locations {
                position: Some(1),
                ..Locations::default()
            },
            None,
        )
        .expect("locator")
        .to_json()
        .expect("json");

        assert!(!json.contains("null"), "json: {json}");
        assert!(!json.contains("fragments"), "json: {json}");
        assert!(!json.contains("text"), "json: {json}");
    }

    /// Un locator de Readium no trae `version`. Rechazarlo cerraría la puerta a
    /// importar anotaciones de otras herramientas, que es justo lo que el
    /// alineamiento con Readium existe para permitir.
    #[test]
    fn un_locator_sin_version_se_acepta_como_la_primera() {
        let ajeno = r#"{
            "href": "OEBPS/c1.xhtml",
            "mediaType": "application/xhtml+xml",
            "locations": { "progression": 0.5 }
        }"#;

        let locator = Locator::from_json(ajeno).expect("locator de Readium");

        assert_eq!(locator.version, LOCATOR_VERSION);
        assert_eq!(locator.locations.progression, Some(0.5));
    }

    /// Una versión posterior significa que el significado de algún campo puede
    /// haber cambiado. Interpretarla con reglas antiguas colocaría la anotación
    /// en un sitio equivocado, y eso es peor que no abrirla: es la misma razón
    /// por la que el motor de migraciones se niega a abrir una base más nueva.
    #[test]
    fn un_locator_de_una_version_posterior_se_rechaza() {
        let futuro = format!(
            r#"{{"version":{},"href":"c.xhtml","mediaType":"text/html","locations":{{"position":1}}}}"#,
            LOCATOR_VERSION + 1
        );

        assert!(matches!(
            Locator::from_json(&futuro),
            Err(NbError::SchemaMismatch)
        ));
    }

    // --- Invariantes --------------------------------------------------------

    /// **La otra mitad del criterio de aceptación.** Un locator sin fragmento,
    /// sin progresión, sin posición y sin cita no representa una posición.
    /// Aceptarlo convertiría el modelo en el entero que ADR-004 descarta, solo
    /// que con más ceremonia.
    #[test]
    fn un_locator_que_no_ancla_por_ninguna_via_se_rechaza() {
        let resultado = Locator::new(
            "c.xhtml",
            "application/xhtml+xml",
            Locations::default(),
            None,
        );

        assert!(matches!(resultado, Err(NbError::Internal)));
    }

    #[test]
    fn un_locator_que_no_ancla_tampoco_se_acepta_al_leerlo() {
        let vacio = r#"{"href":"c.xhtml","mediaType":"text/html","locations":{}}"#;

        assert!(matches!(
            Locator::from_json(vacio),
            Err(NbError::DocumentCorrupted)
        ));
    }

    /// `NaN` pasa cualquier comparación de rango escrita al revés y se propaga
    /// hasta la interfaz como una posición imposible.
    #[test]
    fn una_progresion_fuera_de_rango_o_no_finita_se_rechaza() {
        for valor in [-0.1, 1.1, f64::NAN, f64::INFINITY] {
            let resultado = Locator::new(
                "c.xhtml",
                "application/xhtml+xml",
                Locations {
                    progression: Some(valor),
                    ..Locations::default()
                },
                None,
            );
            assert!(
                matches!(resultado, Err(NbError::Internal)),
                "la progresión {valor} no debería admitirse"
            );
        }
    }

    /// Readium numera las posiciones desde 1. Un 0 casi siempre significa que
    /// alguien tradujo un índice de array sin darse cuenta.
    #[test]
    fn la_posicion_cero_se_rechaza() {
        let resultado = Locator::new(
            "documento.pdf",
            "application/pdf",
            Locations {
                position: Some(0),
                ..Locations::default()
            },
            None,
        );

        assert!(matches!(resultado, Err(NbError::Internal)));
    }

    /// Una cita vacía encuentra cualquier punto del documento, que es peor que
    /// no encontrar ninguno.
    #[test]
    fn una_cita_vacia_se_rechaza() {
        assert!(matches!(
            TextContext::new(None, "   ", None),
            Err(NbError::Internal)
        ));

        let con_cita_vacia = r#"{"href":"c.xhtml","mediaType":"text/html","locations":{"position":1},
                "text":{"highlight":"  "}}"#;
        assert!(matches!(
            Locator::from_json(con_cita_vacia),
            Err(NbError::DocumentCorrupted)
        ));
    }

    #[test]
    fn un_locator_sin_recurso_se_rechaza() {
        assert!(matches!(
            Locator::new("  ", "text/html", locations_completas(), None),
            Err(NbError::Internal)
        ));
        assert!(matches!(
            Locator::new("c.xhtml", "  ", locations_completas(), None),
            Err(NbError::Internal)
        ));
    }

    /// El JSON de un locator llega desde el disco, desde una exportación ajena y
    /// algún día desde el servidor de sincronización. Ninguna forma inesperada
    /// puede producir un pánico.
    #[test]
    fn un_json_con_forma_inesperada_no_entra_en_panico() {
        for entrada in [
            "",
            "42",
            "null",
            "[]",
            "{}",
            r#"{"href":"c.xhtml"}"#,
            r#"{"href":"c.xhtml","mediaType":"text/html","locations":{"progression":"media"}}"#,
            "{\"href\":\"c.xhtml\",",
        ] {
            let resultado = Locator::from_json(entrada);
            assert!(
                resultado.is_err(),
                "la entrada {entrada:?} no debería producir un locator"
            );
        }
    }

    /// El mensaje de error de serde cita el fragmento que falló, y ese fragmento
    /// puede ser texto del libro. El error de dominio no puede arrastrarlo.
    #[test]
    fn el_error_de_lectura_no_filtra_el_contenido_del_documento() {
        let json_roto = r#"{"href":"c.xhtml","mediaType":"text/html",
            "locations":{"position":1},"text":{"highlight":"El nombre de la rosa","after":}}"#;

        let error = Locator::from_json(json_roto).expect_err("debe fallar");
        let serializado = serde_json::to_string(&error).expect("serializable");

        assert!(!serializado.contains("rosa"), "json: {serializado}");
        assert_eq!(serializado, r#"{"code":"DOCUMENT_CORRUPTED"}"#);
    }
}
