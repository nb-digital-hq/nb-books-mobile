# ADR-012: Fotos de autores desde Wikimedia

> **Estado:** Aceptado. Amplía la tabla de destinos de [ADR-004](004-network-exit.md).

**Fecha:** 2026-11-20

## Contexto

La estantería de autores enseñaba un abanico de portadas y no la cara de quien escribió los libros. NB Books en el
PC no guarda fotos de autores, así que el teléfono no puede pedírselas: la única fuente es pública. Hasta ahora
[ADR-004](004-network-exit.md) admitía dos destinos, ambos pedidos por la persona.

## Alternativas consideradas

1. **No tener fotos.** Cero riesgo, menos aspecto.
2. **Que las busque el PC y las sirva.** Cambia el contrato con NB Books y obliga al escritorio a salir a internet
   por algo que solo se ve en el teléfono.
3. **Que las busque el teléfono en Wikidata y Wikimedia Commons, solo si la persona lo enciende.** Fuente abierta,
   sin cuenta ni clave, con la licencia de cada foto publicada.
4. **Otros servicios (Open Library, buscadores de imágenes).** Más cobertura, licencias peores o desconocidas.

## Decisión

Se adopta la alternativa 3.

| Destino | Qué se envía | Cuándo | Consentimiento |
|---|---|---|---|
| `www.wikidata.org`, `commons.wikimedia.org`, `upload.wikimedia.org`, `thumb.wikimedia.org` | El nombre de cada autor de la biblioteca, una vez, y la descarga de su foto a 400 px | Al encender el ajuste y en cada conexión con el PC, solo por los autores que aún no tienen foto | El ajuste "Fotos de autores" de Configuración, **apagado de fábrica** |

* El cliente vive en `lib/core/network/wikimedia.dart` y rechaza cualquier otro anfitrión, aunque la respuesta lo
  señale. El agente identifica la app como pide Wikimedia, sin datos del teléfono ni de la persona.
* Solo se acepta una persona (Wikidata `P31 = Q5`) con un oficio de escritura (`P106`), para no poner la foto de un
  homónimo.
* Las fotos y su índice se guardan en la carpeta privada de la app (`autores/`), nunca se envían al PC, y se
  borran al apagar el ajuste.
* Cada foto enseña su autoría y su licencia, tal como las publica Commons. Las fotos no se distribuyen con la app:
  se descargan en el teléfono de quien las pide, así que no cambian la licencia Apache 2.0 del código.
* Un autor sin foto se vuelve a buscar pasados 30 días; si falla la red, la búsqueda se detiene y sigue en la
  siguiente conexión.

## Consecuencias

* Con el ajuste encendido, Wikimedia sabe qué nombres de autor busca esta dirección IP. El texto del ajuste lo dice.
* Con el ajuste apagado no cambia nada respecto a ADR-004.
* Lo comprueban `test/features/library/fotos_de_autores_test.dart` y el guardián de red.
