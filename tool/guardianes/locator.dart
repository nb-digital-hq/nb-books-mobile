import 'dart:io';

import 'comun.dart';

// Ninguna posición es un entero: siempre un Locator, y siempre el que calcula
// el motor de NB Books (AGENTS.md, regla 3). Este guardián comprueba dos cosas:
//
// 1. Que toda columna de posición del esquema lleva su comprobación de
//    Locator, así que la base rechaza lo que no lo es.
// 2. Que el motor del teléfono responde lo grabado en el corpus de conformidad
//    de NB Books: los mismos Locators, resoluciones y fragmentos.
void main() {
  final Informe inf = Informe('locator');

  final String tablas = File('lib/data/db/tables.dart').readAsStringSync();
  for (final RegExpMatch m in RegExp(
    r'TextColumn get (locator)\b',
  ).allMatches(tablas)) {
    final int inicio = tablas.lastIndexOf('class ', m.start);
    final int fin = tablas.indexOf('\nclass ', m.end);
    final String clase = tablas.substring(
      inicio,
      fin < 0 ? tablas.length : fin,
    );
    final String nombre = RegExp(r'class (\w+)').firstMatch(clase)!.group(1)!;
    if (!clase.contains("_locator('${m.group(1)}')")) {
      inf.fallo(
        'lib/data/db/tables.dart',
        '$nombre.${m.group(1)} sin comprobación de Locator',
      );
    }
  }

  final ProcessResult r = Process.runSync('cargo', <String>[
    'test',
    '--manifest-path',
    'native/Cargo.toml',
    '--test',
    'conformidad',
    '--quiet',
  ]);
  if (r.exitCode != 0) {
    inf.fallo(
      'native/tests/conformidad.rs',
      'el motor no responde lo grabado en el corpus de conformidad\n${r.stdout}${r.stderr}',
    );
  }
  exit(inf.cerrar());
}
