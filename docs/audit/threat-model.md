# Modelo de amenazas

> **Estado:** Aplicable.

| Amenaza | Mitigación |
|---|---|
| Un equipo de la red local se hace pasar por el PC | El certificado se fija por su huella SHA-256 al emparejar (el QR la trae) y se comprueba en cada conexión HTTPS y WSS |
| Alguien en la red reutiliza un QR o un código | El token es de un solo uso y caduca a los cinco minutos |
| Robo del `device_token` | Vive en el llavero del sistema; el PC solo guarda su SHA-256 y puede revocar el teléfono |
| Un libro malicioso (bomba ZIP, rutas fuera del archivo, guiones) | El motor de NB Books limita tamaños y entradas, sanea el marcado por lista de permitidos y quita los guiones; la página del lector tiene una política de contenido sin red y bloquea la navegación |
| Un archivo cambiado en tránsito | Una descarga solo se acepta si su SHA-256 coincide con la huella del PC |
| Una actualización manipulada | Solo se instala si el tamaño y la huella coinciden con los que publica GitHub; Android exige además la misma firma que la app instalada |
| Fuga por registros | No hay registros (`tool/guardianes/registro.dart`) |
| Una dependencia que abre conexiones propias | Toda red está en `lib/core/network/`, y el motor no puede depender de crates de red (`tool/guardianes/red.dart`) |
| Libros del teléfono enviados al PC | Se filtran antes de construir el envío (`test/features/local_books/`) |
| Pérdida de datos en una actualización | Esquema con migraciones que no se editan una vez publicadas |

Fuera de alcance: un dispositivo con acceso de superusuario y un PC comprometido, que por diseño ya tiene los libros.
