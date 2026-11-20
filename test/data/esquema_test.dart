import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/data/db/database.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  AnotacionesCompanion anotacion(String locator) => AnotacionesCompanion.insert(
    id: 'a1',
    edicion: 'e1',
    tipo: 'highlight',
    locator: locator,
    creadaEn: '2026-01-01T00:00:00Z',
  );

  test('una anotación con un Locator se guarda', () async {
    await db
        .into(db.anotaciones)
        .insert(anotacion('{"href":"OEBPS/c1.xhtml","locations":{}}'));
    expect(await db.select(db.anotaciones).get(), hasLength(1));
  });

  test(
    'quitar una anotación se puede deshacer y viaja otra vez al PC',
    () async {
      await db
          .into(db.anotaciones)
          .insert(anotacion('{"href":"OEBPS/c1.xhtml","locations":{}}'));
      await db.darDeBaja('a1');
      expect(
        (await db.select(db.anotaciones).getSingle()).bajaEn != null,
        isTrue,
      );
      await db.recuperar('a1');
      final Anotacion a = await db.select(db.anotaciones).getSingle();
      expect(a.bajaEn == null, isTrue);
      expect(a.pendiente, isTrue);
    },
  );

  test('la base rechaza una posición que es un entero', () async {
    await expectLater(
      db.into(db.anotaciones).insert(anotacion('1234')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('la base rechaza un JSON sin href', () async {
    await expectLater(
      db.into(db.anotaciones).insert(anotacion('{"progression":0.5}')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('una edición solo puede ser del PC o del teléfono', () async {
    await expectLater(
      db
          .into(db.ediciones)
          .insert(
            EdicionesCompanion.insert(
              id: 'e1',
              titulo: 't',
              tipo: 'application/epub+zip',
              anadidaEn: '2026-01-01T00:00:00Z',
              origen: const Value<String>('nube'),
            ),
          ),
      throwsA(isA<SqliteException>()),
    );
  });
}
