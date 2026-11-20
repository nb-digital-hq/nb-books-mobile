import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/data/db/database.dart';
import 'package:nb_books_mobile/features/sync/data/sync_repository.dart';

import '../../support/pc_falso.dart';

void main() {
  late AppDatabase db;
  late PcFalso pc;
  late SyncRepository repo;
  late Directory dir;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    pc = PcFalso();
    dir = Directory.systemTemp.createTempSync('nb-sync');
    repo = SyncRepository(
      db: db,
      dioFor: (_) => pc.dio(),
      carpetaDeLibros: Directory('${dir.path}/libros')..createSync(),
      carpetaDePortadas: Directory('${dir.path}/portadas')..createSync(),
    );
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'el manifiesto grabado por NB Books se aplica como edición del PC',
    () async {
      final ResultadoDeSync r = await repo.sync(PcFalso.pc);
      expect(r.recibidos, 1);
      final Edicion e = (await db.select(db.ediciones).get()).single;
      expect(e.titulo, 'libro');
      expect(e.origen, 'pc');
      expect(e.huella, startsWith('sha256:'));
    },
  );

  test('la selección grabada por NB Books se lee sin perder campos', () async {
    final Seleccion s = await repo.seleccion(PcFalso.pc);
    expect(s.toJson().keys, containsAll(PcFalso.grabada('seleccion').keys));
  });

  test('una lápida del PC quita la edición del teléfono', () async {
    await repo.sync(PcFalso.pc);
    pc.manifiesto = <String, dynamic>{
      'cambios': <Map<String, dynamic>>[
        <String, dynamic>{
          'entidad': 'edicion',
          'clave': '<id>',
          'borrado': true,
          'version': 1,
        },
      ],
      'hay_mas': false,
      'siguiente': 1,
      'version_actual': 1,
    };
    await repo.sync(PcFalso.pc);
    expect(await db.select(db.ediciones).get(), isEmpty);
  });
}
