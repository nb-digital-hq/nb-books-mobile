import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../data/db/database.dart';
import '../library/application/biblioteca.dart';

const String kNombrePerfil = 'perfil_nombre';
const String kFotoPerfil = 'perfil_foto';

/// El nombre que la persona se puso en el teléfono. Es solo del teléfono: no
/// viaja al PC.
final StreamProvider<String> nombrePerfilProvider = StreamProvider<String>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kNombrePerfil)
      .map((String? v) => (v ?? '').trim()),
);

/// La foto de perfil, copiada en la carpeta de la app, o null.
final StreamProvider<ImageProvider?> fotoPerfilProvider =
    StreamProvider<ImageProvider?>(
      (Ref ref) => ref.watch(databaseProvider).vigilarAjuste(kFotoPerfil).map((
        String? v,
      ) {
        if (v == null || v.isEmpty) {
          return null;
        }
        final File f = File(v);
        return f.existsSync() ? FileImage(f) : null;
      }),
    );

/// La inicial del avatar: la del nombre, o la de NB Books.
final Provider<String> inicialPerfilProvider = Provider<String>((Ref ref) {
  final String n = ref.watch(nombrePerfilProvider).value ?? '';
  return n.isEmpty ? 'B' : n.characters.first.toUpperCase();
});

/// Lo que la persona ha leído, contado en el teléfono. Todo sale de lo que ya
/// está en la base: posiciones, sesiones y anotaciones de los dos dispositivos.
@immutable
class Estadisticas {
  const Estadisticas({
    required this.libros,
    required this.descargados,
    required this.leyendo,
    required this.terminados,
    required this.anotaciones,
    required this.minutos,
    required this.minutosSemana,
    required this.racha,
    required this.diasSemana,
  });

  final int libros;
  final int descargados;
  final int leyendo;
  final int terminados;
  final int anotaciones;
  final int minutos;
  final int minutosSemana;

  /// Días seguidos con lectura, hasta hoy o ayer.
  final int racha;

  /// Minutos leídos cada uno de los últimos 7 días, de hace 6 días a hoy.
  final List<int> diasSemana;
}

/// Un libro se da por terminado al pasar del 98 %: el resto suelen ser notas y
/// colofón.
const double kTerminado = 0.98;

Estadisticas calcularEstadisticas({
  required List<Edicion> ediciones,
  required List<Posicion> posiciones,
  required List<Sesion> sesiones,
  required List<Anotacion> anotaciones,
  DateTime? ahora,
}) {
  final DateTime hoy = DateUtils.dateOnly((ahora ?? DateTime.now()).toLocal());
  final Map<String, double> avance = <String, double>{};
  for (final Posicion p in posiciones) {
    final double v = p.progresion ?? progresionDe(p.locator) ?? 0;
    if (v > (avance[p.edicion] ?? -1)) {
      avance[p.edicion] = v;
    }
  }
  // Se cuenta en segundos: unas páginas antes de dormir son lectura y cuentan
  // para la racha aunque no lleguen al minuto.
  final Map<DateTime, int> porDia = <DateTime, int>{};
  int segundos = 0;
  for (final Sesion s in sesiones) {
    final DateTime? i = DateTime.tryParse(s.inicio);
    final DateTime? f = s.fin == null ? null : DateTime.tryParse(s.fin!);
    if (i == null || f == null || !f.isAfter(i)) {
      continue;
    }
    // Una sesión olvidada abierta no cuenta como una tarde entera.
    final int seg = f.difference(i).inSeconds.clamp(0, 180 * 60);
    segundos += seg;
    final DateTime d = DateUtils.dateOnly(i.toLocal());
    porDia[d] = (porDia[d] ?? 0) + seg;
  }
  final List<int> semana = <int>[
    for (int k = 6; k >= 0; k--)
      ((porDia[hoy.subtract(Duration(days: k))] ?? 0) / 60).round(),
  ];
  int racha = 0;
  DateTime d = (porDia[hoy] ?? 0) > 0
      ? hoy
      : hoy.subtract(const Duration(days: 1));
  while ((porDia[d] ?? 0) > 0) {
    racha++;
    d = d.subtract(const Duration(days: 1));
  }
  final int minutos = (segundos / 60).round();
  return Estadisticas(
    libros: ediciones.length,
    descargados: ediciones.where((Edicion e) => e.ruta != null).length,
    leyendo: avance.values.where((double v) => v < kTerminado).length,
    terminados: avance.values.where((double v) => v >= kTerminado).length,
    anotaciones: anotaciones
        .where((Anotacion a) => a.tipo != 'bookmark')
        .length,
    minutos: minutos,
    minutosSemana: semana.fold<int>(0, (int a, int b) => a + b),
    racha: racha,
    diasSemana: semana,
  );
}

final StreamProvider<List<Sesion>> sesionesProvider =
    StreamProvider<List<Sesion>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarSesiones(),
    );

final StreamProvider<List<Anotacion>> todasLasAnotacionesProvider =
    StreamProvider<List<Anotacion>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarTodasLasAnotaciones(),
    );

final Provider<Estadisticas> estadisticasProvider = Provider<Estadisticas>(
  (Ref ref) => calcularEstadisticas(
    ediciones: ref.watch(edicionesProvider).value ?? const <Edicion>[],
    posiciones: ref.watch(posicionesProvider).value ?? const <Posicion>[],
    sesiones: ref.watch(sesionesProvider).value ?? const <Sesion>[],
    anotaciones:
        ref.watch(todasLasAnotacionesProvider).value ?? const <Anotacion>[],
  ),
);

/// Tiempo leído para enseñarlo: "45 min", "3 h 20 min".
String duracionLegible(int minutos) {
  if (minutos < 60) {
    return tr('{n} min', <String, Object?>{'n': minutos});
  }
  final int h = minutos ~/ 60;
  final int m = minutos % 60;
  return m == 0
      ? tr('{h} h', <String, Object?>{'h': h})
      : tr('{h} h {m} min', <String, Object?>{'h': h, 'm': m});
}

/// Bytes para enseñarlos.
String bytesLegibles(int b) {
  if (b < 1024) {
    return '$b B';
  }
  const List<String> u = <String>['KB', 'MB', 'GB', 'TB'];
  double v = b / 1024;
  int i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${u[i]}';
}
