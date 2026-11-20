# ADR-004: Una sola puerta de red

> **Estado:** Aceptado. [ADR-012](012-author-photos.md) añade un tercer destino opcional.

**Fecha:** 2026-11-19

## Contexto

La app habla con el PC emparejado y, para actualizarse en Android, con la API de publicaciones de GitHub. Si cada
módulo construyera su propio cliente HTTP, nadie podría asegurar qué sale del teléfono.

## Alternativas consideradas

1. **Clientes libres por módulo**, revisados a mano. Se degrada con cada cambio.
2. **Un único módulo de salidas** comprobado por un guardián.

## Decisión

* Todo cliente HTTP, WebSocket, imagen o audio remotos se construye en `lib/core/network/`.
  `tool/guardianes/red.dart` rechaza cualquier construcción fuera de esa carpeta, cualquier conexión en el código
  nativo de Android y cualquier crate de red en el motor de Rust (`native/`): el motor lee archivos, no abre
  conexiones.
* Hay dos destinos y los dos los pide la persona:

| Destino | Cuándo | Consentimiento |
|---|---|---|
| El PC emparejado | Sincronizar, descargar, leer sin descargar, buscar en la biblioteca, pedir estudio, Leer en el PC | Escanear su QR o escribir su código |
| `api.github.com` y las descargas de la publicación | Al pulsar "Buscar actualizaciones" (Android) | El propio botón |

* El certificado del PC se fija por su huella SHA-256 al emparejar y se comprueba en cada conexión.

## Consecuencias

* No hay telemetría, analítica ni informes de fallos, ni forma de añadirlos sin que el guardián falle.
* Ver [privacidad](../audit/privacy.md) y [modelo de amenazas](../audit/threat-model.md).
