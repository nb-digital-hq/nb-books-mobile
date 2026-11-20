//! Validación de rutas: la defensa de la frontera IPC.
//!
//! El webview es una zona no confiable y puede estar comprometido por un
//! documento malicioso o por una extensión. Ninguna ruta que venga de ahí se
//! usa tal cual.
//!
//! Contratos: `docs/architecture/ipc-contracts.md` y
//! `docs/audit/threat-model.md`.

use std::path::{Component, Path, PathBuf};

use crate::error::{NbError, NbResult};

/// Resuelve una ruta y comprueba que queda dentro de `scope`.
///
/// Resuelve la ruta canónicamente, lo que sigue los enlaces simbólicos, y
/// después comprueba la contención. Ese orden es el que importa: comprobar
/// antes de resolver permite escapar con un enlace simbólico.
///
/// # Errors
///
/// - [`NbError::FileNotFound`] si la ruta no existe.
/// - [`NbError::PathNotAllowed`] si, una vez resuelta, queda fuera del ámbito.
pub fn resolve_within(scope: &Path, candidate: &Path) -> NbResult<PathBuf> {
    let scope = scope.canonicalize().map_err(|_| NbError::StorageFailure)?;

    let candidate = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        scope.join(candidate)
    };

    let resolved = candidate.canonicalize().map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            NbError::FileNotFound
        } else {
            NbError::PathNotAllowed
        }
    })?;

    if !resolved.starts_with(&scope) {
        tracing::warn!(
            ruta = %crate::telemetry::redact_path(&resolved),
            "se rechazó una ruta fuera del ámbito permitido"
        );
        return Err(NbError::PathNotAllowed);
    }

    Ok(resolved)
}

/// Comprueba que una ruta interna de un archivo comprimido es segura de extraer.
///
/// Los archivos EPUB y de cómic son contenedores ZIP, y una entrada puede
/// declarar una ruta como `../../.ssh/authorized_keys`. Escribirla tal cual es
/// la vulnerabilidad conocida como recorrido de directorios en la extracción.
///
/// # Errors
///
/// Devuelve [`NbError::PathNotAllowed`] si la entrada es absoluta, contiene un
/// componente `..`, o usa un prefijo de volumen de Windows.
pub fn validate_archive_entry(entry: &str) -> NbResult<PathBuf> {
    // Las rutas de ZIP usan `/`, pero un archivo malicioso puede usar `\` para
    // sortear una comprobación ingenua en Windows.
    let normalized = entry.replace('\\', "/");
    let path = Path::new(&normalized);

    if normalized.is_empty() || path.is_absolute() || normalized.starts_with('/') {
        return Err(NbError::PathNotAllowed);
    }

    // `Component::Prefix` solo existe al compilar para Windows, así que la letra
    // de unidad debe detectarse a mano: si no, un archivo malicioso pasa la
    // validación en Linux y falla al extraerse en Windows.
    let bytes = normalized.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
        tracing::warn!("se rechazó una entrada de archivo con prefijo de volumen");
        return Err(NbError::PathNotAllowed);
    }

    for component in path.components() {
        match component {
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                tracing::warn!("se rechazó una entrada de archivo con recorrido de directorios");
                return Err(NbError::PathNotAllowed);
            }
            Component::CurDir | Component::Normal(_) => {}
        }
    }

    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Temporal(PathBuf);

    impl Temporal {
        fn nuevo(nombre: &str) -> Self {
            let dir = crate::paths::temporal_de_pruebas()
                .join(format!("nb-sec-{nombre}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("directorio");
            Self(dir)
        }
    }

    impl Drop for Temporal {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn acepta_una_ruta_dentro_del_ambito() {
        let tmp = Temporal::nuevo("dentro");
        let archivo = tmp.0.join("libro.epub");
        std::fs::write(&archivo, b"x").expect("escritura");

        let resuelta = resolve_within(&tmp.0, Path::new("libro.epub")).expect("aceptada");
        assert!(resuelta.starts_with(tmp.0.canonicalize().expect("canónica")));
    }

    /// El archivo objetivo se crea de verdad fuera del ámbito. Aceptar también
    /// `FileNotFound` haría pasar esta prueba en una máquina donde el objetivo
    /// simplemente no exista, que es justo el caso en que no prueba nada.
    #[test]
    fn rechaza_el_recorrido_de_directorios() {
        let tmp = Temporal::nuevo("recorrido");
        let fuera = tmp.0.join("..").join(format!(
            "nb-sec-objetivo-{}-{}",
            std::process::id(),
            "recorrido"
        ));
        std::fs::write(&fuera, b"secreto").expect("archivo fuera del ámbito");

        let relativa = Path::new("..").join(fuera.file_name().expect("nombre"));
        let resultado = resolve_within(&tmp.0, &relativa);

        let _ = std::fs::remove_file(&fuera);
        assert!(
            matches!(resultado, Err(NbError::PathNotAllowed)),
            "un objetivo existente fuera del ámbito debe rechazarse por ámbito: {resultado:?}"
        );
    }

    #[test]
    fn rechaza_una_ruta_absoluta_fuera_del_ambito() {
        let tmp = Temporal::nuevo("absoluta");
        let fuera = Temporal::nuevo("absoluta-destino");
        let archivo = fuera.0.join("ajeno.epub");
        std::fs::write(&archivo, b"x").expect("archivo");

        let resultado = resolve_within(&tmp.0, &archivo);

        assert!(
            matches!(resultado, Err(NbError::PathNotAllowed)),
            "una ruta absoluta existente fuera del ámbito debe rechazarse: {resultado:?}"
        );
    }

    /// El caso que hace obligatorio canonicalizar **antes** de comprobar: una
    /// comprobación textual aceptaría este enlace porque su ruta empieza dentro
    /// del ámbito.
    #[cfg(unix)]
    #[test]
    fn rechaza_un_enlace_simbolico_que_escapa_del_ambito() {
        let tmp = Temporal::nuevo("enlace");
        let enlace = tmp.0.join("fuga");
        std::os::unix::fs::symlink("/etc", &enlace).expect("enlace");

        let resultado = resolve_within(&tmp.0, Path::new("fuga/hostname"));
        assert!(matches!(resultado, Err(NbError::PathNotAllowed)));
    }

    #[test]
    fn una_ruta_inexistente_se_distingue_de_una_prohibida() {
        let tmp = Temporal::nuevo("inexistente");
        let resultado = resolve_within(&tmp.0, Path::new("no-existe.epub"));
        assert!(matches!(resultado, Err(NbError::FileNotFound)));
    }

    #[test]
    fn acepta_entradas_de_archivo_normales() {
        assert!(validate_archive_entry("OEBPS/capitulo1.xhtml").is_ok());
        assert!(validate_archive_entry("./portada.jpg").is_ok());
    }

    #[test]
    fn rechaza_entradas_de_archivo_con_recorrido() {
        for entrada in [
            "../../.ssh/authorized_keys",
            "/etc/passwd",
            "..\\..\\windows\\system32\\config",
            "OEBPS/../../fuera.txt",
            "C:\\Windows\\System32\\evil.dll",
            "",
        ] {
            assert!(
                validate_archive_entry(entrada).is_err(),
                "la entrada {entrada:?} debería rechazarse"
            );
        }
    }
}
