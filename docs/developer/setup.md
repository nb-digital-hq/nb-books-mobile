# Puesta en marcha

> **Estado:** Aplicable.

## Herramientas

* Flutter estable 3.47 (Dart 3.11), Android SDK 36, NDK 28 y JDK 17 o posterior.
* Rust 1.98 con los objetivos `aarch64-linux-android`, `armv7-linux-androideabi` y `x86_64-linux-android`, y
  `cargo-ndk` 4.1.
* `flutter_rust_bridge_codegen` 2.13, solo para rehacer el puente (`just puente`).
* `just` para los atajos (opcional: cada receta es un comando de Flutter, Dart o Cargo).
* Para iOS: macOS con Xcode y el objetivo `aarch64-apple-ios`.

## Primeros comandos

```bash
just setup     # dependencias, motor y PDFium por ABI, código generado
just demo      # biblioteca inventada, sin PC
just verify    # la definición de terminado
```

`ANDROID_NDK_HOME` debe apuntar al NDK para que `cargo-ndk` compile el motor.

## Sin PC: la edición de demostración

```bash
flutter run --dart-define=NB_SEED=true
```

Genera en el dispositivo tres libros inventados (EPUB) con su ficha, y solo actúa sobre una base vacía. Es la
edición de las capturas y del video.

## Probar contra un NB Books real

NB Books en el PC, Ajustes, Teléfonos, "Permitir teléfonos" y "Emparejar un teléfono". El teléfono y el PC en la
misma red.
