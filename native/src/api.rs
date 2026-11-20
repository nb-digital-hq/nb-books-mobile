//! Lo que Dart puede pedir al motor. Cada función es síncrona en Rust y
//! `flutter_rust_bridge` la lleva a un hilo de trabajo: abrir o pintar un
//! capítulo no bloquea la interfaz.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use nb_books_lector::error::NbError;
use nb_books_lector::reader::comic::ComicFactory;
use nb_books_lector::reader::epub::EpubFactory;
use nb_books_lector::reader::pdf::PdfFactory;
use nb_books_lector::reader::{DocumentProvider, Locator, NativePosition, ProviderRegistry};
use nb_books_lector::repaso_espaciado::{
    reproducir, CalificacionRepaso, EstadoRepaso, Programacion,
};
use serde::{Deserialize, Serialize};

/// Un fallo del motor, con el mismo código estable que usa NB Books. Dart lo
/// traduce; nunca enseña un mensaje interno.
#[derive(Debug)]
pub struct FalloDelMotor {
    pub codigo: String,
}

impl From<NbError> for FalloDelMotor {
    fn from(e: NbError) -> Self {
        Self {
            codigo: e.code().to_owned(),
        }
    }
}

fn invalido() -> FalloDelMotor {
    FalloDelMotor {
        codigo: "INTERNAL".to_owned(),
    }
}

type Resultado<T> = Result<T, FalloDelMotor>;

struct Motor {
    registro: ProviderRegistry,
    abiertos: Mutex<HashMap<u64, Arc<dyn DocumentProvider>>>,
    siguiente: AtomicU64,
}

static MOTOR: OnceLock<Motor> = OnceLock::new();

fn motor() -> Resultado<&'static Motor> {
    MOTOR.get().ok_or_else(|| FalloDelMotor {
        codigo: "COMPONENT_UNAVAILABLE".to_owned(),
    })
}

fn documento(id: u64) -> Resultado<Arc<dyn DocumentProvider>> {
    motor()?
        .abiertos
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get(&id)
        .cloned()
        .ok_or_else(|| FalloDelMotor {
            codigo: "DOCUMENT_NOT_FOUND".to_owned(),
        })
}

fn json<T: Serialize>(valor: &T) -> Resultado<String> {
    serde_json::to_string(valor).map_err(|_| invalido())
}

fn leer<T: for<'a> Deserialize<'a>>(texto: &str) -> Resultado<T> {
    serde_json::from_str(texto).map_err(|_| invalido())
}

/// Prepara el motor con la carpeta donde guardar lo que pinta (páginas de PDF y
/// de cómic) y los recursos de los EPUB. Llamarlo dos veces no hace nada.
#[flutter_rust_bridge::frb(sync)]
pub fn preparar(cache: String) {
    let raiz = PathBuf::from(cache);
    MOTOR.get_or_init(|| {
        let mut registro = ProviderRegistry::new();
        registro.register(Box::new(EpubFactory::new(raiz.join("epub"))));
        registro.register(Box::new(ComicFactory::new(raiz.join("comic"))));
        registro.register(Box::new(PdfFactory::new(raiz.join("pdf"))));
        Motor {
            registro,
            abiertos: Mutex::new(HashMap::new()),
            siguiente: AtomicU64::new(1),
        }
    });
}

/// Los tipos de documento que esta instalación sabe abrir.
#[flutter_rust_bridge::frb(sync)]
pub fn tipos_admitidos() -> Vec<String> {
    MOTOR.get().map_or_else(Vec::new, |m| {
        m.registro
            .media_types()
            .into_iter()
            .map(str::to_owned)
            .collect()
    })
}

/// Lo que se sabe de un documento al abrirlo, de una vez: capacidades e índice.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Apertura {
    id: u64,
    media_type: String,
    capabilities: nb_books_lector::reader::ReaderCapabilities,
    navigation: nb_books_lector::reader::Navigation,
}

