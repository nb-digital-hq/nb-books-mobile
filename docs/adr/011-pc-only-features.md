# ADR-011: Lo que se queda en el PC

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

NB Books es una aplicación grande: gestión de bibliotecas, extensiones, IA local, voces neuronales, tableros,
catálogos en línea. Un teléfono necesita lo justo para leer bien, anotar y repasar.

## Decisión

| Función de NB Books | En el teléfono |
|---|---|
| Lector de EPUB, PDF y cómic, tipografía, temas, índice, anotaciones y marcadores | Sí |
| Trazos a mano sobre la página | No: se dibujan en el PC con lápiz o ratón. El teléfono los recibe y los conserva para no perderlos al sincronizar, pero no los pinta ni los crea |
| Progreso, notas, vocabulario y repaso espaciado | Sí |
| Lectura en voz alta con las voces del sistema | Sí |
| Diccionarios StarDict y audio preparado por el PC | No: el diccionario y la voz preparada se usan en el PC |
| Búsqueda de texto completo en la biblioteca, por fragmentos y por significado | En directo, con el PC conectado |
| Generar tarjetas, preguntas y resúmenes | No se generan en el teléfono: se generan en el PC y llegan sincronizadas para repasarlas |
| Vista dividida, tableros, estadísticas detalladas | No: necesitan pantalla grande |
| Edición de metadatos, duplicados, importación de Calibre, raíces de biblioteca | No: la gestión de la biblioteca es del PC |
| Voz neuronal e IA locales | No: exigen un cómputo que el teléfono no tiene |
| Catálogos OPDS, enciclopedia y traducción | No: serían destinos de red nuevos desde el teléfono |
| Extensiones | No: superficie de seguridad y de mantenimiento |
| Exportar e importar el estado entero | No: el teléfono se reconstruye sincronizando |

## Consecuencias

* El teléfono no descarga modelos ni índices: lo pesado se consulta al PC.
* Una función de esta tabla solo cambia de fila con otro ADR.
