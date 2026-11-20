//! Escritura y lectura de archivos con las garantías que necesita el motor:
//! nadie lee un archivo a medias y leer no cambia la hora de acceso.
//!
//! Dónde viven los datos de cada aplicación no es asunto del motor: lo resuelve
//! cada aplicación.

use std::path::{Path, PathBuf};

use crate::error::{NbError, NbResult};

/// Escribe un archivo de forma que nadie pueda leerlo a medias.
///
/// # Por qué no basta `fs::write`
///
/// Los archivos que produce la aplicación en la caché (portadas, páginas
/// rendidas) los escribe un hilo mientras otro comprueba si ya existen. Con una
/// escritura directa, el segundo puede encontrar el archivo creado y todavía a
/// medio llenar, y entonces la portada se ve cortada o la página no se decodifica
/// y el fallo aparece una vez de cada cien, en una máquina, sin forma de
/// reproducirlo.
///
/// Se escribe a un temporal **en el mismo directorio** y se renombra encima. El
/// renombrado dentro de un mismo sistema de archivos es atómico: quien mire verá
/// o el archivo entero o ningún archivo, nunca uno a medias. En el mismo
/// directorio y no en el temporal del sistema porque entre sistemas de archivos
/// distintos el renombrado deja de ser un renombrado y vuelve a ser una copia.
///
/// # Errors
///
/// [`NbError::StorageFailure`] si no se puede escribir o renombrar. El temporal
/// se retira en ese caso: dejarlo llenaría la caché de restos que nada limpia.
pub fn write_atomic(destino: &Path, escribir: impl FnOnce(&Path) -> NbResult<()>) -> NbResult<()> {
    let directorio = destino.parent().ok_or(NbError::PathNotAllowed)?;
    std::fs::create_dir_all(directorio).map_err(|_| NbError::StorageFailure)?;

    let nombre = destino
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or(NbError::PathNotAllowed)?;
    // Identificado por proceso e hilo: dos hilos escribiendo la misma página no
    // pueden pisarse el temporal, que es justo el caso que esto viene a arreglar.
    let temporal = directorio.join(format!(
        ".{nombre}.{}.{:?}.parcial",
        std::process::id(),
        std::thread::current().id()
    ));

    if let Err(error) = escribir(&temporal) {
        let _ = std::fs::remove_file(&temporal);
        return Err(error);
    }

    std::fs::rename(&temporal, destino).map_err(|_| {
        let _ = std::fs::remove_file(&temporal);
        NbError::StorageFailure
    })
}

/// Abre un archivo para lectura intentando no actualizar su hora de acceso (`atime`).
///
/// En Linux utiliza la bandera `O_NOATIME` (`libc::O_NOATIME`) para evitar que
/// operaciones de importación, indexación y apertura de libros modifiquen la marca
/// temporal `atime` de los archivos referenciados del usuario.
///
/// Si `O_NOATIME` falla (por ejemplo, con `EPERM` cuando el archivo pertenece a otro
/// usuario o el sistema de archivos no lo admite), reintenta abriéndolo de forma
/// estándar sin la bandera, garantizando degradación elegante.
///
/// En plataformas no Linux (Windows, macOS), abre el archivo para lectura de forma
/// habitual, ya que `O_NOATIME` es una característica específica del núcleo Linux.
///
/// # Errors
///
/// Devuelve los errores estándar de [`std::fs::File::open`].
pub fn open_noatime(path: &Path) -> std::io::Result<std::fs::File> {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;

        let mut opciones = std::fs::OpenOptions::new();
        opciones.read(true);
        opciones.custom_flags(libc::O_NOATIME);
        match opciones.open(path) {
            Ok(archivo) => Ok(archivo),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Err(error),
            Err(_) => std::fs::File::open(path),
        }
    }

    #[cfg(not(target_os = "linux"))]
    {
        std::fs::File::open(path)
    }
}

/// Lee el contenido completo de un archivo en memoria usando [`open_noatime`].
///
/// # Errors
///
/// Devuelve los errores estándar de [`open_noatime`] o de lectura de bytes.
pub fn read_bytes_noatime(path: &Path) -> std::io::Result<Vec<u8>> {
    use std::io::Read;

    let mut archivo = open_noatime(path)?;
    let mut buffer = Vec::new();
    archivo.read_to_end(&mut buffer)?;
    Ok(buffer)
}

/// Carpeta temporal de las pruebas de este proceso.
///
/// Las pruebas crean carpetas en el temporal del sistema y casi ninguna las
/// borraba: se acumularon miles, unos 6 GB, en un `/tmp` que vive en memoria.
/// Ahora todas cuelgan de `nb-pruebas/<pid>`, y la primera llamada de cada
/// proceso barre las de procesos que ya no existen. Así, aunque una prueba
/// falle a medias o no limpie, lo que queda es como mucho lo de una ejecución.
///
/// No es parte de la aplicación: solo la usan las pruebas.
#[doc(hidden)]
#[must_use]
pub fn temporal_de_pruebas() -> PathBuf {
    static RAIZ: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    RAIZ.get_or_init(|| {
        let raiz = std::env::temp_dir().join("nb-pruebas");
        if let Ok(entradas) = std::fs::read_dir(&raiz) {
            for entrada in entradas.flatten() {
                let vivo = entrada
                    .file_name()
                    .to_str()
                    .and_then(|n| n.parse::<u32>().ok())
                    .is_some_and(proceso_vivo);
                if !vivo {
                    borrar_aunque_sea_de_solo_lectura(&entrada.path());
                }
            }
        }
        let propia = raiz.join(std::process::id().to_string());
        let _ = std::fs::create_dir_all(&propia);
        propia
    })
    .clone()
}

