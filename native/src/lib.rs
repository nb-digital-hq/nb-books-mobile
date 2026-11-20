//! El puente entre NB Books Mobile y el motor de lectura de NB Books.
//!
//! El teléfono no reimplementa nada de lo que calcula NB Books: abre, pinta,
//! localiza y repasa con el mismo crate, `nb-books-lector`, que llega sellado en
//! `vendor/` (ADR-008). Este crate solo lo expone a Dart.
//!
//! La frontera habla JSON a propósito: los tipos del motor ya se serializan así
//! para la interfaz de NB Books, y reflejarlos uno por uno en Dart sería una
//! segunda definición que se desincroniza en cuanto el motor añade un campo.

pub mod api;
mod frb_generated;
