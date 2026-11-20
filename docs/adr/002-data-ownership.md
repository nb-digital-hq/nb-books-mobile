# ADR-002: Cada dato tiene un dueño y viaja en un solo sentido

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

NB Books en el PC cataloga la biblioteca y guarda lo que la persona hace al leer. En el teléfono la persona también
lee, anota, repasa y escribe. Si los dos lados pudieran sobrescribir el mismo valor, haría falta resolver
conflictos, y toda resolución automática acaba perdiendo, alguna vez, trabajo de la persona.

## Alternativas consideradas

1. **El teléfono como catálogo independiente.** Duplicaría la catalogación y divergiría del PC.
2. **Sincronización bidireccional con "gana el más reciente".** Depende de relojes y pierde en silencio la versión
   que no gana.
3. **Un dueño por tipo de dato**: lo que se comparte son hechos que se suman, nunca valores que se pisan.

## Decisión

Alternativa 3:

| Dato | Dueño | Sentido | Por qué no hay conflicto |
|---|---|---|---|
| Catálogo, estanterías, colecciones, portadas y archivos | PC | PC → teléfono | El teléfono no los edita |
| Selección del teléfono | Teléfono | Teléfono → PC | El PC solo la obedece |
| Posición de lectura | Cada dispositivo la suya | Las dos viajan | Se guarda una posición por dispositivo; al abrir, si el otro va más adelante, se ofrece saltar |
| Anotaciones, marcadores y trazos | Quien los crea (los trazos, solo el PC) | Altas y bajas en los dos sentidos | Son inmutables: editar es dar de baja y crear otra, y una baja no se revive |
| Sesiones de lectura y vocabulario | Quien las crea | En los dos sentidos | Son registros que se añaden |
| Repaso espaciado | Nadie: el estado se deriva | Viaja el registro de repasos | Cada lado recalcula SM-2 con el registro completo y obtiene el mismo resultado |
| Tarjetas y resúmenes generados | PC | PC → teléfono | Los genera el PC |
| Notas enlazadas | PC | El teléfono crea y propone cambios | El cambio lleva la revisión que vio el teléfono; si la nota cambió en el PC, entra como nota nueva y se avisa |
| Libros del teléfono, su dato y las preferencias | Teléfono | No salen | |

La sincronización viaja solo por la red local, con el PC emparejado; no hay nube ni cuenta.

## Consecuencias

* Los registros que se suman llevan identificadores aleatorios de 128 bits, los mismos que usa NB Books, y su
  aplicación es idempotente: recibir dos veces lo mismo no cambia nada.
* Lo que el PC borra del catálogo desaparece del teléfono con su lápida, salvo lo descargado, que se conserva hasta
  que la persona lo quite.
* Las pruebas de `test/features/sync/` comprueban que ninguna operación pisa un valor del otro lado y que dos
  dispositivos desconectados con relojes desfasados no pierden nada.
* Ver el [contrato con el PC](../architecture/pc-contract.md).
