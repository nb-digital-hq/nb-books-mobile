//! Tipo de error de dominio de NB Books.
//!
//! Ningún error cruza el puente IPC como cadena de texto. Rust devuelve códigos
//! canónicos estables y la capa de internacionalización del frontend los traduce.
//! Ver `docs/developer/coding-standards/error-handling.md` y
//! `docs/architecture/i18n.md`.

use serde::Serialize;
use ts_rs::TS;

/// Error de dominio. Cada variante tiene un código canónico estable que forma
/// parte del contrato con el frontend: **renombrar un código es un cambio
/// incompatible**. Ver `docs/architecture/versioning.md`.
// `PartialEq` porque las pruebas comparan resultados enteros
// (`assert_eq!(resultado, Err(NbError::DocumentCorrupted))`), y sin ella habría
// que escribir un `matches!` que se lee peor y que no dice qué se recibió cuando
// falla. Son variantes sin datos: la comparación es la identidad de la variante.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum NbError {
    #[error("el archivo solicitado no existe")]
    FileNotFound,

    #[error("la ruta queda fuera del ámbito permitido")]
    PathNotAllowed,

    #[error("el formato del documento no está soportado")]
    FormatUnsupported,

    #[error("el documento está dañado o mal formado")]
    DocumentCorrupted,

    #[error("el documento solicitado no existe en la biblioteca")]
    DocumentNotFound,

    #[error("fallo de la capa de almacenamiento")]
    StorageFailure,

    #[error("la base de datos está en una versión distinta de la esperada")]
    SchemaMismatch,

    #[error("el componente solicitado no está disponible")]
    ComponentUnavailable,

    #[error("el modo sin red está activado")]
    NetworkDisabled,

    #[error("hace falta consentimiento para salir a ese destino")]
    ConsentRequired,

    #[error("la petición de red no se pudo completar")]
    NetworkFailure,

    #[error("operación cancelada")]
    Cancelled,

    /// Lo derivado llegó al tope de disco que fija el innegociable, así que no
    /// se genera más. No es un fallo de almacenamiento -el disco responde- ni una
    /// cancelación: es una decisión del producto, y lo que hay que ofrecer es
    /// liberar sitio o subir el tope en Ajustes. Ninguno de los otros dieciocho
    /// permite decir eso.
    #[error("lo derivado llegó al presupuesto de disco")]
    StorageBudgetReached,

    #[error("error interno no clasificado")]
    Internal,

    // --- Extensiones -------------------------------------------
    //
    // Cuatro y no cinco. La especificación pedía también uno para
    // "permiso denegado", y no se añade: `ConsentRequired` ya dice exactamente
    // eso y ya está traducido. Un código nuevo para lo mismo obligaría al
    // frontend a distinguir dos cosas que no se distinguen.
    #[error("el manifiesto de la extensión no es válido")]
    ExtensionManifestInvalid,

    #[error("la extensión se compiló contra una versión de la API que no se soporta")]
    ExtensionApiUnsupported,

    #[error("la extensión se pasó de los recursos que tenía concedidos")]
    ExtensionLimitExceeded,

    #[error("no hay una generación anterior a la que volver")]
    ExtensionRollbackUnavailable,

    /// La actualización no está firmada por quien firmó lo que ya está
    /// instalado. Es un código propio y no un `PathNotAllowed` cualquiera
    /// porque lo que hay que decirle a quien lo ve es muy concreto: esto no es
    /// una versión nueva de lo que tienes, venga de donde venga.
    #[error("la actualización no la firma quien firmó la versión instalada")]
    ExtensionSignatureMismatch,
}

impl NbError {
    /// Código canónico en mayúsculas. Es lo que el frontend usa para elegir el
    /// mensaje localizado; nunca se muestra al usuario tal cual.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::FileNotFound => "FILE_NOT_FOUND",
            Self::PathNotAllowed => "PATH_NOT_ALLOWED",
            Self::FormatUnsupported => "FORMAT_UNSUPPORTED",
            Self::DocumentCorrupted => "DOCUMENT_CORRUPTED",
            Self::DocumentNotFound => "DOCUMENT_NOT_FOUND",
            Self::StorageFailure => "STORAGE_FAILURE",
            Self::SchemaMismatch => "SCHEMA_MISMATCH",
            Self::ComponentUnavailable => "COMPONENT_UNAVAILABLE",
            Self::NetworkDisabled => "NETWORK_DISABLED",
            Self::ConsentRequired => "CONSENT_REQUIRED",
            Self::NetworkFailure => "NETWORK_FAILURE",
            Self::Cancelled => "CANCELLED",
            Self::StorageBudgetReached => "STORAGE_BUDGET_REACHED",
            Self::Internal => "INTERNAL",
            Self::ExtensionManifestInvalid => "EXTENSION_MANIFEST_INVALID",
            Self::ExtensionApiUnsupported => "EXTENSION_API_UNSUPPORTED",
            Self::ExtensionLimitExceeded => "EXTENSION_LIMIT_EXCEEDED",
            Self::ExtensionRollbackUnavailable => "EXTENSION_ROLLBACK_UNAVAILABLE",
            Self::ExtensionSignatureMismatch => "EXTENSION_SIGNATURE_MISMATCH",
        }
    }
}

