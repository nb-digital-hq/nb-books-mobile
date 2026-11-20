# Integración continua

> **Estado:** Implementado.

| Flujo | Cuándo | Qué hace |
|---|---|---|
| `ci.yml` | Cada push a `main` y cada pull request | Procedencia (DCO y Conventional Commits); verificación completa de Dart y Rust; APK de publicación por ABI con el motor y PDFium; compilación de iOS sin firma |
| `ediciones.yml` | A mano | El `.ipa` de iOS sin firmar para una publicación |

La CI no tiene la clave de firma: sus APK se firman con la clave de depuración y no sirven para publicar. Rust y
Flutter van fijados (`RUST_VERSION`, `FLUTTER_VERSION`) a las mismas versiones que en local.
