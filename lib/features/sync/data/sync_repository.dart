import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../../core/motor/motor.dart';
import '../../../core/security/secure_store.dart';
import '../../../data/db/database.dart';
import '../../../data/db/tables.dart';

/// Cuánto ha cambiado una sincronización, para decirlo en la interfaz.
class ResultadoDeSync {
  const ResultadoDeSync({
    required this.recibidos,
    required this.enviados,
    required this.rechazados,
  });

  final int recibidos;
  final int enviados;
  final int rechazados;
}

/// Lo que el teléfono elige recibir del PC. Las listas se combinan; `todo`
/// manda sobre ellas.
class Seleccion {
  const Seleccion({
    this.todo = false,
    this.colecciones = const <String>[],
    this.autores = const <String>[],
    this.series = const <String>[],
    this.materias = const <String>[],
    this.ediciones = const <String>[],
  });

  factory Seleccion.fromJson(Map<String, dynamic> j) {
    List<String> l(String k) =>
        (j[k] as List<dynamic>? ?? <dynamic>[]).cast<String>();
    return Seleccion(
      todo: j['todo'] as bool? ?? false,
      colecciones: l('colecciones'),
      autores: l('autores'),
      series: l('series'),
      materias: l('materias'),
      ediciones: l('ediciones'),
    );
  }

  final bool todo;
  final List<String> colecciones;
  final List<String> autores;
  final List<String> series;
  final List<String> materias;
  final List<String> ediciones;

  bool get vacia =>
      !todo &&
      colecciones.isEmpty &&
      autores.isEmpty &&
      series.isEmpty &&
      materias.isEmpty &&
      ediciones.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'todo': todo,
    'colecciones': colecciones,
    'autores': autores,
    'series': series,
    'materias': materias,
    'ediciones': ediciones,
  };

  Seleccion copiar({
    bool? todo,
    List<String>? colecciones,
    List<String>? autores,
    List<String>? series,
    List<String>? materias,
    List<String>? ediciones,
  }) => Seleccion(
    todo: todo ?? this.todo,
    colecciones: colecciones ?? this.colecciones,
    autores: autores ?? this.autores,
    series: series ?? this.series,
    materias: materias ?? this.materias,
    ediciones: ediciones ?? this.ediciones,
  );
}

/// Una ficha del catálogo del PC, tal como la devuelve `/catalogo`.
class FichaDelPc {
  const FichaDelPc({
    required this.id,
    required this.titulo,
    required this.autores,
    required this.portada,
    required this.seleccionada,
  });

  factory FichaDelPc.fromJson(Map<String, dynamic> j) => FichaDelPc(
    id: j['id'] as String,
    titulo: j['titulo'] as String? ?? '',
    autores: (j['autores'] as List<dynamic>? ?? <dynamic>[]).cast<String>(),
    portada: j['portada'] as bool? ?? false,
    seleccionada: j['seleccionada'] as bool? ?? false,
  );

  final String id;
  final String titulo;
  final List<String> autores;
  final bool portada;
  final bool seleccionada;
}

/// Un resultado de la búsqueda en directo del PC.
class ResultadoDeBusqueda {
  const ResultadoDeBusqueda({
    required this.edicion,
    required this.titulo,
    required this.locator,
    required this.pasaje,
    required this.seleccionada,
  });

  factory ResultadoDeBusqueda.fromJson(Map<String, dynamic> j) =>
      ResultadoDeBusqueda(
        edicion: j['edicion'] as String,
        titulo: j['titulo'] as String? ?? '',
        locator: j['locator'] as Map<String, dynamic>,
        pasaje: (j['pasaje'] as String? ?? '').replaceAll(
          RegExp('<[^>]*>'),
          '',
        ),
        seleccionada: j['seleccionada'] as bool? ?? false,
      );

  final String edicion;
  final String titulo;
  final Map<String, dynamic> locator;
  final String pasaje;
  final bool seleccionada;
}

/// Una estantería que se puede elegir: colección, autor, serie o materia.
class Estanteria {
  const Estanteria(this.clave, this.nombre, this.obras);
  final String clave;
  final String nombre;
  final int obras;
}

