# Publicación

> **Estado:** Implementado. Lista de quien publica una versión.

## Versionado

Versionado semántico. La versión se cambia a la vez en `pubspec.yaml` (con el `+build` incrementado),
`lib/core/plataforma.dart`, `CHANGELOG.md` y `CITATION.cff`; `tool/guardianes/version.dart` comprueba que
coincidan, con la misma fecha.

## Lista

1. `just verify` en verde, y la CI de `main` en verde.
2. Si el motor cambió en NB Books: `tool/exportar_motor.sh` y el corpus de conformidad en verde en los dos repositorios.
3. APK de publicación firmados en local: por ABI y universal ([empaquetado](packaging.md)).
4. Prueba en un dispositivo real instalando encima de la versión anterior, contra un NB Books real: la biblioteca, las
   anotaciones y las descargas sobreviven.
5. Ejecutar `ediciones.yml` y descargar el `.ipa` sin firmar.
6. Montar la carpeta de la publicación:

| Archivo | Qué es |
|---|---|
| `NB-Books-Mobile-<v>-arm64-v8a.apk`, `-armeabi-v7a.apk`, `-x86_64.apk` | APK por arquitectura (los que usa el actualizador) |
| `NB-Books-Mobile-<v>-universal.apk` | APK para cualquier arquitectura |
| `NB-Books-Mobile-<v>-ios-unsigned.ipa` | iOS, sin probar |
| `THIRD-PARTY-NOTICES.md` | Avisos de terceros |
| `SHA256SUMS`, `SHA256SUMS.sig` | Huellas y su firma Ed25519 |

7. Firmar la lista:

```bash
sha256sum NB-Books-Mobile-* THIRD-PARTY-NOTICES.md > SHA256SUMS
openssl pkeyutl -sign -inkey <clave-privada> -rawin -in SHA256SUMS -out SHA256SUMS.sig
openssl pkeyutl -verify -pubin -inkey docs/architecture/api/clave-de-publicacion.pem \
  -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig
```

8. Crear la publicación `v<versión>` con esos archivos; las notas salen de `CHANGELOG.md` y dicen qué está
   verificado y qué no.

## Actualización en Android

Acerca de, "Buscar actualizaciones" consulta la última publicación, elige el APK de la ABI del dispositivo (el
universal solo si no hay por ABI), comprueba tamaño y SHA-256 y lo entrega al instalador del sistema.

## Soporte

Recibe correcciones la última versión publicada.