/// Abre un documento y devuelve su apertura en JSON. El identificador vale
/// hasta [`cerrar`].
pub fn abrir(ruta: String, tipo: String) -> Resultado<String> {
    let m = motor()?;
    let doc: Arc<dyn DocumentProvider> = Arc::from(m.registro.open(&tipo, Path::new(&ruta))?);
    let id = m.siguiente.fetch_add(1, Ordering::Relaxed);
    let apertura = Apertura {
        id,
        media_type: doc.media_type().to_owned(),
        capabilities: doc.capabilities(),
        navigation: doc.navigation()?,
    };
    m.abiertos
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(id, doc);
    json(&apertura)
}

/// Suelta un documento abierto. Cerrar lo que no está abierto no es un error.
#[flutter_rust_bridge::frb(sync)]
pub fn cerrar(id: u64) {
    if let Some(m) = MOTOR.get() {
        m.abiertos
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
    }
}

/// Pinta una posición: el marcado saneado de un capítulo o la imagen de una
/// página. `posicion` es un `NativePosition` en JSON.
pub fn pintar(id: u64, posicion: String) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.render(&leer::<NativePosition>(&posicion)?)?)
}

/// Dónde cae un Locator en este documento, y con qué precisión.
pub fn resolver(id: u64, locator: String) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.resolve(&leer::<Locator>(&locator)?)?)
}

/// El Locator de una posición nativa.
pub fn locator_en(id: u64, posicion: String) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.locator_at(&leer::<NativePosition>(&posicion)?)?)
}

/// El Locator de una cita: es como se ancla una selección y como se apunta
/// dónde se quedó la lectura, igual que en el PC.
pub fn locator_de_cita(id: u64, cita: String, pista: Option<f64>) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.locator_for_quote(&cita, pista)?)
}

/// El texto a partir de un Locator, para la voz y para citar.
pub fn texto_desde(id: u64, locator: String, largo: u32) -> Resultado<String> {
    let doc = documento(id)?;
    Ok(doc.text_range(&leer::<Locator>(&locator)?, largo as usize)?)
}

/// La capa de texto de una página que se pinta como imagen.
pub fn capa_de_texto(id: u64, posicion: String) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.text_layer(&leer::<NativePosition>(&posicion)?)?)
}

/// El tamaño intrínseco de una página que se pinta como imagen.
pub fn tamano_de_pagina(id: u64, posicion: String) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.page_size(&leer::<NativePosition>(&posicion)?)?)
}

/// Los fragmentos de texto del documento, con su Locator: es lo que busca el
/// teléfono dentro de un libro sin el índice del PC.
pub fn fragmentos(id: u64, maximo: u32) -> Resultado<String> {
    let doc = documento(id)?;
    json(&doc.text_chunks(maximo as usize)?)
}

#[derive(Serialize)]
struct Metadatos {
    titulo: Option<String>,
    autores: Vec<String>,
    idioma: Option<String>,
    editorial: Option<String>,
    fecha: Option<String>,
    serie: Option<String>,
    sinopsis: Option<String>,
}

/// Lo que un libro dice de sí mismo, para darlo de alta en el teléfono con su
/// título y su autoría y no con el nombre del archivo.
pub fn metadatos(ruta: String, tipo: String) -> Resultado<String> {
    let ruta = Path::new(&ruta);
    let m = match tipo.as_str() {
        "application/epub+zip" => nb_books_lector::epub::read_metadata(ruta)?,
        nb_books_lector::reader::comic::MEDIA_TYPE => {
            nb_books_lector::reader::comic::read_metadata(ruta)?
        }
        _ => {
            return json(&Metadatos {
                titulo: None,
                autores: Vec::new(),
                idioma: None,
                editorial: None,
                fecha: None,
                serie: None,
                sinopsis: None,
            })
        }
    };
    json(&Metadatos {
        titulo: m.title,
        autores: m
            .creators
            .into_iter()
            .filter(|c| matches!(c.role, nb_books_lector::epub::Papel::Autor))
            .map(|c| c.name)
            .collect(),
        idioma: m.language,
        editorial: m.publisher,
        fecha: m.date,
        serie: m.series,
        sinopsis: m.description,
    })
}

