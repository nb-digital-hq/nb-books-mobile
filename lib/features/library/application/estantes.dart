import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../profile/perfil.dart';
import 'biblioteca.dart';

/// Cómo se agrupa la biblioteca en estanterías.
enum Estante { autor, serie, coleccion, materia }

extension NombreDelEstante on Estante {
  String get plural => switch (this) {
    Estante.autor => tr('Autores'),
    Estante.serie => tr('Series'),
    Estante.coleccion => tr('Colecciones'),
    Estante.materia => tr('Materias'),
  };
}

/// Una estantería: un autor, una serie, una colección o una materia, con sus
/// libros ya ordenados.
class Grupo {
  const Grupo(this.clave, this.nombre, this.libros);
  final String clave;
  final String nombre;
  final List<Edicion> libros;
}

/// Los grupos de un tipo de estante. Un libro con dos autores está en los dos.
/// Las series van por su número; el resto, por título.
List<Grupo> agrupar(
  List<Edicion> libros,
  Estante estante, {
  List<Coleccion> colecciones = const <Coleccion>[],
}) {
  final Map<String, (String, List<Edicion>)> g =
      <String, (String, List<Edicion>)>{};
  void meter(String clave, String nombre, Edicion e) {
    if (clave.trim().isEmpty) {
      return;
    }
    g.putIfAbsent(clave, () => (nombre, <Edicion>[])).$2.add(e);
  }

  switch (estante) {
    case Estante.autor:
      for (final Edicion e in libros) {
        for (final String a in listaJson(e.autores).whereType<String>()) {
          meter(a, a, e);
        }
      }
    case Estante.serie:
      for (final Edicion e in libros) {
        if (e.serie != null) {
          meter(e.serie!, e.serie!, e);
        }
      }
    case Estante.materia:
      for (final Edicion e in libros) {
        for (final dynamic m in listaJson(e.materias)) {
          final String? n = m is Map<String, dynamic>
              ? m['nombre'] as String?
              : m is String
              ? m
              : null;
          if (n != null) {
            meter(n, n, e);
          }
        }
      }
    case Estante.coleccion:
      final Map<String, Edicion> porId = <String, Edicion>{
        for (final Edicion e in libros) e.id: e,
      };
      for (final Coleccion c in colecciones) {
        for (final dynamic id in listaJson(c.ediciones)) {
          final Edicion? e = porId[id];
          if (e != null) {
            meter(c.id, c.nombre, e);
          }
        }
      }
  }
  final List<Grupo> salida = <Grupo>[
    for (final MapEntry<String, (String, List<Edicion>)> x in g.entries)
      Grupo(
        x.key,
        x.value.$1,
        x.value.$2..sort(
          estante == Estante.serie
              ? (Edicion a, Edicion b) =>
                    (a.indiceSerie ?? 1e9).compareTo(b.indiceSerie ?? 1e9)
              : (Edicion a, Edicion b) =>
                    normalizar(a.titulo).compareTo(normalizar(b.titulo)),
        ),
      ),
  ];
  salida.sort(
    (Grupo a, Grupo b) => normalizar(a.nombre).compareTo(normalizar(b.nombre)),
  );
  return salida;
}

/// Para ordenar como lo haría una persona: sin mayúsculas ni tildes.
String normalizar(String s) {
  const String con = 'áàäâéèëêíìïîóòöôúùüûñç';
  const String sin = 'aaaaeeeeiiiioooouuuunc';
  final StringBuffer b = StringBuffer();
  for (final int r in s.toLowerCase().runes) {
    final String ch = String.fromCharCode(r);
    final int i = con.indexOf(ch);
    b.write(i < 0 ? ch : sin[i]);
  }
  return b.toString();
}

/// Qué libros se ven en Biblioteca.
enum Filtro { todos, enCurso, sinEmpezar, terminados, descargados, telefono }

extension NombreDelFiltro on Filtro {
  String get nombre => switch (this) {
    Filtro.todos => tr('Todos'),
    Filtro.enCurso => tr('Leyendo'),
    Filtro.sinEmpezar => tr('Sin empezar'),
    Filtro.terminados => tr('Terminados'),
    Filtro.descargados => tr('Descargados'),
    Filtro.telefono => tr('Del teléfono'),
  };
}

