//! Motor de lectura de NB Books.
//!
//! # Por qué es un crate aparte
//!
//! Una posición de lectura es un Locator, y en EPUB su fragmento es un
//! desplazamiento sobre el texto que extrae este motor. Si otra aplicación
//! —NB Books Mobile— leyera los mismos documentos con otro motor, el mismo
//! desplazamiento señalaría otro sitio, y cada anotación cruzada entre
//! dispositivos llegaría reanclada. Por eso el motor es uno y lo usan las dos:
//! la paridad de posiciones es una consecuencia de su forma, no una prueba que
//! hay que acordarse de pasar.
//!
//! # Qué hay dentro y qué no
//!
//! Lo que hace falta para abrir, sanear, pintar y anclar un documento sin una
//! biblioteca detrás: los errores canónicos, el lector de ZIP con sus límites,
//! los metadatos de EPUB, la validación de rutas, la identidad por contenido y
//! los proveedores de formato, y el cálculo determinista del repaso espaciado,
//! que los dos dispositivos reproducen a partir del mismo registro de repasos.
//! No hay base de datos, ni red, ni interfaz.
//!
//! Contrato: `docs/architecture/reader-contracts.md`.

pub mod epub;
pub mod error;
pub mod library;
pub mod paths;
pub mod reader;
pub mod repaso_espaciado;
pub mod security;
pub mod telemetry;
pub mod zip;
