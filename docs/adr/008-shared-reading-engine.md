# ADR-008: El motor de lectura es el de NB Books

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

NB Books guarda cada posición como un Locator (ADR-004 de NB Books). En EPUB el fragmento es `#char=N`: un
desplazamiento en el texto que extrae su saneador, que además es la barrera frente a documentos hostiles. Para que
una anotación hecha en el teléfono caiga en el mismo sitio en el PC, el teléfono tiene que extraer exactamente el
mismo texto.

## Alternativas consideradas

1. **Un lector de Flutter de terceros.** Otro texto, otras posiciones: cada anotación del teléfono llegaría al PC
   reanclada por cita o por progresión.
2. **Portar el extractor y el saneador a Dart**, con pruebas de conformidad. Dos implementaciones de una barrera de
   seguridad; las pruebas detectan la deriva, no la impiden.
3. **Usar el mismo código Rust**, extraído de NB Books como crate y llamado desde Dart.

## Decisión

Alternativa 3:

* El crate `nb-books-lector` de NB Books (lector de ZIP con límites contra bombas, EPUB, saneador por lista de
  permitidos, Locator, secciones, segmentos, cómic y PDF) llega a `native/vendor/nb-books-lector` como **exportación
  sellada** con su manifiesto de huellas. No se edita a mano: se cambia en NB Books y se vuelve a exportar.
* `native/` lo envuelve con la superficie que necesita la app y la expone con `flutter_rust_bridge`. Solo
  `lib/core/motor/` llama al puente.
* PDF se pinta con PDFium, en la versión que fija NB Books, desde los binarios publicados para Android e iOS.
* Un **corpus de conformidad** generado por NB Books (libros ficticios, sin material con derechos) fija el texto de
  cada recurso y una serie de locators; el móvil los reproduce en sus pruebas. La muestra del corpus real se ejecuta
  en local con `NB_BOOKS_CORPUS`.

## Consecuencias

* Paridad por construcción, y una sola implementación del saneador.
* Si alguna posición no resuelve igual, la cascada de anclaje de NB Books lo cubre: la anotación se reancla por cita
  y se marca. Nunca se pierde.
* `tool/guardianes/motor.dart` comprueba la exportación contra su manifiesto y que nadie fuera de
  `lib/core/motor/` use el puente. Ver [motor de lectura](../architecture/reading-engine.md).
