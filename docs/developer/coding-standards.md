# Normas de código

> **Estado:** Aplicable.

* `analysis_options.yaml` con `flutter_lints` y reglas estrictas de tipos; `flutter analyze` sin avisos.
* `dart format` y `cargo fmt` sin cambios; `cargo clippy -D warnings` en `native/`.
* Identificadores, comentarios y documentación en español. Los comentarios explican **por qué**: lo descartado y la
  razón cuando la decisión no es obvia. No narran el historial del código.
* Sin emoticonos en ninguna parte ni marcas de trabajo pendiente.
* Textos visibles siempre con `tr('...')` ([internacionalización](../architecture/i18n.md)).
* Nada de red fuera de `lib/core/network/`, nada de registros y nada del motor fuera de `lib/core/motor/`
  ([Constitución](../architecture/constitution.md)).
* `native/vendor/` no se edita: se cambia en NB Books y se exporta.
* Los errores esperables se convierten en estados de la interfaz con un mensaje para la persona; ninguna pantalla
  muestra trazas.
* Cada propiedad nueva lleva su prueba y cada defecto corregido, su prueba de regresión. Las pruebas se nombran por
  la propiedad que comprueban.
