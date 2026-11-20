# Motor de lectura

> **Estado:** Implementado. Decisión: [ADR-008](../adr/008-shared-reading-engine.md).

## Qué es

`native/vendor/nb-books-lector` es una copia sellada del crate `nb-books-lector` de NB Books: lector de ZIP con
límites contra bombas, EPUB, saneador por lista de permitidos, Locator, cómic y PDF. `MANIFIESTO` guarda la huella
SHA-256 de cada archivo. No se edita aquí: se cambia en NB Books y se vuelve a exportar con
`tool/exportar_motor.sh <ruta a NB Books>`.

`native/src/api.rs` es la superficie que ve Dart: abrir y cerrar, lomo, índice, marcado de un recurso, Locator de
un punto, resolución de un Locator, Locator de una cita, fragmentos de texto, página de PDF como imagen y huella
de un archivo. `flutter_rust_bridge` 2.13 genera `lib/core/motor/puente/` (versionado) y `Motor`, en
`lib/core/motor/motor.dart`, es la única clase que lo llama.

## PDF

PDFium es la misma compilación que usa NB Books (`chromium/7881`, sin motor de JavaScript).
`dart run tool/motor.dart` la descarga por ABI, comprueba su huella antes de escribirla y la deja junto al motor en
`android/app/src/main/jniLibs/`. En iOS el motor se enlaza estático y PDF no está disponible.

## El Locator

Una posición es un objeto JSON con `href`, `mediaType`, `locations` (`fragments` con `#char=N`, `progression` y
`totalProgression`) y `text` (`before`, `highlight`, `after`). `#char=N` cuenta caracteres del texto que produce el
saneador de NB Books; por eso solo el mismo motor puede producirlo. El teléfono guarda el Locator tal cual y nunca
lo reinterpreta. Al anclar una cita, el motor tolera que la página haya perdido espacios o caracteres invisibles del
libro, sin mover el `#char`.

## El corpus de conformidad

`tests/conformidad.rs` en el crate de NB Books genera un EPUB de contenido fijo, inventado, y pide al motor el lomo,
el índice, Locators en varios puntos, su resolución, Locators de citas, fragmentos de texto y la huella del marcado
de cada recurso. El resultado grabado es `tests/conformidad.json`. La exportación lleva los dos archivos y
`native/tests/conformidad.rs` los ejecuta contra la copia del teléfono: si los dos motores pasan, señalan lo mismo.
Regrabar el corpus es aceptar que las posiciones guardadas se mueven, y eso es un cambio de contrato.