#[cfg(target_os = "linux")]
fn proceso_vivo(pid: u32) -> bool {
    Path::new("/proc").join(pid.to_string()).exists()
}

// Fuera de Linux no hay `/proc`: se da por vivo y no se barre nada ajeno.
#[cfg(not(target_os = "linux"))]
const fn proceso_vivo(_pid: u32) -> bool {
    true
}

/// Borra una carpeta aunque alguna prueba la dejara sin permiso de escritura,
/// como hace la de Calibre en solo lectura.
fn borrar_aunque_sea_de_solo_lectura(ruta: &Path) {
    if std::fs::remove_dir_all(ruta).is_ok() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fn abrir(ruta: &Path) {
            let _ = std::fs::set_permissions(ruta, std::fs::Permissions::from_mode(0o755));
            if let Ok(entradas) = std::fs::read_dir(ruta) {
                for e in entradas.flatten() {
                    if e.file_type().is_ok_and(|t| t.is_dir()) {
                        abrir(&e.path());
                    }
                }
            }
        }
        abrir(ruta);
    }
    let _ = std::fs::remove_dir_all(ruta);
}

#[cfg(test)]
mod escritura_atomica {
    use super::*;

    fn temporal(nombre: &str) -> PathBuf {
        let dir = crate::paths::temporal_de_pruebas().join(format!(
            "nb-atomica-{nombre}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("directorio");
        dir
    }

    /// Regresión: la portada de un EPUB de dos megabytes se leyó a medias.
    ///
    /// Ocurrió de verdad, en `tests/metadatos.rs`: el servicio de metadatos
    /// escribía la portada mientras otro hilo comprobaba si existía, y esa
    /// comprobación la encontró creada con 765 952 de sus 2 097 152 bytes. Con
    /// `fs::write` el archivo aparece vacío y se llena a la vista de todos; aquí
    /// no aparece hasta que está entero.
    #[test]
    fn el_destino_no_existe_mientras_se_escribe() {
        let dir = temporal("durante");
        let destino = dir.join("portada.png");

        write_atomic(&destino, |parcial| {
            std::fs::write(parcial, vec![7_u8; 4096]).expect("escritura");
            assert!(
                !destino.exists(),
                "quien mire ahora mismo no debe ver nada, y menos algo a medias"
            );
            Ok(())
        })
        .expect("escritura atómica");

        assert_eq!(
            std::fs::read(&destino).expect("lectura").len(),
            4096,
            "y al terminar está entero"
        );
    }

    #[test]
    fn una_escritura_fallida_no_deja_ni_destino_ni_restos() {
        let dir = temporal("fallo");
        let destino = dir.join("pagina.png");

        let resultado = write_atomic(&destino, |parcial| {
            std::fs::write(parcial, b"a medias").expect("escritura");
            Err(NbError::StorageFailure)
        });

        assert_eq!(resultado.err(), Some(NbError::StorageFailure));
        assert!(!destino.exists(), "un fallo no deja un archivo a medias");
        assert_eq!(
            std::fs::read_dir(&dir).expect("caché").count(),
            0,
            "ni restos que nada limpie después"
        );
    }

    #[test]
    fn reescribir_encima_sustituye_sin_dejar_hueco() {
        let dir = temporal("encima");
        let destino = dir.join("pagina.png");
        std::fs::write(&destino, b"anterior").expect("primera");

        write_atomic(&destino, |parcial| {
            std::fs::write(parcial, b"posterior mas larga").expect("segunda");
            // El archivo viejo sigue completo hasta el instante del renombrado:
            // nunca hay un momento en que la caché esté vacía.
            assert_eq!(std::fs::read(&destino).expect("lectura"), b"anterior");
            Ok(())
        })
        .expect("escritura atómica");

        assert_eq!(
            std::fs::read(&destino).expect("lectura"),
            b"posterior mas larga"
        );
        assert_eq!(std::fs::read_dir(&dir).expect("caché").count(), 1);
    }
}

#[cfg(test)]
mod lectura_sin_hora_de_acceso {
    use super::*;

    #[test]
    fn open_noatime_lee_archivo_existente_y_falla_si_no_existe() {
        let dir =
            crate::paths::temporal_de_pruebas().join(format!("nb-noatime-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let ruta = dir.join("prueba.txt");
        std::fs::write(&ruta, b"contenido de prueba").expect("escritura");

        let mut archivo = open_noatime(&ruta).expect("abrir con open_noatime");
        let mut contenido = Vec::new();
        std::io::Read::read_to_end(&mut archivo, &mut contenido).expect("lectura");
        assert_eq!(contenido, b"contenido de prueba");

        let bytes = read_bytes_noatime(&ruta).expect("read_bytes_noatime");
        assert_eq!(bytes, b"contenido de prueba");

        let inexistente = dir.join("no_existe.txt");
        assert_eq!(
            open_noatime(&inexistente).unwrap_err().kind(),
            std::io::ErrorKind::NotFound
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn degrada_con_elegancia_si_el_archivo_no_admite_o_noatime() {
        // En Linux, abrir un archivo del sistema que no pertenece al usuario (p. ej. /etc/hosts)
        // con O_NOATIME devuelve EPERM a menos que el proceso tenga CAP_FOWNER.
        // open_noatime debe capturar el error y degradar a File::open estándar sin fallar.
        let hosts = Path::new("/etc/hosts");
        if hosts.exists() {
            let resultado = open_noatime(hosts);
            assert!(
                resultado.is_ok(),
                "debe degradar y abrir /etc/hosts exitosamente"
            );
        }
    }
}
