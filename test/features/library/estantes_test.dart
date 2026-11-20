import 'package:flutter_test/flutter_test.dart';
import 'package:nb_books_mobile/data/db/database.dart';
import 'package:nb_books_mobile/features/library/application/estantes.dart';

Edicion libro(
  String id, {
  List<String> autores = const <String>[],
  String? serie,
  double? indice,
  String materias = '[]',
  String origen = 'pc',
  String? ruta,
  String anadida = '2026-01-01T00:00:00.000Z',
}) => Edicion(
  id: id,
  titulo: id,
  autores: '[${autores.map((String a) => '"$a"').join(',')}]',
  serie: serie,
  indiceSerie: indice,
  materias: materias,
  portada: false,
  bytes: 0,
  tipo: 'application/epub+zip',
  origen: origen,
  ruta: ruta,
  anadidaEn: anadida,
);

void main() {
  test('un libro con dos autores está en la estantería de cada uno', () {
    final List<Grupo> g = agrupar(<Edicion>[
      libro('a', autores: <String>['Ana', 'Bea']),
      libro('b', autores: <String>['Bea']),
    ], Estante.autor);
    expect(g.map((Grupo x) => x.nombre), <String>['Ana', 'Bea']);
    expect(g.last.libros.map((Edicion e) => e.id), <String>['a', 'b']);
  });

  test('una serie se ordena por su número y no por título', () {
    final Grupo s = agrupar(<Edicion>[
      libro('z', serie: 'Valle', indice: 1),
      libro('a', serie: 'Valle', indice: 3),
      libro('m', serie: 'Valle', indice: 2),
    ], Estante.serie).single;
    expect(s.libros.map((Edicion e) => e.id), <String>['z', 'm', 'a']);
  });

  test('las colecciones solo cuentan los libros que hay en el teléfono', () {
    final Grupo c = agrupar(
      <Edicion>[libro('a'), libro('b')],
      Estante.coleccion,
      colecciones: const <Coleccion>[
        Coleccion(
          id: 'c1',
          nombre: 'Verano',
          tipo: 'manual',
          ediciones: '["a","x"]',
        ),
      ],
    ).single;
    expect(c.nombre, 'Verano');
    expect(c.libros.map((Edicion e) => e.id), <String>['a']);
  });

  test('las estanterías se ordenan sin distinguir tildes ni mayúsculas', () {
    final List<Grupo> g = agrupar(<Edicion>[
      libro('1', autores: <String>['Óscar']),
      libro('2', autores: <String>['nuria']),
      libro('3', autores: <String>['Pablo']),
    ], Estante.autor);
    expect(g.map((Grupo x) => x.nombre), <String>['nuria', 'Óscar', 'Pablo']);
  });

  test('los filtros separan lo empezado, lo terminado y lo descargado', () {
    final List<Edicion> l = <Edicion>[
      libro('nuevo'),
      libro('leyendo'),
      libro('acabado'),
      libro('bajado', ruta: '/x'),
      libro('propio', origen: 'telefono', ruta: '/y'),
    ];
    final Map<String, (double, String)> avance = <String, (double, String)>{
      'leyendo': (0.4, '2026-01-02'),
      'acabado': (0.99, '2026-01-01'),
    };
    List<String> ids(Filtro f) => filtrarYOrdenar(
      l,
      avance,
      f,
      Orden.titulo,
    ).map((Edicion e) => e.id).toList();
    expect(ids(Filtro.enCurso), <String>['leyendo']);
    expect(ids(Filtro.terminados), <String>['acabado']);
    expect(ids(Filtro.descargados), <String>['bajado']);
    expect(ids(Filtro.telefono), <String>['propio']);
    expect(ids(Filtro.sinEmpezar), <String>['bajado', 'nuevo', 'propio']);
  });

  test('un libro largo apenas empezado ya está en Leyendo', () {
    final List<Edicion> r = filtrarYOrdenar(
      <Edicion>[libro('largo'), libro('nuevo')],
      <String, (double, String)>{'largo': (0.0035, '2026-01-01')},
      Filtro.enCurso,
      Orden.titulo,
    );
    expect(r.map((Edicion e) => e.id), <String>['largo']);
  });

  test('leídos recientemente pone primero lo último que se leyó', () {
    final List<Edicion> r = filtrarYOrdenar(
      <Edicion>[libro('a'), libro('b')],
      <String, (double, String)>{
        'a': (0.1, '2026-01-01'),
        'b': (0.1, '2026-02-01'),
      },
      Filtro.todos,
      Orden.leidos,
    );
    expect(r.first.id, 'b');
  });
}