/// Todas las variantes, en el orden en que se declaran.
///
/// Existe para que nada que recorra los errores lo haga sobre una muestra: la
/// prueba de estabilidad los recorre todos, y el generador de la lista para el
/// frontend también. Añadir una variante sin añadirla aquí hace fallar la
/// prueba que fija cuántas hay.
pub const TODAS: &[NbError] = &[
    NbError::FileNotFound,
    NbError::PathNotAllowed,
    NbError::FormatUnsupported,
    NbError::DocumentCorrupted,
    NbError::DocumentNotFound,
    NbError::StorageFailure,
    NbError::SchemaMismatch,
    NbError::ComponentUnavailable,
    NbError::NetworkDisabled,
    NbError::ConsentRequired,
    NbError::NetworkFailure,
    NbError::Cancelled,
    NbError::StorageBudgetReached,
    NbError::Internal,
    NbError::ExtensionManifestInvalid,
    NbError::ExtensionApiUnsupported,
    NbError::ExtensionLimitExceeded,
    NbError::ExtensionRollbackUnavailable,
    NbError::ExtensionSignatureMismatch,
];

/// Escribe la lista de códigos canónicos que consume la capa de traducción.
///
/// Mismo mecanismo que los valores por defecto del primer pintado: el nombre
/// empieza por `export_bindings_` para que `pnpm check:bindings` la ejecute y
/// compruebe que el árbol no queda sucio.
///
/// Existe porque la interfaz exige que **todo** código tenga mensaje en todos los
/// idiomas, y una lista escrita a mano en TypeScript convertiría esa exigencia
/// en una promesa: se añadiría una variante en Rust, nadie la traduciría, y el
/// usuario vería un código en mayúsculas en mitad de la interfaz.
#[cfg(test)]
#[test]
#[allow(non_snake_case)]
fn export_bindings_errorcodes() {
    use std::fmt::Write as _;

    let mut ts = [
        "// This file was generated by NB Books from src-tauri/lector/src/error.rs.",
        "// Do not edit this file manually.",
        "",
        "/**",
        " * Los códigos de error canónicos que puede devolver el runtime.",
        " *",
        " * Se generan desde Rust para que no puedan divergir de él en silencio: la",
        " * prueba de la capa de traducción los recorre y exige mensaje en cada idioma.",
        " */",
        "export const ERROR_CODES = [",
        "",
    ]
    .join("\n");

    for variante in TODAS {
        let _ = writeln!(ts, "  '{}',", variante.code());
    }
    ts.push_str("] as const;\n\n");
    ts.push_str("/** Un código de error del runtime. */\n");
    ts.push_str("export type ErrorCode = (typeof ERROR_CODES)[number];\n");

    let destino = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../src/lib/bindings/errorCodes.ts");
    std::fs::write(destino, ts).expect("no se pudieron escribir los códigos de error");
}

/// Forma serializada que cruza el puente IPC.
///
/// No transporta detalles de la infraestructura subyacente: exponer el mensaje
/// de una biblioteca de terceros filtra información y acopla el frontend a la
/// implementación.
#[derive(Debug, Serialize, TS)]
#[ts(export, export_to = "../../src/lib/bindings/")]
pub struct NbErrorPayload {
    pub code: String,
}

impl serde::Serialize for NbError {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        NbErrorPayload {
            code: self.code().to_owned(),
        }
        .serialize(serializer)
    }
}

/// Alias del resultado usado en toda la superficie pública del runtime.
pub type NbResult<T> = std::result::Result<T, NbError>;

#[cfg(test)]
mod tests {
    use super::*;

    use super::TODAS;

