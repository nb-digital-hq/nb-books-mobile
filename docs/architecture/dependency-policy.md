# Política de dependencias

> **Estado:** Aplicable. La licencia la comprueba `tool/guardianes/licencias.dart`.

Una dependencia nueva, de Dart o de Rust, se justifica en su pull request por tres criterios:

1. **Coste:** qué añade al tamaño del APK y al arranque, y si el SDK ya lo resuelve.
2. **Licencia:** solo Apache-2.0, MIT, BSD, ISC o Zlib (y, en crates, Unicode, CC0, BSL-1.0 y la excepción LLVM) en
   lo que se distribuye. Nada GPL, AGPL o LGPL, ninguna MPL y ningún binario propietario.
3. **Mantenimiento:** publicaciones recientes y compatibilidad con la versión estable de Flutter y de Rust.

El motor no puede depender de ningún crate de red (`tool/guardianes/red.dart`). Los paquetes que solo se compilan
para escritorio, como `dbus`, no viajan en el APK y no cuentan. `THIRD-PARTY-NOTICES.md` se regenera con
`dart run tool/guardianes/licencias.dart --escribir`; la CI falla si está desactualizado.
