# Empaquetado

> **Estado:** Implementado.

## Android

| Campo | Valor |
|---|---|
| `applicationId` | `com.nbbooks.nb_books_mobile` |
| Versión | `version` de `pubspec.yaml`; con `--split-per-abi` el `versionCode` es 1000 × índice de la ABI + build |
| SDK mínimo / objetivo | 24 (Android 7.0) / 36 |
| Reducción | R8 activo; reglas en `android/app/proguard-rules.pro` |

```bash
dart run tool/motor.dart                      # motor y PDFium en jniLibs/, por ABI
flutter build apk --release --split-per-abi   # arm64-v8a, armeabi-v7a, x86_64
flutter build apk --release                   # universal
```

### Firma

La publicación se firma con la clave de NB Books Mobile (`android/key.properties` apunta al almacén
`android/nb-books-release.jks`). Ninguno de los dos se versiona. Sin `key.properties`, Gradle firma con la clave de
depuración para no bloquear el desarrollo; ese APK no actualiza una instalación de publicación. La clave se custodia
fuera del repositorio con copia cifrada: perderla impide publicar actualizaciones con la misma identidad.

### Lo que lleva el APK

El motor (`libnb_books_motor.so`) y PDFium (`libpdfium.so`) por ABI, las fuentes y el logotipo. Ningún libro: la
edición de demostración genera los suyos en el dispositivo.

## iOS

```bash
cargo build --release --target aarch64-apple-ios --manifest-path native/Cargo.toml
flutter build ios --release --no-codesign
```

`ios/Flutter/Release.xcconfig` enlaza el motor estático. `ediciones.yml` empaqueta el resultado como `.ipa` sin
firmar. Sin probar en un dispositivo real, y sin PDFium.

## Íconos

Todos salen de [`NB_Books.svg`](../assets/branding/README.md): el lanzador de cada densidad, el adaptativo (silueta
sobre el color del disco, `#FEB61A`), el monocromo y el logotipo de Acerca de, trazados con `rsvg-convert`.
