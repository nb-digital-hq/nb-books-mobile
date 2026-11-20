# ADR-007: Plataformas y distribución

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

La app se verifica en Android en un dispositivo real. iOS comparte el código Flutter y el motor de Rust, pero ni se
puede firmar ni probar sin equipos de Apple. NB Digital no publica sus apps móviles en tiendas.

## Decisión

| Plataforma | Estado | Entrega |
|---|---|---|
| Android 7.0 o posterior (`arm64-v8a`, `armeabi-v7a`, `x86_64` y universal) | Verificada en dispositivo real | APK firmados con la clave de NB Books Mobile |
| iOS 13 o posterior | **Sin probar** en dispositivo real; compila en la CI | `.ipa` **sin firmar**, para instalar con una firma propia |

* La única vía de distribución son las publicaciones de `github.com/nb-digital-hq/nb-books-mobile`, con
  `SHA256SUMS` firmado con Ed25519.
* En Android la app se actualiza desde Acerca de, a petición de la persona.
* En iOS no existen las teclas de volumen en Leer en el PC ni el actualizador: dependen de servicios de Android y
  sus entradas no se muestran.

## Consecuencias

* La CI compila iOS en macOS en cada cambio, para que la edición sin probar no se rompa en silencio
  ([CI](../developer/ci-cd.md)).
* Cada ABI lleva su motor de Rust y su PDFium; el APK universal los lleva todos.
