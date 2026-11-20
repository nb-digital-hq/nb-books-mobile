# Avisos de terceros

> **Estado:** Implementado. Se genera con `dart run tool/guardianes/licencias.dart --escribir`.

`THIRD-PARTY-NOTICES.md`, en la raíz, contiene el texto completo de la licencia de cada paquete de Dart que se
distribuye con la app, la tabla de crates de Rust enlazados en el motor con su licencia, y el aviso de PDFium. La CI
falla si no coincide con las dependencias. Cada publicación lo adjunta.

Además, la app incluye las fuentes Manrope y Space Grotesk (SIL Open Font License 1.1) y, a través de los paquetes,
bibliotecas nativas con licencias permisivas: AndroidX y CameraX (Apache-2.0), zxing-cpp (Apache-2.0), SQLite
(dominio público) y PDFium (BSD-3-Clause y Apache-2.0).
