//! Identidad de un archivo por su contenido.
//!
//! Vive en el motor porque la identidad la necesita quien abre un documento
//! —las imágenes de un EPUB y las páginas de un cómic se nombran por ella— y no
//! solo quien lo cataloga. Contrato: `docs/architecture/storage.md`.

use std::io::Read;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{NbError, NbResult};

/// Tamaño del fragmento con el que se recorre el archivo.
///
/// Fijo y modesto a propósito: un EPUB típico ocupa un megabyte, pero un PDF
/// escaneado pasa del gigabyte, y leerlo entero en memoria para calcular su
/// identidad convertiría una importación masiva en un fallo por falta de
/// memoria. El coste de un búfer pequeño es una llamada más al sistema; el
/// coste de no tenerlo es que la aplicación muera con la biblioteca de alguien
/// a medio importar.
pub const FRAGMENTO: usize = 128 * 1024;

/// Identidad de un archivo por su contenido.
///
/// Es un tipo y no una cadena porque su forma es un contrato que sobrevive a la
/// biblioteca: si mañana hiciera falta otro algoritmo, hay que poder distinguir
/// los hashes viejos de los nuevos sin rehashear 150 000 archivos para
/// averiguarlo. De ahí el prefijo del algoritmo, como en las sumas de
/// integridad de subrecurso o en los digests de contenedor.
///
/// Forma: `sha256:` seguido de 64 caracteres hexadecimales en minúscula.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ContentHash(String);

impl ContentHash {
    /// Prefijo del único algoritmo en uso.
    pub const ALGORITMO: &'static str = "sha256";

    /// Longitud total de la forma canónica: `sha256:` más 64 hexadecimales.
    pub const LONGITUD: usize = 7 + 64;

    /// Construye la identidad a partir del resumen ya calculado.
    #[must_use]
    pub fn from_sha256(digest: &[u8; 32]) -> Self {
        let mut texto = String::with_capacity(Self::LONGITUD);
        texto.push_str(Self::ALGORITMO);
        texto.push(':');
        for byte in digest {
            use std::fmt::Write as _;
            // Ignorar el resultado es correcto: escribir en un String no falla.
            let _ = write!(texto, "{byte:02x}");
        }
        Self(texto)
    }

    /// Lee una identidad almacenada.
    ///
    /// # Errors
    ///
    /// [`NbError::DocumentCorrupted`] si la cadena no tiene la forma canónica.
    /// Una identidad mal formada en la base solo puede venir de una escritura
    /// que se saltó este tipo, y tratarla como válida propagaría el error.
    pub fn parse(texto: &str) -> NbResult<Self> {
        let valido = texto.len() == Self::LONGITUD
            && texto.starts_with("sha256:")
            && texto[7..]
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c));

        if !valido {
            tracing::error!(
                longitud = texto.len(),
                "identidad de contenido con forma inesperada"
            );
            return Err(NbError::DocumentCorrupted);
        }
        Ok(Self(texto.to_owned()))
    }

    /// Forma canónica, tal y como se almacena.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for ContentHash {
    type Error = NbError;

    fn try_from(texto: String) -> Result<Self, Self::Error> {
        Self::parse(&texto)
    }
}

impl From<ContentHash> for String {
    fn from(hash: ContentHash) -> Self {
        hash.0
    }
}

impl std::fmt::Display for ContentHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Calcula la identidad de lo que produce un lector, sin acumularlo en memoria.
///
/// # Errors
///
/// [`NbError::StorageFailure`] si la lectura falla a mitad.
pub fn hash_reader<R: Read>(mut reader: R) -> NbResult<(ContentHash, u64)> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; FRAGMENTO];
    let mut total: u64 = 0;

    loop {
        let leidos = reader.read(&mut buffer).map_err(|error| {
            tracing::error!(error = %error, "fallo al leer mientras se calculaba la identidad");
            NbError::StorageFailure
        })?;
        if leidos == 0 {
            break;
        }
        hasher.update(&buffer[..leidos]);
        total += leidos as u64;
    }

    let digest: [u8; 32] = hasher.finalize().into();
    Ok((ContentHash::from_sha256(&digest), total))
}

/// Calcula la identidad de un archivo del disco.
///
/// # Errors
///
/// - [`NbError::FileNotFound`] si la ruta no existe.
/// - [`NbError::StorageFailure`] si no se puede leer.
pub fn hash_file(path: &Path) -> NbResult<(ContentHash, u64)> {
    let archivo = crate::paths::open_noatime(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            NbError::FileNotFound
        } else {
            tracing::error!(
                ruta = %crate::telemetry::redact_path(path),
                error = %error,
                "no se pudo abrir el archivo para calcular su identidad"
            );
            NbError::StorageFailure
        }
    })?;

    hash_reader(std::io::BufReader::with_capacity(FRAGMENTO, archivo))
}