class Estanterias {
  const Estanterias({
    required this.colecciones,
    required this.autores,
    required this.series,
    required this.materias,
    required this.total,
  });

  final List<Estanteria> colecciones;
  final List<Estanteria> autores;
  final List<Estanteria> series;
  final List<Estanteria> materias;
  final int total;
}

/// El cliente del contrato con NB Books (docs/architecture/pc-contract.md).
///
/// Cada tipo de dato tiene un dueño y un sentido (ADR-002): lo del PC se aplica
/// tal cual llega; lo que se hizo aquí sube y solo se suma.
class SyncRepository {
  SyncRepository({
    required this.db,
    required this.dioFor,
    required this.carpetaDeLibros,
    required this.carpetaDePortadas,
    Directory? carpetaTemporal,
  }) : carpetaTemporal =
           carpetaTemporal ?? Directory('${carpetaDeLibros.path}/temporal');

  final AppDatabase db;
  final Dio Function(PairedPc pc) dioFor;
  final Directory carpetaDeLibros;
  final Directory carpetaDePortadas;

  /// Libros traídos para leer sin descargar (ADR-009). Es una caché: se
  /// recorta sola y no cuenta como descargado.
  final Directory carpetaTemporal;

  /// Cuánto puede ocupar la caché de lectura sin descargar.
  static const int limiteTemporal = 300 * 1024 * 1024;

  static const String kVersion = 'sync_version';
  static const String kUltima = 'sync_ultima';
  static const int _porTanda = 300;

  // --- Selección y catálogo en directo -------------------------------------

  Future<Seleccion> seleccion(PairedPc pc) async {
    final Response<dynamic> r = await dioFor(
      pc,
    ).get<dynamic>('/api/v1/seleccion');
    return Seleccion.fromJson(r.data as Map<String, dynamic>);
  }

  /// Cambia la selección. Si se amplió, el manifiesto se vuelve a pedir desde
  /// el principio: lo recién elegido tiene versiones viejas.
  Future<void> fijarSeleccion(PairedPc pc, Seleccion s) async {
    final Response<dynamic> r = await dioFor(
      pc,
    ).post<dynamic>('/api/v1/seleccion', data: s.toJson());
    if ((r.data as Map<String, dynamic>)['reiniciar'] == true) {
      await db.fijarAjuste(kVersion, '0');
    }
  }

