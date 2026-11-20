import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../data/db/database.dart';

/// Qué parte de la biblioteca se ve.
enum Vista {
  /// Todo el catálogo del PC, en directo y sin copiarlo.
  todo,

  /// Lo elegido para el teléfono, descargado o no.
  seleccionado,

  /// Solo lo que se puede leer sin el PC.
  descargado,
}

const String kVista = 'biblioteca_vista';
const String kOcultarTelefono = 'ocultar_telefono';

/// La vista elegida, recordada entre aperturas.
final StreamProvider<Vista> vistaProvider = StreamProvider<Vista>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kVista)
      .map(
        (String? v) => Vista.values.firstWhere(
          (Vista x) => x.name == v,
          orElse: () => Vista.seleccionado,
        ),
      ),
);

/// Si los libros añadidos en el teléfono se esconden de la biblioteca.
final StreamProvider<bool> ocultarTelefonoProvider = StreamProvider<bool>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kOcultarTelefono)
      .map((String? v) => v == '1'),
);

final StreamProvider<List<Edicion>> edicionesProvider =
    StreamProvider<List<Edicion>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarEdiciones(),
    );

final StreamProvider<List<Posicion>> posicionesProvider =
    StreamProvider<List<Posicion>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarPosiciones(),
    );

/// Lo que se ve en la biblioteca local según la vista y el filtro del teléfono.
List<Edicion> filtrar(
  List<Edicion> todas,
  Vista vista, {
  required bool ocultarTelefono,
}) => <Edicion>[
  for (final Edicion e in todas)
    if (!(ocultarTelefono && e.origen == 'telefono') &&
        (vista != Vista.descargado || e.ruta != null))
      e,
];

/// Los nombres de autoría de una edición, unidos para enseñarlos.
String autoresDe(Edicion e) =>
    listaJson(e.autores).whereType<String>().join(', ');

/// Lo que falta para "Seguir leyendo": las ediciones con posición, la más
/// reciente primero, sea del teléfono o del PC.
List<(Edicion, Posicion)> seguirLeyendo(
  List<Edicion> ediciones,
  List<Posicion> posiciones,
) {
  final Map<String, Edicion> porId = <String, Edicion>{
    for (final Edicion e in ediciones) e.id: e,
  };
  final Map<String, Posicion> ultima = <String, Posicion>{};
  for (final Posicion p in posiciones) {
    final Posicion? previa = ultima[p.edicion];
    if (previa == null || p.actualizadoEn.compareTo(previa.actualizadoEn) > 0) {
      ultima[p.edicion] = p;
    }
  }
  final List<(Edicion, Posicion)> lista = <(Edicion, Posicion)>[
    for (final MapEntry<String, Posicion> m in ultima.entries)
      if (porId[m.key] != null) (porId[m.key]!, m.value),
  ];
  lista.sort(
    ((Edicion, Posicion) a, (Edicion, Posicion) b) =>
        b.$2.actualizadoEn.compareTo(a.$2.actualizadoEn),
  );
  return lista;
}

/// La progresión de 0 a 1 de un Locator guardado, si la trae.
double? progresionDe(String locator) {
  try {
    final Map<String, dynamic> l = jsonDecode(locator) as Map<String, dynamic>;
    return ((l['locations'] as Map<String, dynamic>?)?['totalProgression']
            as num?)
        ?.toDouble();
  } catch (_) {
    return null;
  }
}
