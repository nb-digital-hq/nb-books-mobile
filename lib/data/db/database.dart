import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// La base del teléfono (Drift sobre SQLite). Réplica de lo que el teléfono
/// eligió del PC más lo que hace en él. Ver docs/architecture/storage.md.
///
/// Una migración publicada no se edita nunca: se añade la siguiente.
@DriftDatabase(
  tables: <Type>[
    Ediciones,
    Colecciones,
    Anotaciones,
    Posiciones,
    Sesiones,
    Vocabulario,
    Tarjetas,
    Repasos,
    Notas,
    Ajustes,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'nb_books'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await customStatement(
        'CREATE INDEX anotaciones_por_edicion ON anotaciones (edicion)',
      );
      await customStatement(
        'CREATE INDEX repasos_por_tarjeta ON repasos (tarjeta, repasado_en)',
      );
    },
    beforeOpen: (OpeningDetails d) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  // --- Ajustes -------------------------------------------------------------

  Future<String?> ajuste(String clave) async => (await (select(
    ajustes,
  )..where((Ajustes a) => a.clave.equals(clave))).getSingleOrNull())?.valor;

  Future<void> fijarAjuste(String clave, String valor) => into(
    ajustes,
  ).insertOnConflictUpdate(AjustesCompanion.insert(clave: clave, valor: valor));

  Future<void> borrarAjuste(String clave) =>
      (delete(ajustes)..where((Ajustes a) => a.clave.equals(clave))).go();

  Stream<String?> vigilarAjuste(String clave) =>
      (select(ajustes)..where((Ajustes a) => a.clave.equals(clave)))
          .watchSingleOrNull()
          .map((Ajuste? a) => a?.valor);

  // --- Biblioteca ----------------------------------------------------------

  Stream<List<Edicion>> vigilarEdiciones() =>
      (select(ediciones)..orderBy(<OrderClauseGenerator<Ediciones>>[
            (Ediciones e) => OrderingTerm.asc(e.titulo),
          ]))
          .watch();

  Future<Edicion?> edicion(String id) => (select(
    ediciones,
  )..where((Ediciones e) => e.id.equals(id))).getSingleOrNull();

  Stream<Edicion?> vigilarEdicion(String id) => (select(
    ediciones,
  )..where((Ediciones e) => e.id.equals(id))).watchSingleOrNull();

  Stream<List<Coleccion>> vigilarColecciones() =>
      (select(colecciones)..orderBy(<OrderClauseGenerator<Colecciones>>[
            (Colecciones c) => OrderingTerm.asc(c.nombre),
          ]))
          .watch();

  // --- Posiciones ----------------------------------------------------------

  Future<Posicion?> posicion(String edicion, String dispositivo) =>
      (select(posiciones)..where(
            (Posiciones p) =>
                p.edicion.equals(edicion) & p.dispositivo.equals(dispositivo),
          ))
          .getSingleOrNull();

  Stream<List<Posicion>> vigilarPosiciones() => select(posiciones).watch();

  /// Apunta dónde va este teléfono. Nunca toca la del PC.
  Future<void> apuntarPosicion(
    String edicion,
    String locator,
    double? progresion,
  ) => into(posiciones).insertOnConflictUpdate(
    PosicionesCompanion.insert(
      edicion: edicion,
      dispositivo: 'telefono',
      locator: locator,
      progresion: Value<double?>(progresion),
      actualizadoEn: ahoraIso(),
      pendiente: const Value<bool>(true),
    ),
  );

  // --- Anotaciones ---------------------------------------------------------

  Stream<List<Anotacion>> vigilarAnotaciones(String edicion) =>
      (select(anotaciones)
            ..where(
              (Anotaciones a) => a.edicion.equals(edicion) & a.bajaEn.isNull(),
            )
            ..orderBy(<OrderClauseGenerator<Anotaciones>>[
              (Anotaciones a) => OrderingTerm.asc(a.creadaEn),
            ]))
          .watch();

  Stream<List<Anotacion>> vigilarTodasLasAnotaciones() =>
      (select(anotaciones)
            ..where((Anotaciones a) => a.bajaEn.isNull())
            ..orderBy(<OrderClauseGenerator<Anotaciones>>[
              (Anotaciones a) => OrderingTerm.desc(a.creadaEn),
            ]))
          .watch();

  /// Una anotación nueva. Si sustituye a otra, la otra queda dada de baja: es
  /// como se edita lo que es inmutable.
  Future<void> anotar(AnotacionesCompanion nueva) => transaction(() async {
    await into(anotaciones).insert(nueva);
    final String? anterior = nueva.sustituyeA.present
        ? nueva.sustituyeA.value
        : null;
    if (anterior != null) {
      await (update(
        anotaciones,
      )..where((Anotaciones a) => a.id.equals(anterior))).write(
        AnotacionesCompanion(
          bajaEn: Value<String?>(ahoraIso()),
          pendiente: const Value<bool>(true),
        ),
      );
    }
  });

  /// Quitar es dar de baja, no borrar: la baja tiene que llegar al PC.
  Future<void> darDeBaja(String id) =>
      (update(anotaciones)..where((Anotaciones a) => a.id.equals(id))).write(
        AnotacionesCompanion(
          bajaEn: Value<String?>(ahoraIso()),
          pendiente: const Value<bool>(true),
        ),
      );

  /// Deshace [darDeBaja] mientras la persona aún puede arrepentirse.
  Future<void> recuperar(String id) =>
      (update(anotaciones)..where((Anotaciones a) => a.id.equals(id))).write(
        const AnotacionesCompanion(
          bajaEn: Value<String?>(null),
          pendiente: Value<bool>(true),
        ),
      );

  // --- Estudio -------------------------------------------------------------

  Stream<List<Tarjeta>> vigilarTarjetasPendientes(String hasta) =>
      (select(tarjetas)
            ..where((Tarjetas t) => t.venceEn.isSmallerOrEqualValue(hasta))
            ..orderBy(<OrderClauseGenerator<Tarjetas>>[
              (Tarjetas t) => OrderingTerm.asc(t.venceEn),
            ]))
          .watch();

  Stream<int> vigilarCuantasTarjetas() => tarjetas.count().watchSingle();

  Future<List<Repaso>> repasosDe(String tarjeta) =>
      (select(repasos)
            ..where((Repasos r) => r.tarjeta.equals(tarjeta))
            ..orderBy(<OrderClauseGenerator<Repasos>>[
              (Repasos r) => OrderingTerm.asc(r.repasadoEn),
              (Repasos r) => OrderingTerm.asc(r.id),
            ]))
          .get();

  Stream<List<Nota>> vigilarNotas() =>
      (select(notas)..orderBy(<OrderClauseGenerator<Notas>>[
            (Notas n) => OrderingTerm.desc(n.actualizadaEn),
          ]))
          .watch();

  Stream<List<Sesion>> vigilarSesiones() => select(sesiones).watch();

  Stream<List<Palabra>> vigilarVocabulario() =>
      (select(vocabulario)..orderBy(<OrderClauseGenerator<Vocabulario>>[
            (Vocabulario v) => OrderingTerm.desc(v.creadaEn),
          ]))
          .watch();
}

/// El instante en ISO-8601 UTC con milisegundos, el formato del PC: con los
/// microsegundos que añade Dart, el PC lo rechaza, y ordenarlos como texto
/// dejaría de ser ordenarlos en el tiempo.
String ahoraIso() => isoDe(DateTime.now());

String isoDe(DateTime t) {
  final DateTime u = t.toUtc();
  String d(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${d(u.year, 4)}-${d(u.month)}-${d(u.day)}T${d(u.hour)}:'
      '${d(u.minute)}:${d(u.second)}.${d(u.millisecond, 3)}Z';
}

/// Lee una lista JSON guardada en una columna, o una lista vacía.
List<dynamic> listaJson(String? texto) {
  if (texto == null || texto.isEmpty) {
    return const <dynamic>[];
  }
  try {
    final Object? v = jsonDecode(texto);
    return v is List<dynamic> ? v : const <dynamic>[];
  } catch (_) {
    return const <dynamic>[];
  }
}
