import 'dart:io';

import 'comun.dart';

// La app no escribe registros: ni en Dart ni en el código nativo. Un registro
// acabaría llevando títulos, rutas o direcciones del PC al logcat, que otras
// apps con permisos de depuración pueden leer.
void main() {
  final Informe inf = Informe('registro');
  for (final File f in archivos(<String>['lib/'], <String>['.dart'])) {
    final List<String> lineas = f.readAsLinesSync();
    for (int i = 0; i < lineas.length; i++) {
      final String l = lineas[i];
      if (l.trimLeft().startsWith('//')) {
        continue;
      }
      if (RegExp(
        r'(?<![\w.])(print|debugPrint|log)\s*\(|\bdeveloper\.log\(',
      ).hasMatch(l)) {
        inf.fallo('${f.path}:${i + 1}', 'escritura de registro');
      }
      // Inspeccionar la página del lector desde un ordenador la deja leer
      // entera: solo en depuración, nunca en lo que se publica.
      if (l.contains('enableDebugging(true)') &&
          (i == 0 || !lineas[i - 1].contains('kDebugMode'))) {
        inf.fallo(
          '${f.path}:${i + 1}',
          'inspección de la vista web fuera de kDebugMode',
        );
      }
    }
  }
  for (final File f in archivos(
    <String>['android/app/src/'],
    <String>['.kt', '.java'],
  )) {
    final List<String> lineas = f.readAsLinesSync();
    for (int i = 0; i < lineas.length; i++) {
      if (RegExp(
        r'\bLog\.[vdiwe]\(|printStackTrace\(|println\(',
      ).hasMatch(lineas[i])) {
        inf.fallo('${f.path}:${i + 1}', 'escritura de registro nativa');
      }
    }
  }
  // El puente del motor tampoco escribe nada. El motor sellado en `vendor/`
  // lo vigila su propio guardián en NB Books, y aquí no se edita.
  for (final File f in archivos(<String>['native/src/'], <String>['.rs'])) {
    final List<String> lineas = f.readAsLinesSync();
    for (int i = 0; i < lineas.length; i++) {
      if (RegExp(r'\b(e?println|dbg)!\(').hasMatch(lineas[i])) {
        inf.fallo('${f.path}:${i + 1}', 'escritura de registro en Rust');
      }
    }
  }
  exit(inf.cerrar());
}
