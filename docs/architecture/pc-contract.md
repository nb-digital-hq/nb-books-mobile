# Contrato con el PC

> **Estado:** Implementado. Protocolo `1`. El documento dueño del contrato está en NB Books:
> `docs/architecture/mobile-contract.md`.

Este documento describe el contrato desde el lado del teléfono: qué pide la app, cuándo y qué hace con la
respuesta. Las respuestas grabadas por NB Books viven en `test/fixtures/contrato-pc/` y las pruebas de
`test/features/sync/` las aplican. Si NB Books cambia una respuesta, regraba las suyas y el mismo cambio se copia
aquí en el mismo trabajo.

## 1. Encontrar el PC

| Aspecto | Valor |
|---|---|
| Descubrimiento | mDNS `_nbbooks._tcp.local.`; si no responde, la última dirección conocida |
| Cambio de puerto o dirección | Si una petición en directo falla por la red (no por una respuesta del PC), `SyncController.conPc` busca el PC de nuevo por mDNS, guarda la dirección nueva y reintenta una vez |
| Puertos | `8831` a `8899` |
| Transporte | HTTPS y WSS con el certificado fijado por su huella SHA-256 |
| Autenticación | `Authorization: Bearer <device_token>`, guardado en el llavero del sistema |

## 2. Emparejar

El QR del PC lleva `host`, `puerto`, `token`, `version`, `tls`, `tls_fingerprint` y `servicio`. Sin cámara, se
escribe la dirección y el código de 8 caracteres. La app canjea el token con `POST /api/v1/pair` y guarda en el
llavero el `device_token`, la huella y la dirección. Un `401` posterior significa que el PC revocó el teléfono: la
app lo dice en Inicio y ofrece emparejar de nuevo, sin borrar nada.

## 3. Qué pide la app

| Petición | Cuándo |
|---|---|
| `GET /api/v1/ping` | Al buscar el PC |
| `GET /api/v1/seleccion`, `POST /api/v1/seleccion` | Al abrir y guardar "Elegir libros"; si la respuesta trae `reiniciar`, el manifiesto se pide desde `0` |
| `GET /api/v1/estanterias` | Pestañas de colecciones, autores, series y materias de "Elegir libros" |
| `GET /api/v1/manifest?since=N&limit=500` | Cada sincronización, por páginas hasta `hay_mas = false` |
| `GET /api/v1/catalogo` | La vista "Todo el PC" de Biblioteca, paginada y sin copiarla |
| `GET /api/v1/buscar` | "Dentro de los libros" en Buscar |
| `GET /api/v1/archivo/{huella}` | Descargar o leer sin descargar, con `Range` para reanudar |
| `GET /api/v1/portada/{edicion}` | Portadas que faltan de lo elegido |
| `POST /api/v1/cambios` | Cada sincronización, en tandas de 300 por lista |
| `GET /api/v1/control` | Leer en el PC |

## 4. Cómo se aplica el manifiesto

Todo se aplica en una transacción por página y la versión alcanzada se guarda con ella: una sincronización cortada
continúa donde quedó.

| Entidad | Efecto en el teléfono |
|---|---|
| `edicion` | Se inserta o actualiza. Un archivo descargado sigue valiendo solo si su huella no cambió; si cambió, se borra |
| `coleccion` | Se sustituye entera |
| `anotacion`, `sesion`, `vocabulario`, `repaso` | Se suman por `id`; una baja del PC marca `baja_en` |
| `progreso` | Posición del dispositivo `pc`; la del teléfono no se toca |
| `tarjeta` | Se guarda y su estado se recalcula con SM-2 desde el registro de repasos |
| `nota` | Se guarda con su `revision` |
| Lápida de `edicion` | Se olvida la edición y su archivo; lo anotado en ella se conserva |

## 5. Qué sube la app

Anotaciones, posiciones del teléfono, sesiones, vocabulario, repasos y notas marcadas como pendientes. Lo que pertenece
a un libro con `origen = telefono` se filtra antes de construir el envío. Lo que el PC confirma deja de estar
pendiente; lo rechazado sigue pendiente. Si una nota cambió en el PC mientras se editaba, el PC la guarda como copia
(`notas_copiadas`) y la del teléfono se sustituye por las dos que llegan con el manifiesto.

## 6. Leer en el PC

La app abre `wss://<pc>/api/v1/control`, muestra el `estado` que envía el PC (título, capítulo, porcentaje, la frase
de su Locator, el estado de la voz y del fondo sonoro, el modo y la inmersión) y envía órdenes: comandos del lector
(`pagina-siguiente`, `capitulo-anterior`, `marcador`, `voz`, `fondo-sonoro`, `modo-de-lectura`, `letra-mayor`, `letra-menor`, `acercar`, `alejar`,
`inmersion`, `pantalla-completa`), `abrir`, `irA`, `irAlLocator`, `desplazar` y `avance`. "Seguir en el PC" manda
`abrir` y, cuando el estado ya dice que el libro está abierto, `irAlLocator` con la posición del teléfono; "Seguir
aquí" abre el lector del teléfono en el Locator del estado. El detalle de cada orden es el del documento dueño ([ADR-010](../adr/010-read-on-pc.md)).
