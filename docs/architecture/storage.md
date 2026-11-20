# Almacenamiento

> **Estado:** Implementado.

## Base de datos

Drift sobre SQLite, en `nb_books.sqlite` dentro de la carpeta de datos de la app. Esquema versión `1`; una
migración publicada no se edita.

| Tabla | Dueño | Qué guarda |
|---|---|---|
| `ediciones` | PC o teléfono (`origen`) | Ficha, huella, tipo, ruta del archivo y de la portada |
| `colecciones` | PC | Colecciones con sus ediciones |
| `anotaciones` | Quien la crea | Tipo, texto, Locator, alta, baja y a quién sustituye; los trazos del PC llegan con su dibujo y se guardan sin pintarse |
| `posiciones` | Cada dispositivo | Una por edición y dispositivo (`telefono` o `pc`) |
| `sesiones` | Quien la crea | Inicio, fin y Locators de una lectura |
| `vocabulario` | Quien la crea | Palabras consultadas con su Locator |
| `tarjetas` | PC | Tarjetas de estudio y su estado de repaso |
| `repasos` | Quien repasa | El registro de calificaciones del que sale el estado |
| `notas` | PC, con propuestas del teléfono | Notas enlazadas y su revisión |
| `ajustes` | Teléfono | Versión del manifiesto, última sincronización, preferencias, nombre y ruta de la foto del perfil, búsquedas recientes y la vista elegida en Biblioteca y Estudio |

Lo que el teléfono crea lleva `pendiente` hasta que el PC lo confirma. Toda columna de posición tiene un `CHECK` que
exige JSON válido con `href` de texto; la comprobación usa `IS` y no `=`, porque un `CHECK` que da NULL deja pasar
la fila.

## Archivos

| Carpeta | Qué contiene |
|---|---|
| `libros/` | Libros descargados, nombrados por su huella |
| `libros/temporal/` | Libros traídos para leer sin descargar; se recorta sola por debajo de 300 MB, empezando por lo menos leído |
| `telefono/` | Libros añadidos desde el teléfono, copiados; el original no se toca |
| `portadas/` | Portadas del PC |
| `perfil-<instante>` | La foto de perfil, copiada desde la galería; se borra al cambiarla o quitarla |
| caché de la app, `motor/` | Imágenes y recursos que el motor extrae al abrir |

Una descarga se escribe en `.parcial`, se reanuda con `Range` y solo se acepta si su SHA-256 coincide con la huella
del PC.

## Secretos y preferencias

El `device_token`, la huella del certificado y la dirección del PC viven en el llavero del sistema
(`flutter_secure_storage`), nunca en la base. Tema, idioma y ajustes de lectura van en la tabla `ajustes`.
