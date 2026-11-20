import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/data/db/database.dart';
import 'package:nb_books_mobile/features/sync/data/sync_repository.dart';

import '../../support/pc_falso.dart';

void main() {
  test('lo anotado en un libro del teléfono nunca llega al PC', () async {
    final AppDatabase db = AppDatabase(NativeDatabase.memory());
    final PcFalso pc = PcFalso();
    final Directory dir = Directory.systemTemp.createTempSync('nb-local');
    final SyncRepository repo = SyncRepository(
      db: db,
      dioFor: (_) => pc.dio(),
      carpetaDeLibros: dir,
      carpetaDePortadas: dir,
    );
    for (final (String id, String origen) in <(String, String)>[
      ('propio', 'telefono'),
      ('del-pc', 'pc'),
    ]) {
      await db
          .into(db.ediciones)
          .insert(
            EdicionesCompanion.insert(
              id: id,
              titulo: id,
              tipo: 'application/epub+zip',
              anadidaEn: '2026-01-01T00:00:00Z',
              origen: Value<String>(origen),
            ),
          );
      await db
          .into(db.anotaciones)
          .insert(
            AnotacionesCompanion.insert(
              id: 'a-$id',
              edicion: id,
              tipo: 'highlight',
              locator: '{"href":"c1.xhtml"}',
              creadaEn: '2026-01-01T00:00:00Z',
              pendiente: const Value<bool>(true),
            ),
          );
    }
    pc.manifiesto = <String, dynamic>{
      'cambios': <dynamic>[],
      'hay_mas': false,
      'siguiente': 0,
      'version_actual': 0,
    };
    await repo.sync(PcFalso.pc);

    final List<dynamic> subidas =
        pc.envios.single['anotaciones'] as List<dynamic>;
    expect(
      subidas.map((dynamic a) => (a as Map<String, dynamic>)['edicion']),
      <String>['del-pc'],
    );
    await db.close();
    dir.deleteSync(recursive: true);
  });
}
