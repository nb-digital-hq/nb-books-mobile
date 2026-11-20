# ADR-010: Leer en el PC

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

NB Sound Mobile permite reproducir en el PC y controlarlo desde el teléfono. En lectura, el teléfono puede servir
de mando del lector del escritorio: pasar página desde el sofá, presentar un texto en una pantalla o dejar que el PC
avance solo.

## Alternativas consideradas

1. **Un protocolo de control con su propia lógica de lectura en el PC.** Duplicaría lo que ya hace el lector.
2. **Espejo de la pantalla del PC en el teléfono.** Ancho de banda y batería para nada.
3. **El teléfono como un teclado más del lector del PC.**

## Decisión

* El teléfono manda y el PC obedece, en vivo; el PC nunca controla el teléfono.
* Cada orden del teléfono es un comando del registro de comandos del lector de NB Books y se ejecuta por el mismo
  camino que el teclado. Lo que el teclado puede, el mando puede.
* El teléfono puede: abrir y cerrar un libro en el PC; pasar página; ir a un capítulo, al índice, a una anotación o
  a cualquier punto de la barra de posición; desplazar en modo continuo como una superficie táctil; activar el
  avance automático y su velocidad; cambiar el modo de lectura, el tamaño de letra, la inmersión y la pantalla
  completa; controlar la lectura en voz alta y el fondo sonoro; poner un marcador; y pasar el libro de un
  dispositivo al otro en la frase exacta.
* En Android, las teclas de volumen pasan página mientras la pantalla de control está abierta. No hay notificación
  con botones: el mando es una pantalla, y fuera de ella el volumen vuelve a ser volumen.
* El teléfono muestra título, capítulo, porcentaje, la frase donde va el PC y el estado de la voz.
* No se selecciona, resalta ni escribe a distancia.
* Solo los teléfonos emparejados mandan; el PC enseña desde cuál se le controla y se puede cortar al momento; con dos
  teléfonos, manda la última orden.

## Consecuencias

* Las órdenes viajan por el WebSocket del [contrato](../architecture/pc-contract.md).
* NB Books añade las órdenes de abrir, cerrar, ir a una posición y avance automático a su registro, cada una con su
  atajo de teclado.
