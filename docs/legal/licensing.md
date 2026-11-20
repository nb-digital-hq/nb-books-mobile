# Licencias

> **Estado:** Aplicable. Decisión: [ADR-003](../adr/003-licensing-model.md).

## Decisión vigente

| Elemento | Decisión |
|---|---|
| Licencia del código | **Apache License 2.0** |
| Licencia de la documentación | Apache License 2.0 |
| Modelo de NB Digital | Aplicaciones para personas de código abierto; módulos y servicios institucionales con licencia comercial, separados |
| Procedencia de las contribuciones | **DCO** (`Signed-off-by`), sin acuerdo de cesión |
| Aviso de copyright | `Copyright 2026 The NB Books Mobile Authors`; cada contribuidor conserva el suyo |
| Marcas | "NB", "NB Digital", "NB Books" y "NB Books Mobile", fuera de la licencia; ver [marcas](trademark.md) |

`LICENSE` y `NOTICE` están en la raíz del repositorio. El motor de lectura exportado de NB Books es también Apache 2.0.

## La frontera con lo comercial

| Componente | Licencia |
|---|---|
| NB Books Mobile: app, motor, código nativo, herramientas y documentación | Apache 2.0 |
| Fuentes Manrope y Space Grotesk | SIL Open Font License 1.1 |
| Dependencias de Dart y crates de Rust | La de cada una ([avisos](third-party-notices.md)), todas permisivas |
| PDFium | BSD-3-Clause y Apache-2.0 |
| Módulos y servicios institucionales de NB Digital | Licencia comercial, fuera de este repositorio |

Ningún componente de la app depende de un producto comercial. Un cambio que introduzca esa dependencia se rechaza.

## Consecuencias operativas

* **Dependencias:** solo licencias permisivas; sin GPL, AGPL, LGPL, MPL ni binarios propietarios
  ([política de dependencias](../architecture/dependency-policy.md)). El escáner QR usa ZXing en lugar de ML Kit por
  esta razón ([ADR-005](../adr/005-qr-scanner.md)).
* **Contenido de demostración:** los libros de las capturas y del video son inventados y los genera la app; el
  repositorio no contiene libros, portadas ni textos de terceros.
