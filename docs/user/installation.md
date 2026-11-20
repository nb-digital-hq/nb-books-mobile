# Instalación

> **Estado:** Implementado en Android. iOS se publica sin probar en un dispositivo real.

## Android

1. En la página de publicaciones de `github.com/nb-digital-hq/nb-books-mobile`, descarga el APK de tu teléfono:

| Teléfono | Paquete |
|---|---|
| La mayoría de teléfonos (64 bits) | `NB-Books-Mobile-<versión>-arm64-v8a.apk` |
| Teléfonos antiguos de 32 bits | `NB-Books-Mobile-<versión>-armeabi-v7a.apk` |
| Emuladores y Chromebook con Intel o AMD | `NB-Books-Mobile-<versión>-x86_64.apk` |
| Si no sabes cuál | `NB-Books-Mobile-<versión>-universal.apk` |

2. Ábrelo y permite instalar aplicaciones de esa fuente cuando Android lo pida.
3. Si quieres comprobar la descarga, compárala con `SHA256SUMS` y su firma
   ([cadena de suministro](../audit/supply-chain.md)).

Hace falta Android 7.0 o posterior y NB Books 1.0 o posterior en el PC, en la misma red.

## Actualizar

Acerca de, "Buscar actualizaciones": la app consulta la última publicación, descarga el APK de tu teléfono,
comprueba su tamaño y su huella y lo entrega al instalador del sistema. Tu biblioteca, tus anotaciones y tus
descargas se conservan.

## iOS

El `.ipa` se publica sin firma de Apple y sin haberse probado en un iPhone. Para instalarlo hay que firmarlo con un
perfil propio. En iOS no hay actualizador, ni teclas de volumen en Leer en el PC, ni PDF.
