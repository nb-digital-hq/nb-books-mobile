# Constitución

> **Estado:** Aplicable. Se modifica únicamente mediante un ADR aceptado.

Ningún cambio se integra en `main` si rompe una de estas reglas. Cada regla dice qué la hace cumplir: una regla
sin mecanismo es una intención.

## 1. Nada sale del teléfono sin que la persona lo pida

La app solo habla con el PC que la persona emparejó y, en Android, con GitHub cuando pulsa "Buscar
actualizaciones". No hay telemetría, analítica, informes de fallos ni cuentas. El motor de lectura no abre
conexiones.

**Mecanismo:** `tool/guardianes/red.dart` rechaza cualquier cliente de red fuera de `lib/core/network/`, cualquier
conexión en el código nativo de Android y cualquier crate de red en `native/` ([ADR-004](../adr/004-network-exit.md)).

## 2. Nada de la persona en los registros

La app no escribe registros: ni `print` en Dart, ni `Log` en Kotlin, ni `println!` en Rust. Títulos, pasajes, rutas
y direcciones del PC no llegan nunca al logcat.

**Mecanismo:** `tool/guardianes/registro.dart`.

## 3. Ninguna posición es un entero

Toda posición guardada (progreso, anotación, sesión, vocabulario) es un Locator calculado por el motor de NB Books.
Una anotación hecha en el teléfono cae en el mismo pasaje en el PC, y al revés.

**Mecanismo:** el esquema de Drift rechaza lo que no es un Locator, y `tool/guardianes/locator.dart` reproduce el
corpus de conformidad contra el motor del teléfono ([motor de lectura](reading-engine.md)).

## 4. Un solo motor de lectura

El teléfono no reimplementa lo que calcula NB Books: abre, sanea, segmenta y sitúa con el mismo crate.

**Mecanismo:** `tool/guardianes/motor.dart` comprueba la exportación sellada contra su manifiesto de huellas y que
nada fuera de `lib/core/motor/` llame al puente ([ADR-008](../adr/008-shared-reading-engine.md)).

## 5. Cada dato viaja en un sentido

Lo del PC se aplica como llega; lo hecho en el teléfono se suma y nunca pisa lo del PC. Los libros del teléfono, y
lo anotado en ellos, no salen del teléfono.

**Mecanismo:** pruebas de `test/features/sync/` y `test/features/local_books/` contra las respuestas grabadas por
NB Books ([ADR-002](../adr/002-data-ownership.md)).

## 6. Lo que se distribuye es abierto

Todo componente dentro del APK o del `.ipa` es compatible con Apache 2.0 y de código abierto, incluidos los crates
de Rust del motor y PDFium.

**Mecanismo:** `tool/guardianes/licencias.dart` clasifica `pubspec.lock` y `native/Cargo.lock` y regenera los
avisos ([ADR-003](../adr/003-licensing-model.md)).

## 7. Toda la interfaz en tres idiomas

Ningún texto visible queda solo en español.

**Mecanismo:** `tool/guardianes/i18n.dart` ([ADR-006](../adr/006-internationalization.md)).

## 8. La documentación es parte del cambio

Un cambio con impacto en la arquitectura o en el uso no está terminado hasta que su documento lo refleja, con su
etiqueta de estado.

**Mecanismo:** revisión y `tool/guardianes/docs.dart`.
