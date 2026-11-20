# Pruebas

> **Estado:** Implementado.

| Suite | Qué comprueba |
|---|---|
| `test/data/` | El esquema: una posición que no es un Locator se rechaza en la base; `origen` solo admite `pc` o `telefono` |
| `test/features/sync/` | Las respuestas grabadas por NB Books se aplican como el contrato dice, y una lápida quita la edición |
| `test/features/local_books/` | Lo anotado en un libro del teléfono nunca llega al PC |
| `test/features/library/` | Las estanterías: un libro en cada autor, series por su número, colecciones con lo que hay, orden sin tildes; los filtros y el orden de Biblioteca |
| `test/features/profile/` | Las estadísticas: la racha de días, el tope a una sesión olvidada abierta y cómo se enseña el tiempo |
| `native/tests/conformidad.rs` | El motor del teléfono responde exactamente lo grabado en el corpus de conformidad de NB Books |

`test/support/pc_falso.dart` es un PC de mentira que sirve las respuestas de `test/fixtures/contrato-pc/` y apunta lo
que el teléfono le envía.

## Guardianes

`dart run tool/guardianes/todos.dart` ejecuta:

| Guardián | Regla |
|---|---|
| `red.dart` | Red solo en `lib/core/network/`; ninguna conexión en Kotlin; ningún crate de red en `native/` |
| `registro.dart` | Ningún registro en Dart, Kotlin ni Rust, y la inspección de la página del lector solo en depuración |
| `i18n.dart` | Cada texto con su traducción y los mismos marcadores |
| `licencias.dart` | Licencias de `pubspec.lock` y `native/Cargo.lock`, y avisos al día |
| `secretos.dart` | Ninguna clave privada, almacén de firma ni configuración de agentes |
| `version.dart` | La misma versión y fecha en `pubspec.yaml`, `plataforma.dart`, `CHANGELOG.md` y `CITATION.cff` |
| `docs.dart` | Título, estado, enlaces, sin emoji, sin rutas locales ni trabajo pendiente |
| `motor.dart` | La exportación coincide con su manifiesto; el puente solo se usa desde `lib/core/motor/`; las dos versiones de `flutter_rust_bridge` coinciden |
| `locator.dart` | Cada columna de posición tiene su comprobación y el corpus de conformidad pasa |

## En un dispositivo

Antes de publicar: instalar encima de la versión anterior, emparejar con un NB Books real, elegir, descargar, leer,
anotar, sincronizar y comprobar en el PC que lo anotado cae en el mismo pasaje; Leer en el PC con las teclas de
volumen.
