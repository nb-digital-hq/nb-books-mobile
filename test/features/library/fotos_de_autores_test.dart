import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/core/di/providers.dart';
import 'package:nb_books_mobile/core/network/wikimedia.dart';
import 'package:nb_books_mobile/data/db/database.dart';
import 'package:nb_books_mobile/features/library/application/fotos_de_autores.dart';

import 'estantes_test.dart' show libro;

// Respuestas con la forma de las de Wikidata y Commons, con personas
// inventadas: no se copia nada real al repositorio.
Map<String, dynamic> _entidad({
  required List<String> instancia,
  required List<String> oficios,
  String? foto,
}) {
  Map<String, dynamic> item(String id) => <String, dynamic>{
    'mainsnak': <String, dynamic>{
      'datavalue': <String, dynamic>{
        'value': <String, dynamic>{'id': id},
      },
    },
  };
  return <String, dynamic>{
    'claims': <String, dynamic>{
      'P31': instancia.map(item).toList(),
      'P106': oficios.map(item).toList(),
      if (foto != null)
        'P18': <Map<String, dynamic>>[
          <String, dynamic>{
            'mainsnak': <String, dynamic>{
              'datavalue': <String, dynamic>{'value': foto},
            },
          },
        ],
    },
  };
}

void main() {
  group('Wikidata', () {
    test('los candidatos de la búsqueda se leen en su orden', () {
      expect(
        idsDeBusqueda(<String, dynamic>{
          'search': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'Q2'},
            <String, dynamic>{'id': 'Q1'},
          ],
        }),
        <String>['Q2', 'Q1'],
      );
    });

    test('un homónimo que no escribe no presta su foto', () {
      final Map<String, dynamic> j = <String, dynamic>{
        'entities': <String, dynamic>{
          'Q2': _entidad(
            instancia: <String>['Q5'],
            oficios: <String>['Q937857'], // futbolista
            foto: 'Futbolista.jpg',
          ),
          'Q1': _entidad(
            instancia: <String>['Q5'],
            oficios: <String>['Q6625963'], // novelista
            foto: 'Novelista.jpg',
          ),
        },
      };
      expect(archivoDeAutor(j, <String>['Q2', 'Q1']), 'Novelista.jpg');
    });

    test('una obra o un lugar con el mismo nombre no cuenta como autor', () {
      final Map<String, dynamic> j = <String, dynamic>{
        'entities': <String, dynamic>{
          'Q3': _entidad(
            instancia: <String>['Q7725634'], // obra literaria
            oficios: <String>['Q36180'],
            foto: 'Obra.jpg',
          ),
        },
      };
      expect(archivoDeAutor(j, <String>['Q3']), isNull);
    });
  });

  group('Commons', () {
    test('la atribución llega en texto plano y con su licencia', () {
      final i = imagenDeCommons(<String, dynamic>{
        'query': <String, dynamic>{
          'pages': <String, dynamic>{
            '-1': <String, dynamic>{
              'imageinfo': <Map<String, dynamic>>[
                <String, dynamic>{
                  'thumburl':
                      'https://thumb.wikimedia.org/x/400px-A.jpg?utm_source=x',
                  'descriptionurl':
                      'https://commons.wikimedia.org/wiki/File:A.jpg',
                  'extmetadata': <String, dynamic>{
                    'Artist': <String, dynamic>{
                      'value': '<a href="x">Ana &amp; Bea</a>',
                    },
                    'LicenseShortName': <String, dynamic>{
                      'value': 'CC BY-SA 4.0',
                    },
                  },
                },
              ],
            },
          },
        },
      });
      expect(i?.url, 'https://thumb.wikimedia.org/x/400px-A.jpg');
      expect(i?.autoria, 'Ana & Bea');
      expect(i?.licencia, 'CC BY-SA 4.0');
    });

    test('una miniatura fuera de Wikimedia no se descarga', () {
      final i = imagenDeCommons(<String, dynamic>{
        'query': <String, dynamic>{
          'pages': <String, dynamic>{
            '1': <String, dynamic>{
              'imageinfo': <Map<String, dynamic>>[
                <String, dynamic>{'thumburl': 'https://otro.example/A.jpg'},
              ],
            },
          },
        },
      });
      expect(i, isNull);
    });
  });

  test('un autor sin foto se vuelve a mirar al mes, no en cada conexión', () {
    final DateTime ahora = DateTime(2026, 6, 1);
    expect(hayQueBuscar(null, ahora), isTrue);
    expect(
      hayQueBuscar(
        FotoDeAutor(buscada: ahora.subtract(const Duration(days: 3))),
        ahora,
      ),
      isFalse,
    );
    expect(
      hayQueBuscar(
        FotoDeAutor(buscada: ahora.subtract(const Duration(days: 40))),
        ahora,
      ),
      isTrue,
    );
    expect(
      hayQueBuscar(
        FotoDeAutor(
          archivo: '/x.jpg',
          buscada: ahora.subtract(const Duration(days: 400)),
        ),
        ahora,
      ),
      isFalse,
    );
  });

  group('las fotos se guardan en el teléfono', () {
    late Directory dir;
    late AppDatabase db;
    late ProviderContainer c;
    late List<String> preguntados;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fotos');
      db = AppDatabase(NativeDatabase.memory());
      for (final Edicion e in <Edicion>[
        libro('a', autores: <String>['Ana Ruiz']),
        libro('b', autores: <String>['ana ruiz', 'Bea Gil']),
      ]) {
        await db.into(db.ediciones).insert(e);
      }
      c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          documentosProvider.overrideWithValue(dir),
        ],
      );
      preguntados = <String>[];
      c.read(fotosDeAutoresProvider.notifier).buscador = (String n) async {
        preguntados.add(n);
        return n == 'Bea Gil'
            ? null
            : FotoEncontrada(
                bytes: Uint8List.fromList(<int>[1, 2, 3]),
                autoria: 'Fotógrafa',
                licencia: 'CC0',
                pagina: '',
              );
      };
    });

    tearDown(() async {
      c.dispose();
      await db.close();
      await dir.delete(recursive: true);
    });

    test('con el ajuste apagado no sale ninguna pregunta', () async {
      await c.read(fotosDeAutoresProvider.notifier).completar();
      expect(preguntados, isEmpty);
    });

    test(
      'al encenderlo se pregunta una vez por autor y no se repite',
      () async {
        final FotosDeAutores n = c.read(fotosDeAutoresProvider.notifier);
        await n.activar(true);
        expect(preguntados, <String>['Ana Ruiz', 'Bea Gil']);
        final FotoDeAutor? ana = c.read(fotosDeAutoresProvider)['ana ruiz'];
        expect(File(ana!.archivo!).readAsBytesSync(), <int>[1, 2, 3]);
        expect(ana.credito, 'Fotógrafa · CC0 · Wikimedia Commons');
        await n.completar();
        expect(preguntados, hasLength(2));
      },
    );

    test('si se cae la red se para y se sigue en la próxima', () async {
      final FotosDeAutores n = c.read(fotosDeAutoresProvider.notifier);
      n.buscador = (String _) async =>
          throw DioException(requestOptions: RequestOptions());
      await n.activar(true);
      expect(c.read(fotosDeAutoresProvider), isEmpty);
    });

    test('al apagarlo se borran las fotos', () async {
      final FotosDeAutores n = c.read(fotosDeAutoresProvider.notifier);
      await n.activar(true);
      await n.activar(false);
      expect(c.read(fotosDeAutoresProvider), isEmpty);
      expect(Directory('${dir.path}/autores').existsSync(), isFalse);
    });
  });
}