/// Los capítulos de un EPUB en orden de lectura. Pasar de capítulo sigue el
/// lomo y no el índice: hay libros cuyo índice se salta capítulos enteros.
pub fn lomo(ruta: String) -> Resultado<Vec<String>> {
    let doc = nb_books_lector::reader::epub::EpubDocument::open(Path::new(&ruta))?;
    Ok(doc.spine().into_iter().map(str::to_owned).collect())
}

/// La huella de un archivo, con el mismo formato que la del PC: es lo que dice
/// que un libro del teléfono y uno del PC son el mismo.
pub fn huella(ruta: String) -> Resultado<String> {
    let (hash, _) = nb_books_lector::library::hash_file(Path::new(&ruta))?;
    Ok(hash.as_str().to_owned())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntradaRepaso {
    repeticiones: u32,
    intervalo_dias: u32,
    facilidad: f64,
    vence_en: String,
    repasada_en: Option<String>,
    /// `[instante, calificación]`, ya en orden.
    repasos: Vec<(String, String)>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SalidaRepaso {
    repeticiones: u32,
    intervalo_dias: u32,
    facilidad: f64,
    vence_en: String,
    repasada_en: Option<String>,
}

/// Reproduce los repasos de una tarjeta sobre su base con SM-2: el mismo
/// cálculo, en el mismo orden, que hace el PC, así que los dos llegan al mismo
/// resultado sin elegir a nadie (ADR-002).
pub fn reproducir_repasos(entrada: String) -> Resultado<String> {
    let e: EntradaRepaso = leer(&entrada)?;
    let repasos = e
        .repasos
        .into_iter()
        .map(|(cuando, cal)| Ok((cuando, CalificacionRepaso::desde_str(&cal)?)))
        .collect::<Result<Vec<_>, NbError>>()?;
    let p = reproducir(
        Programacion {
            estado: EstadoRepaso {
                repetitions: e.repeticiones,
                interval_days: e.intervalo_dias,
                ease_factor: e.facilidad,
            },
            due_at: e.vence_en,
            last_reviewed_at: e.repasada_en,
        },
        &repasos,
    )?;
    json(&SalidaRepaso {
        repeticiones: p.estado.repetitions,
        intervalo_dias: p.estado.interval_days,
        facilidad: p.estado.ease_factor,
        vence_en: p.due_at,
        repasada_en: p.last_reviewed_at,
    })
}

/// La versión del Locator que escribe este motor. Si no coincide con la del PC,
/// el teléfono no sincroniza posiciones.
#[flutter_rust_bridge::frb(sync)]
pub fn version_del_locator() -> u32 {
    nb_books_lector::reader::LOCATOR_VERSION
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn el_repaso_del_telefono_es_el_del_pc() {
        let entrada = r#"{"repeticiones":0,"intervaloDias":0,"facilidad":2.5,
            "venceEn":"2026-01-01T00:00:00.000Z","repasadaEn":null,
            "repasos":[["2026-01-01T10:00:00.000Z","good"],["2026-01-02T10:00:00.000Z","good"]]}"#;
        let salida: serde_json::Value =
            serde_json::from_str(&reproducir_repasos(entrada.to_owned()).expect("repaso"))
                .expect("json");
        assert_eq!(salida["repeticiones"], 2);
        assert_eq!(salida["intervaloDias"], 6);
        assert_eq!(salida["venceEn"], "2026-01-08T10:00:00.000Z");
    }

    #[test]
    fn sin_preparar_el_motor_no_abre_nada() {
        assert!(MOTOR.get().is_none() || abrir(String::new(), String::new()).is_err());
    }
}