/// En qué orden.
enum Orden { recientes, leidos, titulo, autor }

extension NombreDelOrden on Orden {
  String get nombre => switch (this) {
    Orden.recientes => tr('Añadidos recientemente'),
    Orden.leidos => tr('Leídos recientemente'),
    Orden.titulo => tr('Título'),
    Orden.autor => tr('Autor'),
  };
}

const String kFiltro = 'biblioteca_filtro';
const String kOrden = 'biblioteca_orden';
const String kRejilla = 'biblioteca_rejilla';

T _enum<T extends Enum>(List<T> valores, String? v, T porDefecto) =>
    valores.firstWhere((T x) => x.name == v, orElse: () => porDefecto);

final StreamProvider<Filtro> filtroProvider = StreamProvider<Filtro>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kFiltro)
      .map((String? v) => _enum(Filtro.values, v, Filtro.todos)),
);
final StreamProvider<Orden> ordenProvider = StreamProvider<Orden>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kOrden)
      .map((String? v) => _enum(Orden.values, v, Orden.recientes)),
);
final StreamProvider<bool> rejillaProvider = StreamProvider<bool>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kRejilla)
      .map((String? v) => v != '0'),
);
final StreamProvider<List<Coleccion>> coleccionesProvider =
    StreamProvider<List<Coleccion>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarColecciones(),
    );

/// Cuánto se ha leído de cada libro (lo más avanzado de los dos dispositivos)
/// y cuándo se leyó por última vez.
final Provider<Map<String, (double, String)>> avanceProvider =
    Provider<Map<String, (double, String)>>((Ref ref) {
      final Map<String, (double, String)> m = <String, (double, String)>{};
      for (final Posicion p
          in ref.watch(posicionesProvider).value ?? const <Posicion>[]) {
        final double v = p.progresion ?? progresionDe(p.locator) ?? 0;
        final (double, String)? previo = m[p.edicion];
        m[p.edicion] = (
          previo == null || v > previo.$1 ? v : previo.$1,
          previo == null || p.actualizadoEn.compareTo(previo.$2) > 0
              ? p.actualizadoEn
              : previo.$2,
        );
      }
      return m;
    });

/// Los libros que se ven, según el ocultar del teléfono.
final Provider<List<Edicion>> librosVisiblesProvider = Provider<List<Edicion>>((
  Ref ref,
) {
  final bool ocultar = ref.watch(ocultarTelefonoProvider).value ?? false;
  return <Edicion>[
    for (final Edicion e
        in ref.watch(edicionesProvider).value ?? const <Edicion>[])
      if (!(ocultar && e.origen == 'telefono')) e,
  ];
});

List<Edicion> filtrarYOrdenar(
  List<Edicion> libros,
  Map<String, (double, String)> avance,
  Filtro f,
  Orden o,
) {
  // Empezado es tener una posición, no pasar de un porcentaje: el primer
  // capítulo de un libro largo es menos del 1 % de su texto.
  bool pasa(Edicion e) {
    final bool empezado = avance.containsKey(e.id);
    final double v = avance[e.id]?.$1 ?? 0;
    return switch (f) {
      Filtro.todos => true,
      Filtro.enCurso => empezado && v < kTerminado,
      Filtro.sinEmpezar => !empezado,
      Filtro.terminados => v >= kTerminado,
      Filtro.descargados => e.ruta != null && e.origen == 'pc',
      Filtro.telefono => e.origen == 'telefono',
    };
  }

  final List<Edicion> l = libros.where(pasa).toList();
  switch (o) {
    case Orden.recientes:
      l.sort((Edicion a, Edicion b) => b.anadidaEn.compareTo(a.anadidaEn));
    case Orden.leidos:
      l.sort(
        (Edicion a, Edicion b) =>
            (avance[b.id]?.$2 ?? '').compareTo(avance[a.id]?.$2 ?? ''),
      );
    case Orden.titulo:
      l.sort(
        (Edicion a, Edicion b) =>
            normalizar(a.titulo).compareTo(normalizar(b.titulo)),
      );
    case Orden.autor:
      l.sort(
        (Edicion a, Edicion b) => normalizar(
          a.ordenAutor ?? autoresDe(a),
        ).compareTo(normalizar(b.ordenAutor ?? autoresDe(b))),
      );
  }
  return l;
}
