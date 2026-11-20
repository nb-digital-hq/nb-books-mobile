import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';

import '../../core/motor/motor.dart';
import '../../data/db/database.dart';

/// Los tipos que el teléfono sabe abrir, por extensión.
const Map<String, String> kTiposPorExtension = <String, String>{
  'epub': 'application/epub+zip',
  'pdf': 'application/pdf',
  'cbz': 'application/vnd.comicbook+zip',
};

/// Añade al teléfono libros elegidos por la persona. Se copian a la carpeta de
/// la app (el archivo original no se toca) y quedan con `origen = telefono`:
/// nunca suben al PC, ni ellos ni lo que se anote en ellos.
///
/// Devuelve cuántos entraron. Un libro que ya estaba (misma huella) no se
/// duplica.
Future<int> anadirLibrosDelTelefono(AppDatabase db, Directory docs) async {
  final List<PlatformFile> elegidos = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: kTiposPorExtension.keys.toList(),
  );
  if (elegidos.isEmpty) {
    return 0;
  }
  final Directory destino = Directory('${docs.path}/telefono')
    ..createSync(recursive: true);
  int entraron = 0;
  for (final PlatformFile f in elegidos) {
    final String? ruta = f.path;
    final String ext = (f.extension ?? '').toLowerCase();
    final String? tipo = kTiposPorExtension[ext];
    if (ruta == null || tipo == null) {
      continue;
    }
    final String huella = await Motor.huella(ruta);
    final String id = 'telefono-${huella.split(':').last.substring(0, 32)}';
    if (await db.edicion(id) != null) {
      continue;
    }
    final File copia = File(
      '${destino.path}/${huella.replaceAll(':', '_')}.$ext',
    );
    await File(ruta).copy(copia.path);
    Map<String, dynamic> m = const <String, dynamic>{};
    try {
      m = await Motor.metadatos(copia.path, tipo);
    } on MotorException {
      // Sin metadatos legibles, el nombre del archivo hace de título.
    }
    final String titulo = (m['titulo'] as String?)?.trim().isNotEmpty == true
        ? m['titulo'] as String
        : f.name.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' ');
    await db
        .into(db.ediciones)
        .insert(
          EdicionesCompanion.insert(
            id: id,
            titulo: titulo,
            autores: Value<String>(jsonEncode(m['autores'] ?? <String>[])),
            idioma: Value<String?>(m['idioma'] as String?),
            editorial: Value<String?>(m['editorial'] as String?),
            fecha: Value<String?>(m['fecha'] as String?),
            serie: Value<String?>(m['serie'] as String?),
            sinopsis: Value<String?>(m['sinopsis'] as String?),
            huella: Value<String?>(huella),
            bytes: Value<int>(copia.lengthSync()),
            tipo: tipo,
            origen: const Value<String>('telefono'),
            ruta: Value<String?>(copia.path),
            anadidaEn: ahoraIso(),
          ),
        );
    entraron++;
  }
  return entraron;
}

/// Quita un libro del teléfono: el archivo copiado y todo lo que cuelga de él.
Future<void> quitarLibroDelTelefono(AppDatabase db, Edicion e) async {
  if (e.origen != 'telefono') {
    return;
  }
  for (final String? r in <String?>[e.ruta, e.rutaPortada]) {
    if (r != null) {
      try {
        File(r).deleteSync();
      } catch (_) {
        // Ya no estaba.
      }
    }
  }
  await db.transaction(() async {
    await (db.delete(
      db.anotaciones,
    )..where(($AnotacionesTable a) => a.edicion.equals(e.id))).go();
    await (db.delete(
      db.posiciones,
    )..where(($PosicionesTable p) => p.edicion.equals(e.id))).go();
    await (db.delete(
      db.sesiones,
    )..where(($SesionesTable s) => s.edicion.equals(e.id))).go();
    await (db.delete(
      db.ediciones,
    )..where(($EdicionesTable x) => x.id.equals(e.id))).go();
  });
}
