# Privacidad

> **Estado:** Implementado. Versión para la comunidad: [PRIVACY.md](../../PRIVACY.md).

## Qué sale del teléfono

| Destino | Qué se envía | Cuándo |
|---|---|---|
| El PC emparejado | Nombre y plataforma del teléfono al emparejar; la selección; anotaciones, posiciones, sesiones, repasos y notas de los libros del PC; peticiones de catálogo, archivos, portadas, búsqueda y órdenes de Leer en el PC | Al emparejar, sincronizar, descargar, buscar o usar el mando |
| `api.github.com` y `github.com` | Una petición anónima por la última publicación y la descarga del APK | Solo al pulsar "Buscar actualizaciones" o "Instalar" (Android) |
| Wikidata y Wikimedia Commons | El nombre de cada autor de la biblioteca, una vez, y la descarga de su foto | Solo con "Fotos de autores" encendido en Configuración (apagado de fábrica); ver [ADR-012](../adr/012-author-photos.md) |

Nada más. No hay telemetría, analítica, informes de fallos ni identificadores publicitarios, y la app no escribe
registros. El motor de lectura no abre conexiones, y la página del lector bloquea cualquier carga o navegación
externa: un libro no puede llamar a la red.

## Qué no sale nunca

* Los libros añadidos desde el teléfono, y lo anotado o leído en ellos.
* Las preferencias (tema, idioma, ajustes de lectura).
* El nombre y la foto del perfil, y las estadísticas de lectura que se calculan con ellos.
* Las búsquedas recientes.

## Qué se guarda en el teléfono

Fichas y portadas de lo elegido, las fotos de autores si se pidieron, archivos descargados, la caché de leer sin descargar, anotaciones, posiciones,
sesiones, vocabulario, tarjetas, repasos, notas y preferencias, en la carpeta privada de la app. El `device_token`,
la huella del certificado y la dirección del PC, en el llavero del sistema. Desinstalar la app lo borra todo.

## Permisos

| Permiso | Para qué |
|---|---|
| Red y estado de la red | Hablar con el PC y, a petición, con GitHub y Wikimedia |
| Multidifusión Wi-Fi | Encontrar el PC por mDNS |
| Cámara | Escanear el QR, solo mientras la pantalla de emparejar está abierta |
| Instalar paquetes | Instalar la actualización que la persona pidió (Android) |
