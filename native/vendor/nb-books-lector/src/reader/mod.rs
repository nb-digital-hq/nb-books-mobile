//! Lo que el lector necesita de un documento: la posición, el contrato de formato
//! y los proveedores de EPUB, PDF y cómic.
//!
//! Lo que depende de la biblioteca (la sesión abierta, el progreso guardado) no
//! está aquí: vive en la aplicación que usa el motor.
//!
//! Contrato: `docs/architecture/reader-contracts.md`.

pub mod comic;
pub mod epub;
pub mod locator;
pub mod pdf;
pub mod provider;
pub mod sanitize;
pub mod secciones;
pub mod segmentos;

pub use locator::{Locations, Locator, TextContext, LOCATOR_VERSION};
pub use provider::{
    DocumentProvider, FitMode, NativePosition, Navigation, NavigationEntry, PageSize, Precision,
    ProviderFactory, ProviderRegistry, ReaderCapabilities, Rendered, Resolution, SynchronizedAudio,
    TextLayer, TextLayerStatus, TextSpan,
};
