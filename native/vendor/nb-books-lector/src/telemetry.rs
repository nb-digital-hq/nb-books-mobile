//! Redacción de lo que nombra contenido de la persona antes de registrarlo.
//!
//! Vive en el motor y no en la aplicación porque el motor también registra, y lo
//! que registra tiene que salir redactado igual en cualquier aplicación que lo use.

use std::path::Path;

/// Redacta una ruta del sistema de archivos para que pueda registrarse.
///
/// Devuelve únicamente la extensión y la longitud, que es lo que sirve para
/// diagnosticar, sin revelar el nombre del archivo, la estructura de carpetas ni
/// el nombre de usuario del sistema operativo.
///
/// ```
/// use nb_books_lector::telemetry::redact_path;
///
/// let redacted = redact_path(std::path::Path::new("/home/ana/Libros/Ulises.epub"));
///
/// assert!(redacted.contains("epub"));   // la extensión sirve para diagnosticar
/// assert!(!redacted.contains("ana"));   // el nombre de usuario, no
/// assert!(!redacted.contains("Ulises"));
/// ```
#[must_use]
pub fn redact_path(path: &Path) -> String {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("desconocida");
    let len = path.as_os_str().len();
    format!("<ruta ext={ext} len={len}>")
}

/// Redacta un texto libre que podría contener contenido del usuario.
///
/// Se usa cuando hay que registrar que *algo* tenía un valor sin registrar cuál:
/// títulos, nombres de autor, consultas de búsqueda o fragmentos de documento.
#[must_use]
pub fn redact_text(text: &str) -> String {
    format!("<texto len={}>", text.chars().count())
}
