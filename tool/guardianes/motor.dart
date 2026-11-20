import 'dart:io';

import 'package:crypto/crypto.dart';

import 'comun.dart';

// Un solo motor de lectura (ADR-008). Este guardián comprueba tres cosas:
//
// 1. Que `native/vendor/nb-books-lector/` es exactamente la exportación de
//    NB Books: cada archivo coincide con la huella de su `MANIFIESTO`, y no
//    sobra ni falta ninguno. El motor no se edita aquí; se vuelve a exportar.
// 2. Que nada fuera de `lib/core/motor/` habla con el puente generado: el
//    resto de la app usa `Motor`, que no recalcula nada.
// 3. Que el paquete de Dart y el crate de Rust del puente son la misma
//    versión: con dos distintas el puente no arranca.
const String _vendor = 'native/vendor/nb-books-lector';

void main() {
  final Informe inf = Informe('motor');

  final File manifiesto = File('$_vendor/MANIFIESTO');
  final Map<String, String> esperadas = <String, String>{};
  for (final String l in manifiesto.readAsLinesSync()) {
    final RegExpMatch? m = RegExp(r'^([0-9a-f]{64})  (.+)$').firstMatch(l);
    if (m != null) {
      esperadas[m.group(2)!] = m.group(1)!;
    }
  }
  final Set<String> vistas = <String>{};
  for (final FileSystemEntity e in Directory(
    _vendor,
  ).listSync(recursive: true)) {
    if (e is! File || e.path.endsWith('/MANIFIESTO')) {
      continue;
    }
    final String rel = e.path.substring(_vendor.length + 1);
    vistas.add(rel);
    final String? h = esperadas[rel];
    if (h == null) {
      inf.fallo(e.path, 'archivo que no está en la exportación');
    } else if (sha256.convert(e.readAsBytesSync()).toString() != h) {
      inf.fallo(e.path, 'no coincide con la exportación de NB Books');
    }
  }
  for (final String rel in esperadas.keys) {
    if (!vistas.contains(rel)) {
      inf.fallo('$_vendor/$rel', 'falta un archivo de la exportación');
    }
  }

  for (final File f in archivos(<String>['lib/'], <String>['.dart'])) {
    if (f.path.startsWith('lib/core/motor/')) {
      continue;
    }
    final List<String> lineas = f.readAsLinesSync();
    for (int i = 0; i < lineas.length; i++) {
      if (lineas[i].contains('motor/puente/') ||
          lineas[i].contains('flutter_rust_bridge')) {
        inf.fallo(
          '${f.path}:${i + 1}',
          'llama al puente fuera de lib/core/motor/',
        );
      }
    }
  }

  final RegExpMatch? dart = RegExp(
    r'^  flutter_rust_bridge: (\S+)$',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync());
  final RegExpMatch? rust = RegExp(
    r'^flutter_rust_bridge = "=(\S+)"$',
    multiLine: true,
  ).firstMatch(File('native/Cargo.toml').readAsStringSync());
  if (dart == null || rust == null || dart.group(1) != rust.group(1)) {
    inf.fallo(
      'pubspec.yaml',
      'flutter_rust_bridge de Dart (${dart?.group(1)}) y de Rust '
          '(${rust?.group(1)}) tienen que ser la misma versión fijada',
    );
  }
  exit(inf.cerrar());
}
