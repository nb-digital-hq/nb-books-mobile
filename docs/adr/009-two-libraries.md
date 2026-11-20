# ADR-009: Dos bibliotecas, y la persona decide qué llega y qué se ve

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

Una biblioteca de NB Books puede tener cientos de miles de libros y cientos de GB. Copiarla entera al teléfono no
cabe ni tiene sentido. A la vez, mucha gente tiene libros que solo están en el teléfono.

## Alternativas consideradas

1. **Copiar todo al conectar**, como los medios de NB Sound Mobile. Inviable con bibliotecas grandes.
2. **Solo lo que se abre**, sin catálogo. El teléfono no sabría qué hay en el PC.
3. **Selección explícita, descarga a petición y visibilidad elegida por la persona.**

## Decisión

* **Selección** (qué llega): todo, nada, estanterías, colecciones o libro a libro, combinables. De lo seleccionado
  llegan los metadatos, la portada bajo demanda y todo lo ligero de la persona sobre esos libros.
* **Descarga** (qué ocupa espacio): solo el archivo del libro, y solo al pedirlo. Con el PC conectado, un libro seleccionado se puede **leer sin descargar**: se trae a una caché
  temporal con límite de tamaño.
* **Visibilidad** (qué se ve del PC): todo el catálogo, lo seleccionado o solo lo descargado. "Todo el catálogo" se
  pide paginado al PC mientras se mira; no se copia.
* **Biblioteca del teléfono**: libros abiertos o importados desde Archivos. No salen del teléfono. Se pueden quitar
  de la app sin borrarlos y ocultar todos de una vez.

## Consecuencias

* Lo único que tarda es descargar, y solo cuando la persona lo pide.
* Los libros del teléfono se distinguen por su origen en las mismas tablas, y ninguna operación hacia el PC acepta
  uno ([almacenamiento](../architecture/storage.md)).