  Future<Estanterias> estanterias(PairedPc pc) async {
    final Map<String, dynamic> d =
        (await dioFor(pc).get<dynamic>('/api/v1/estanterias')).data
            as Map<String, dynamic>;
    List<Estanteria> lista(String k) => <Estanteria>[
      for (final dynamic e in d[k] as List<dynamic>? ?? <dynamic>[])
        Estanteria(
          (e as Map<String, dynamic>)['clave'] as String? ??
              e['id'] as String? ??
              '',
          e['nombre'] as String? ?? '',
          (e['libros'] as num?)?.toInt() ?? 0,
        ),
    ];
    return Estanterias(
      colecciones: lista('colecciones'),
      autores: lista('autores'),
      series: lista('series'),
      materias: lista('materias'),
      total: (d['total'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<FichaDelPc>> catalogo(
    PairedPc pc, {
    String q = '',
    int desde = 0,
    int limite = 60,
  }) async {
    final Response<dynamic> r = await dioFor(pc).get<dynamic>(
      '/api/v1/catalogo',
      queryParameters: <String, dynamic>{
        'q': q,
        'desde': desde,
        'limit': limite,
      },
    );
    return <FichaDelPc>[
      for (final dynamic f
          in (r.data as Map<String, dynamic>)['fichas'] as List<dynamic>)
        FichaDelPc.fromJson(f as Map<String, dynamic>),
    ];
  }

  Future<List<ResultadoDeBusqueda>> buscar(
    PairedPc pc,
    String q, {
    int desde = 0,
  }) async {
    final Response<dynamic> r = await dioFor(pc).get<dynamic>(
      '/api/v1/buscar',
      queryParameters: <String, dynamic>{'q': q, 'desde': desde, 'limit': 30},
    );
    return <ResultadoDeBusqueda>[
      for (final dynamic f
          in (r.data as Map<String, dynamic>)['resultados'] as List<dynamic>)
        ResultadoDeBusqueda.fromJson(f as Map<String, dynamic>),
    ];
  }

  // --- Sincronización ------------------------------------------------------

  /// Sube lo pendiente y baja lo que cambió. Primero se sube: así el manifiesto
  /// que llega después ya trae lo propio confirmado.
  Future<ResultadoDeSync> sync(PairedPc pc) async {
    int enviados = 0;
    int rechazados = 0;
    // Por tandas: el PC admite 2.000 cosas por envío, y una semana sin
    // conexión puede juntar más.
    while (true) {
      final (int e, int r, bool quedan) = await _subir(pc);
      enviados += e;
      rechazados += r;
      // Si nada entró, insistir en la misma tanda no cambiaría nada.
      if (!quedan || e == 0) {
        break;
      }
    }
    final int recibidos = await _bajar(pc);
    await db.fijarAjuste(kUltima, ahoraIso());
    return ResultadoDeSync(
      recibidos: recibidos,
      enviados: enviados,
      rechazados: rechazados,
    );
  }

  Future<(int, int, bool)> _subir(PairedPc pc) async {
    final List<Anotacion> anotaciones =
        await (db.select(db.anotaciones)
              ..where((Anotaciones a) => a.pendiente.equals(true))
              ..limit(_porTanda))
            .get();
    final List<Posicion> posiciones =
        await (db.select(db.posiciones)
              ..where(
                (Posiciones p) =>
                    p.pendiente.equals(true) & p.dispositivo.equals('telefono'),
              )
              ..limit(_porTanda))
            .get();
    final List<Sesion> sesiones =
        await (db.select(db.sesiones)
              ..where((Sesiones s) => s.pendiente.equals(true))
              ..limit(_porTanda))
            .get();
    final List<Palabra> palabras =
        await (db.select(db.vocabulario)
              ..where((Vocabulario v) => v.pendiente.equals(true))
              ..limit(_porTanda))
            .get();
    final List<Repaso> repasos =
        await (db.select(db.repasos)
              ..where((Repasos r) => r.pendiente.equals(true))
              ..limit(_porTanda))
            .get();
    final List<Nota> notas =
        await (db.select(db.notas)
              ..where((Notas n) => n.pendiente.equals(true))
              ..limit(_porTanda))
            .get();

    // Lo del teléfono nunca sube: ni el libro ni lo que cuelga de él.
    final Set<String> deTelefono = <String>{
      for (final Edicion e in await (db.select(
        db.ediciones,
      )..where((Ediciones e) => e.origen.equals('telefono'))).get())
        e.id,
    };
    bool sube(String edicion) => !deTelefono.contains(edicion);

    final Map<String, dynamic> envio = <String, dynamic>{
      'anotaciones': <Map<String, dynamic>>[
        for (final Anotacion a in anotaciones.where(
          (Anotacion a) => sube(a.edicion),
        ))
          <String, dynamic>{
            'id': a.id,
            'edicion': a.edicion,
            'tipo': a.tipo,
            'texto': a.texto,
            'locator': jsonDecode(a.locator),
            'trazo': a.trazo == null ? null : jsonDecode(a.trazo!),
            'creada_en': a.creadaEn,
            'baja_en': a.bajaEn,
            'sustituye_a': a.sustituyeA,
          },
      ],
      'posiciones': <Map<String, dynamic>>[
        for (final Posicion p in posiciones.where(
          (Posicion p) => sube(p.edicion),
        ))
          <String, dynamic>{
            'edicion': p.edicion,
            'locator': jsonDecode(p.locator),
            'actualizado_en': p.actualizadoEn,
          },
      ],
      'sesiones': <Map<String, dynamic>>[
        for (final Sesion s in sesiones.where((Sesion s) => sube(s.edicion)))
          <String, dynamic>{
            'id': s.id,
            'edicion': s.edicion,
            'inicio': s.inicio,
            'fin': s.fin,
            'desde': jsonDecode(s.desde),
            'hasta': s.hasta == null ? null : jsonDecode(s.hasta!),
          },
      ],
      'vocabulario': <Map<String, dynamic>>[
        for (final Palabra v in palabras.where((Palabra v) => sube(v.edicion)))
          <String, dynamic>{
            'id': v.id,
            'edicion': v.edicion,
            'lema': v.lema,
            'termino': v.termino,
            'proveedor': v.proveedor,
            'locator': jsonDecode(v.locator),
            'creada_en': v.creadaEn,
          },
      ],
      'repasos': <Map<String, dynamic>>[
        for (final Repaso r in repasos)
          <String, dynamic>{
            'id': r.id,
            'tarjeta': r.tarjeta,
            'calificacion': r.calificacion,
            'repasado_en': r.repasadoEn,
          },
      ],
      'notas': <Map<String, dynamic>>[
        for (final Nota n in notas)
          <String, dynamic>{
            'id': n.id,
            'titulo': n.titulo,
            'cuerpo': n.cuerpo,
            'revision_vista': n.revision == 0 ? null : n.revision,
          },
      ],
    };
    final int total = envio.values.fold<int>(
      0,
      (int t, dynamic l) => t + (l as List<dynamic>).length,
    );
    final bool quedan = <int>[
      anotaciones.length,
      posiciones.length,
      sesiones.length,
      palabras.length,
      repasos.length,
      notas.length,
    ].any((int n) => n == _porTanda);
    if (total == 0) {
      return (0, 0, false);
    }
    final Response<dynamic> r = await dioFor(
      pc,
    ).post<dynamic>('/api/v1/cambios', data: envio);
    final Map<String, dynamic> res =
        (r.data as Map<String, dynamic>)['resultado'] as Map<String, dynamic>;
    final Set<String> rechazados = <String>{
      for (final dynamic id
          in res['rechazados'] as List<dynamic>? ?? <dynamic>[])
        id as String,
    };

    await db.transaction(() async {
      Expression<bool> confirmado(Expression<String> id) =>
          id.isNotIn(rechazados);
      await (db.update(db.anotaciones)..where(
            (Anotaciones a) => a.pendiente.equals(true) & confirmado(a.id),
          ))
          .write(const AnotacionesCompanion(pendiente: Value<bool>(false)));
      await (db.update(db.posiciones)
            ..where((Posiciones p) => p.pendiente.equals(true)))
          .write(const PosicionesCompanion(pendiente: Value<bool>(false)));
      await (db.update(
            db.sesiones,
          )..where((Sesiones s) => s.pendiente.equals(true) & confirmado(s.id)))
          .write(const SesionesCompanion(pendiente: Value<bool>(false)));
      await (db.update(db.vocabulario)..where(
            (Vocabulario v) => v.pendiente.equals(true) & confirmado(v.id),
          ))
          .write(const VocabularioCompanion(pendiente: Value<bool>(false)));
      await (db.update(db.repasos)
            ..where((Repasos x) => x.pendiente.equals(true) & confirmado(x.id)))
          .write(const RepasosCompanion(pendiente: Value<bool>(false)));
      await (db.update(db.notas)
            ..where((Notas n) => n.pendiente.equals(true) & confirmado(n.id)))
          .write(const NotasCompanion(pendiente: Value<bool>(false)));
      // Una nota que cambió en el PC mientras se editaba aquí entró como
      // copia: la de aquí pasa a ser esa copia, y la original vuelve con el
      // manifiesto tal como está en el PC.
      for (final dynamic par
          in res['notas_copiadas'] as List<dynamic>? ?? <dynamic>[]) {
        final List<dynamic> p = par as List<dynamic>;
        await (db.delete(
          db.notas,
        )..where((Notas n) => n.id.equals(p[0] as String))).go();
      }
    });
    return (total - rechazados.length, rechazados.length, quedan);
  }

  Future<int> _bajar(PairedPc pc) async {
    int desde = int.tryParse(await db.ajuste(kVersion) ?? '') ?? 0;
    int recibidos = 0;
    final Set<String> tarjetasTocadas = <String>{};
    while (true) {
      final Response<dynamic> r = await dioFor(pc).get<dynamic>(
        '/api/v1/manifest',
        queryParameters: <String, dynamic>{'since': desde, 'limit': 500},
      );
      final Map<String, dynamic> pagina = r.data as Map<String, dynamic>;
      final List<dynamic> cambios = pagina['cambios'] as List<dynamic>;
      await db.transaction(() async {
        for (final dynamic c in cambios) {
          await _aplicar(c as Map<String, dynamic>, tarjetasTocadas);
        }
        desde = (pagina['siguiente'] as num).toInt();
        await db.fijarAjuste(kVersion, '$desde');
      });
      recibidos += cambios.length;
      if (pagina['hay_mas'] != true) {
        break;
      }
    }
    for (final String t in tarjetasTocadas) {
      await recalcularTarjeta(db, t);
    }
    return recibidos;
  }

  Future<void> _aplicar(Map<String, dynamic> c, Set<String> tarjetas) async {
    final String entidad = c['entidad'] as String;
    final String clave = c['clave'] as String;
    final bool borrado = c['borrado'] as bool? ?? false;
    final Map<String, dynamic>? d = c['datos'] as Map<String, dynamic>?;
    String? j(Object? v) => v == null ? null : jsonEncode(v);

    switch (entidad) {
      case 'edicion':
        if (borrado || d == null) {
          await _olvidarEdicion(clave);
          return;
        }
        final Map<String, dynamic>? archivo =
            d['archivo'] as Map<String, dynamic>?;
        final Edicion? previa = await db.edicion(clave);
        await db
            .into(db.ediciones)
            .insertOnConflictUpdate(
              EdicionesCompanion.insert(
                id: clave,
                titulo: d['titulo'] as String? ?? '',
                subtitulo: Value<String?>(d['subtitulo'] as String?),
                autores: Value<String>(jsonEncode(d['autores'] ?? <String>[])),
                ordenAutor: Value<String?>(d['orden_autor'] as String?),
                serie: Value<String?>(d['serie'] as String?),
                indiceSerie: Value<double?>(
                  (d['indice_serie'] as num?)?.toDouble(),
                ),
                idioma: Value<String?>(d['idioma'] as String?),
                editorial: Value<String?>(d['editorial'] as String?),
                fecha: Value<String?>(d['fecha'] as String?),
                sinopsis: Value<String?>(d['sinopsis'] as String?),
                materias: Value<String>(
                  jsonEncode(d['materias'] ?? <dynamic>[]),
                ),
                portada: Value<bool>(d['portada'] as bool? ?? false),
                huella: Value<String?>(archivo?['huella'] as String?),
                bytes: Value<int>((archivo?['bytes'] as num?)?.toInt() ?? 0),
                tipo: archivo?['tipo'] as String? ?? 'application/epub+zip',
                // Un archivo descargado sigue valiendo solo si es el mismo.
                ruta: Value<String?>(
                  previa?.huella == archivo?['huella'] ? previa?.ruta : null,
                ),
                rutaPortada: Value<String?>(previa?.rutaPortada),
                anadidaEn: previa?.anadidaEn ?? ahoraIso(),
              ),
            );
        if (previa != null &&
            previa.ruta != null &&
            previa.huella != archivo?['huella']) {
          _borrarArchivo(previa.ruta);
        }
      case 'coleccion':
        if (borrado || d == null) {
          await (db.delete(
            db.colecciones,
          )..where((Colecciones x) => x.id.equals(clave))).go();
          return;
        }
        await db
            .into(db.colecciones)
            .insertOnConflictUpdate(
              ColeccionesCompanion.insert(
                id: clave,
                nombre: d['nombre'] as String? ?? '',
                tipo: d['tipo'] as String? ?? 'manual',
                ediciones: Value<String>(
                  jsonEncode(d['ediciones'] ?? <dynamic>[]),
                ),
              ),
            );
      case 'anotacion':
        if (borrado || d == null) {
          await (db.delete(
            db.anotaciones,
          )..where((Anotaciones x) => x.id.equals(clave))).go();
          return;
        }
        await db
            .into(db.anotaciones)
            .insertOnConflictUpdate(
              AnotacionesCompanion.insert(
                id: clave,
                edicion: d['edicion'] as String,
                tipo: d['tipo'] as String,
                texto: Value<String?>(d['texto'] as String?),
                locator: jsonEncode(d['locator']),
                trazo: Value<String?>(j(d['trazo'])),
                creadaEn: d['creada_en'] as String,
                bajaEn: Value<String?>(d['baja_en'] as String?),
                sustituyeA: Value<String?>(d['sustituye_a'] as String?),
              ),
            );
      case 'progreso':
        if (borrado || d == null) {
          await (db.delete(db.posiciones)..where(
                (Posiciones p) =>
                    p.edicion.equals(clave) & p.dispositivo.equals('pc'),
              ))
              .go();
          return;
        }
        final Map<String, dynamic> loc = d['locator'] as Map<String, dynamic>;
        await db
            .into(db.posiciones)
            .insertOnConflictUpdate(
              PosicionesCompanion.insert(
                edicion: clave,
                dispositivo: 'pc',
                locator: jsonEncode(loc),
                progresion: Value<double?>(
                  ((loc['locations']
                              as Map<String, dynamic>?)?['totalProgression']
                          as num?)
                      ?.toDouble(),
                ),
                actualizadoEn: d['actualizado_en'] as String,
              ),
            );
      case 'sesion':
        if (borrado || d == null) {
          await (db.delete(
            db.sesiones,
          )..where((Sesiones x) => x.id.equals(clave))).go();
          return;
        }
        await db
            .into(db.sesiones)
            .insertOnConflictUpdate(
              SesionesCompanion.insert(
                id: clave,
                edicion: d['edicion'] as String,
                inicio: d['inicio'] as String,
                fin: Value<String?>(d['fin'] as String?),
                desde: jsonEncode(d['desde']),
                hasta: Value<String?>(j(d['hasta'])),
              ),
            );
      case 'vocabulario':
        if (borrado || d == null) {
          await (db.delete(
            db.vocabulario,
          )..where((Vocabulario x) => x.id.equals(clave))).go();
          return;
        }
        await db
            .into(db.vocabulario)
            .insertOnConflictUpdate(
              VocabularioCompanion.insert(
                id: clave,
                edicion: d['edicion'] as String,
                lema: d['lema'] as String,
                termino: d['termino'] as String,
                proveedor: d['proveedor'] as String? ?? '',
                locator: jsonEncode(d['locator']),
                creadaEn: d['creada_en'] as String,
              ),
            );
      case 'tarjeta':
        if (borrado || d == null) {
          await (db.delete(
            db.tarjetas,
          )..where((Tarjetas x) => x.id.equals(clave))).go();
          return;
        }
        final Map<String, dynamic> base = d['base'] as Map<String, dynamic>;
        await db
            .into(db.tarjetas)
            .insertOnConflictUpdate(
              TarjetasCompanion.insert(
                id: clave,
                edicion: Value<String?>(d['edicion'] as String?),
                tipo: d['tipo'] as String? ?? 'flashcard',
                anverso: d['anverso'] as String? ?? '',
                reverso: d['reverso'] as String? ?? '',
                opciones: Value<String?>(j(d['opciones'])),
                base: jsonEncode(base),
                venceEn: base['vence_en'] as String? ?? ahoraIso(),
              ),
            );
        tarjetas.add(clave);
      case 'repaso':
        if (borrado || d == null) {
          return;
        }
        await db
            .into(db.repasos)
            .insertOnConflictUpdate(
              RepasosCompanion.insert(
                id: clave,
                tarjeta: d['tarjeta'] as String,
                calificacion: d['calificacion'] as String,
                repasadoEn: d['repasado_en'] as String,
              ),
            );
        tarjetas.add(d['tarjeta'] as String);
      case 'nota':
        if (borrado || d == null) {
          await (db.delete(
            db.notas,
          )..where((Notas x) => x.id.equals(clave))).go();
          return;
        }
        // Una edición propia sin subir no se pisa: subirá con la revisión que
        // vio, y el PC decide si entra o llega como copia.
        final Nota? local = await (db.select(
          db.notas,
        )..where((Notas n) => n.id.equals(clave))).getSingleOrNull();
        if (local != null && local.pendiente) {
          return;
        }
        await db
            .into(db.notas)
            .insertOnConflictUpdate(
              NotasCompanion.insert(
                id: clave,
                titulo: d['titulo'] as String? ?? '',
                cuerpo: d['cuerpo'] as String? ?? '',
                revision: Value<int>((d['revision'] as num?)?.toInt() ?? 0),
                actualizadaEn: d['actualizada_en'] as String? ?? ahoraIso(),
              ),
            );
    }
  }

  Future<void> _olvidarEdicion(String id) async {
    final Edicion? e = await db.edicion(id);
    if (e == null || e.origen == 'telefono') {
      return;
    }
    _borrarArchivo(e.ruta);
    _borrarArchivo(e.rutaPortada);
    await (db.delete(
      db.ediciones,
    )..where((Ediciones x) => x.id.equals(id))).go();
  }

  void _borrarArchivo(String? ruta) {
    if (ruta == null) {
      return;
    }
    try {
      File(ruta).deleteSync();
    } catch (_) {
      // Ya no estaba: no hay nada que limpiar.
    }
  }

  // --- Descargas -----------------------------------------------------------

  /// Descarga el libro de una edición, reanudando por tramos lo que quedó a
  /// medias. Se comprueba la huella antes de darlo por bueno.
  Future<void> descargar(
    PairedPc pc,
    Edicion e, {
    void Function(int recibido, int total)? progreso,
    CancelToken? cancelar,
    bool temporal = false,
  }) async {
    final String? huella = e.huella;
    if (huella == null) {
      throw const MotorException('FILE_NOT_FOUND');
    }
    final Directory carpeta = temporal ? carpetaTemporal : carpetaDeLibros;
    carpeta.createSync(recursive: true);
    final String limpio = huella.replaceAll(':', '_');
    final File destino = File('${carpeta.path}/$limpio');
    final File parcial = File('${destino.path}.parcial');
    final int yaHay = parcial.existsSync() ? parcial.lengthSync() : 0;
    final Response<ResponseBody> r = await dioFor(pc).get<ResponseBody>(
      '/api/v1/archivo/$huella',
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(minutes: 5),
        headers: <String, dynamic>{if (yaHay > 0) 'Range': 'bytes=$yaHay-'},
      ),
      cancelToken: cancelar,
    );
    final bool reanuda = r.statusCode == 206;
    final IOSink salida = parcial.openWrite(
      mode: reanuda ? FileMode.append : FileMode.write,
    );
    int recibido = reanuda ? yaHay : 0;
    try {
      await for (final List<int> trozo in r.data!.stream) {
        salida.add(trozo);
        recibido += trozo.length;
        progreso?.call(recibido, e.bytes);
      }
    } finally {
      await salida.close();
    }
    final String obtenida = await Motor.huella(parcial.path);
    if (obtenida != huella) {
      parcial.deleteSync();
      throw const MotorException('DOCUMENT_CORRUPTED');
    }
    parcial.renameSync(destino.path);
    if (temporal) {
      _recortarTemporales();
      return;
    }
    await (db.update(db.ediciones)..where((Ediciones x) => x.id.equals(e.id)))
        .write(EdicionesCompanion(ruta: Value<String?>(destino.path)));
  }

  /// Si el libro sigue en la caché de leer sin descargar, sin tocar su fecha:
  /// para decidir qué botón enseñar, no para abrirlo.
  bool enCache(Edicion e) {
    final String? huella = e.huella;
    return huella != null &&
        File(
          '${carpetaTemporal.path}/${huella.replaceAll(':', '_')}',
        ).existsSync();
  }

  /// El archivo traído para leer sin descargar, si sigue en la caché.
  File? temporalDe(Edicion e) {
    final String? huella = e.huella;
    if (huella == null) {
      return null;
    }
    final File f = File(
      '${carpetaTemporal.path}/${huella.replaceAll(':', '_')}',
    );
    if (!f.existsSync()) {
      return null;
    }
    // Abrirlo lo hace el más reciente: el recorte quita primero lo que lleva
    // más tiempo sin leerse.
    f.setLastModifiedSync(DateTime.now());
    return f;
  }

  /// Deja la caché por debajo del límite, empezando por lo más antiguo. Lo
  /// recién traído no se toca aunque solo él ya pase del límite.
  void _recortarTemporales() {
    final List<File> archivos =
        carpetaTemporal
            .listSync()
            .whereType<File>()
            .where((File f) => !f.path.endsWith('.parcial'))
            .toList()
          ..sort(
            (File a, File b) =>
                b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    int total = 0;
    for (int i = 0; i < archivos.length; i++) {
      total += archivos[i].lengthSync();
      if (i > 0 && total > limiteTemporal) {
        archivos[i].deleteSync();
      }
    }
  }

  /// Lo que ocupa la caché de leer sin descargar.
  int bytesTemporales() => !carpetaTemporal.existsSync()
      ? 0
      : carpetaTemporal.listSync().whereType<File>().fold<int>(
          0,
          (int t, File f) => t + f.lengthSync(),
        );

  /// Vacía la caché de leer sin descargar. Lo anotado no se toca: vive en la
  /// base, no en el archivo.
  void vaciarTemporales() {
    if (carpetaTemporal.existsSync()) {
      carpetaTemporal.deleteSync(recursive: true);
    }
  }

  /// Quita del teléfono el archivo descargado. La ficha se queda.
  Future<void> quitarDescarga(Edicion e) async {
    _borrarArchivo(e.ruta);
    await (db.update(db.ediciones)..where((Ediciones x) => x.id.equals(e.id)))
        .write(const EdicionesCompanion(ruta: Value<String?>(null)));
  }

  /// Baja las portadas que faltan de lo seleccionado.
  Future<void> portadasQueFaltan(PairedPc pc) async {
    final List<Edicion> faltan =
        await (db.select(db.ediciones)..where(
              (Ediciones e) =>
                  e.portada.equals(true) &
                  e.rutaPortada.isNull() &
                  e.origen.equals('pc'),
            ))
            .get();
    carpetaDePortadas.createSync(recursive: true);
    for (final Edicion e in faltan) {
      try {
        final Response<List<int>> r = await dioFor(pc).get<List<int>>(
          '/api/v1/portada/${e.id}',
          options: Options(responseType: ResponseType.bytes),
        );
        final File f = File('${carpetaDePortadas.path}/${e.id}')
          ..writeAsBytesSync(r.data!);
        await (db.update(db.ediciones)
              ..where((Ediciones x) => x.id.equals(e.id)))
            .write(EdicionesCompanion(rutaPortada: Value<String?>(f.path)));
      } catch (_) {
        // Una portada que no llega se pinta con su sustituta y se reintenta en
        // la siguiente sincronización.
      }
    }
  }
}

/// Recalcula la programación de una tarjeta reproduciendo sus repasos sobre la
/// base con el motor: el mismo resultado que en el PC.
Future<void> recalcularTarjeta(AppDatabase db, String id) async {
  final Tarjeta? t = await (db.select(
    db.tarjetas,
  )..where((Tarjetas x) => x.id.equals(id))).getSingleOrNull();
  if (t == null) {
    return;
  }
  final List<Repaso> repasos = await db.repasosDe(id);
  final Map<String, dynamic> p = await Motor.reproducirRepasos(
    base: jsonDecode(t.base) as Map<String, dynamic>,
    repasos: <(String, String)>[
      for (final Repaso r in repasos) (r.repasadoEn, r.calificacion),
    ],
  );
  await (db.update(db.tarjetas)..where((Tarjetas x) => x.id.equals(id))).write(
    TarjetasCompanion(
      repeticiones: Value<int>((p['repeticiones'] as num).toInt()),
      intervaloDias: Value<int>((p['intervaloDias'] as num).toInt()),
      facilidad: Value<double>((p['facilidad'] as num).toDouble()),
      venceEn: Value<String>(p['venceEn'] as String),
      repasadaEn: Value<String?>(p['repasadaEn'] as String?),
    ),
  );
}