    /// Copia deliberadamente independiente de [`NbError::code`].
    ///
    /// Duplicar la tabla es el objetivo, no un descuido: si la prueba llamara a
    /// `code()` para saber qué esperar, renombrar un código pasaría en verde. Y
    /// el `match` es exhaustivo, de modo que **una variante nueva no compila**
    /// hasta que alguien decide conscientemente su código canónico.
    fn codigo_esperado(error: &NbError) -> &'static str {
        match error {
            NbError::FileNotFound => "FILE_NOT_FOUND",
            NbError::PathNotAllowed => "PATH_NOT_ALLOWED",
            NbError::FormatUnsupported => "FORMAT_UNSUPPORTED",
            NbError::DocumentCorrupted => "DOCUMENT_CORRUPTED",
            NbError::DocumentNotFound => "DOCUMENT_NOT_FOUND",
            NbError::StorageFailure => "STORAGE_FAILURE",
            NbError::SchemaMismatch => "SCHEMA_MISMATCH",
            NbError::ComponentUnavailable => "COMPONENT_UNAVAILABLE",
            NbError::NetworkDisabled => "NETWORK_DISABLED",
            NbError::ConsentRequired => "CONSENT_REQUIRED",
            NbError::NetworkFailure => "NETWORK_FAILURE",
            NbError::Cancelled => "CANCELLED",
            NbError::StorageBudgetReached => "STORAGE_BUDGET_REACHED",
            NbError::Internal => "INTERNAL",
            NbError::ExtensionManifestInvalid => "EXTENSION_MANIFEST_INVALID",
            NbError::ExtensionApiUnsupported => "EXTENSION_API_UNSUPPORTED",
            NbError::ExtensionLimitExceeded => "EXTENSION_LIMIT_EXCEEDED",
            NbError::ExtensionRollbackUnavailable => "EXTENSION_ROLLBACK_UNAVAILABLE",
            NbError::ExtensionSignatureMismatch => "EXTENSION_SIGNATURE_MISMATCH",
        }
    }

    /// Los códigos forman parte del contrato público: si esta prueba falla, el
    /// cambio es incompatible y necesita entrada en el registro de versionado.
    #[test]
    fn los_codigos_son_estables() {
        // Trece: la salida de red trajo tres situaciones que el
        // frontend tiene que distinguir para poder hacer algo distinto con cada
        // una. Reutilizar códigos existentes habría sido mentir: "no está
        // disponible" y "hace falta que lo autorices" piden acciones opuestas.
        //
        // Diecisiete, por el mismo criterio: un manifiesto
        // inválido, una API que no se habla, un límite agotado y una reversión
        // sin destino piden cuatro acciones distintas, y ninguna es la de los
        // trece anteriores. "Permiso denegado" no entra: `CONSENT_REQUIRED` ya
        // dice eso, y duplicarlo obligaría a distinguir lo que no se distingue.
        //
        // Dieciocho. Que una actualización no la firme quien firmó
        // lo instalado no es "no tienes permiso" ni "el manifiesto está mal": lo
        // que hay que decirle a quien lo ve es que **esto no es una versión
        // nueva de lo que tiene**, venga de donde venga, y esa frase no la
        // permite ninguno de los diecisiete anteriores.
        // Diecinueve. Preparar un audiolibro puede no caber en el
        // presupuesto de lo derivado, y eso no es "el almacenamiento falló" ni
        // "lo cancelaste": el disco responde y nadie canceló nada. Lo que hay que
        // ofrecer -liberar sitio, o subir el tope en Ajustes- no lo permite decir
        // ninguno de los dieciocho anteriores. El código es el mismo nombre con
        // que el indexador publica su pausa, y una prueba de
        // `search` lo ata para que no puedan separarse.
        assert_eq!(
            TODAS.len(),
            19,
            "hay una variante de NbError fuera de la lista de la prueba"
        );

        for variante in TODAS {
            assert_eq!(
                variante.code(),
                codigo_esperado(variante),
                "código inestable en {variante:?}"
            );
        }
    }

    /// Dos variantes con el mismo código dejarían al frontend sin poder
    /// distinguirlas, y un código en minúsculas rompería la convención que la
    /// capa de internacionalización usa como clave.
    #[test]
    fn los_codigos_son_unicos_y_canonicos() {
        let codigos: std::collections::BTreeSet<_> = TODAS.iter().map(NbError::code).collect();

        assert_eq!(codigos.len(), TODAS.len(), "hay códigos repetidos");
        for codigo in &codigos {
            assert!(
                codigo.chars().all(|c| c.is_ascii_uppercase() || c == '_'),
                "el código {codigo} no es un identificador canónico"
            );
        }
    }

    #[test]
    fn se_serializa_solo_el_codigo() {
        let json = serde_json::to_string(&NbError::DocumentNotFound).expect("serializable");
        assert_eq!(json, r#"{"code":"DOCUMENT_NOT_FOUND"}"#);
    }

    /// Ningún mensaje de error puede filtrar rutas ni detalles internos.
    #[test]
    fn el_payload_no_contiene_detalles_internos() {
        let json = serde_json::to_string(&NbError::StorageFailure).expect("serializable");
        assert!(!json.contains("sqlite"));
        assert!(!json.contains('/'));
    }
}
