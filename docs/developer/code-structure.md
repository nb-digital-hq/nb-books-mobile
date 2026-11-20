# Estructura del código

> **Estado:** Implementado.

```text
lib/
  main.dart               Arranque: motor, base de datos, demostración
  app/                    Widget raíz, pestañas
  core/motor/             Motor y el puente generado
  core/network/           Única salida de red: clientes, fijación TLS, GitHub
  core/security/          Emparejamiento en el llavero
  core/i18n/              tr() y catálogos
  core/router/            Rutas
  data/db/                Esquema y consultas de Drift
  data/demo/              Biblioteca de demostración
  features/               sync, library, reader, study, search, read_on_pc, local_books, offline, settings, about
  shared/                 Tema y componentes
native/
  src/api.rs              Superficie del motor para Dart
  vendor/nb-books-lector/ Exportación sellada del motor de NB Books
  tests/conformidad.rs    El corpus de conformidad contra la copia del teléfono
android/app/src/main/kotlin/   MainActivity (teclas de volumen) y AppUpdater
ios/                      Proyecto de iOS, sin probar en dispositivo
test/                     Espejo de lib/, con las respuestas grabadas del PC en fixtures/
tool/guardianes/          Guardianes de `just verify` y de la CI
tool/motor.dart           Compila el motor y trae PDFium por ABI
tool/exportar_motor.sh    Vuelve a exportar el motor desde NB Books
```
