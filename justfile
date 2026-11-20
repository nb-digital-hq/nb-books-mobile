# Atajos del proyecto. Cada receta es un comando de Flutter, Dart o Cargo, para
# que la CI y la verificación local ejecuten exactamente lo mismo.

# Dependencias, el motor de lectura para cada ABI de Android con su PDFium y el
# código generado de Drift.
setup:
    flutter pub get
    dart run tool/motor.dart
    dart run build_runner build --delete-conflicting-outputs

# Regenera el puente con Rust tras cambiar `native/src/api.rs`. El puente se
# versiona: la CI no necesita el generador.
puente:
    flutter_rust_bridge_codegen generate

run:
    flutter run

demo:
    flutter run --dart-define=NB_SEED=true

test:
    flutter test
    cargo test --manifest-path native/Cargo.toml

guardianes:
    dart run tool/guardianes/todos.dart

verify:
    flutter pub get
    dart run build_runner build --delete-conflicting-outputs
    dart format --output=none --set-exit-if-changed lib test tool
    flutter analyze
    flutter test
    cargo fmt --manifest-path native/Cargo.toml --all -- --check
    cargo clippy --manifest-path native/Cargo.toml --all-targets -- -D warnings
    cargo test --manifest-path native/Cargo.toml
    dart run tool/guardianes/todos.dart

apk:
    dart run tool/motor.dart
    flutter build apk --release --split-per-abi
    flutter build apk --release
