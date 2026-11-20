import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';

/// Los fondos del libro. `app` usa los colores del tema de la app.
enum FondoDeLectura { dia, sepia, noche, app }

String nombreDelFondo(FondoDeLectura f) => switch (f) {
  FondoDeLectura.dia => tr('Día'),
  FondoDeLectura.sepia => tr('Sepia'),
  FondoDeLectura.noche => tr('Noche'),
  FondoDeLectura.app => tr('Tema de la app'),
};

/// Cómo se compone el libro en el teléfono. Es del teléfono: no viaja al PC,
/// que tiene su propia pantalla y su propia distancia de lectura.
@immutable
class AjustesDeLectura {
  const AjustesDeLectura({
    this.tamano = 18,
    this.interlineado = 1.6,
    this.margen = 22,
    this.serif = true,
    this.justificar = false,
    this.paginado = true,
    this.fondo = FondoDeLectura.dia,
  });

  factory AjustesDeLectura.fromJson(Map<String, dynamic> j) => AjustesDeLectura(
    tamano: (j['tamano'] as num?)?.toDouble() ?? 18,
    interlineado: (j['interlineado'] as num?)?.toDouble() ?? 1.6,
    margen: (j['margen'] as num?)?.toDouble() ?? 22,
    serif: j['serif'] as bool? ?? true,
    justificar: j['justificar'] as bool? ?? false,
    paginado: j['paginado'] as bool? ?? true,
    fondo: FondoDeLectura.values.firstWhere(
      (FondoDeLectura f) => f.name == j['fondo'],
      orElse: () => FondoDeLectura.dia,
    ),
  );

  final double tamano;
  final double interlineado;
  final double margen;
  final bool serif;
  final bool justificar;
  final bool paginado;
  final FondoDeLectura fondo;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tamano': tamano,
    'interlineado': interlineado,
    'margen': margen,
    'serif': serif,
    'justificar': justificar,
    'paginado': paginado,
    'fondo': fondo.name,
  };

  AjustesDeLectura con({
    double? tamano,
    double? interlineado,
    double? margen,
    bool? serif,
    bool? justificar,
    bool? paginado,
    FondoDeLectura? fondo,
  }) => AjustesDeLectura(
    tamano: tamano ?? this.tamano,
    interlineado: interlineado ?? this.interlineado,
    margen: margen ?? this.margen,
    serif: serif ?? this.serif,
    justificar: justificar ?? this.justificar,
    paginado: paginado ?? this.paginado,
    fondo: fondo ?? this.fondo,
  );

  /// Fondo y texto del libro.
  (Color, Color) colores(Color fondoApp, Color textoApp) => switch (fondo) {
    FondoDeLectura.dia => (const Color(0xFFFFFDF8), const Color(0xFF1B1B1B)),
    FondoDeLectura.sepia => (const Color(0xFFF4ECD8), const Color(0xFF3B2F20)),
    FondoDeLectura.noche => (const Color(0xFF121212), const Color(0xFFD8D4CC)),
    FondoDeLectura.app => (fondoApp, textoApp),
  };
}

const String kAjustesDeLectura = 'lectura';

class AjustesDeLecturaController extends Notifier<AjustesDeLectura> {
  @override
  AjustesDeLectura build() {
    Future<void>(() async {
      final String? g = await ref
          .read(databaseProvider)
          .ajuste(kAjustesDeLectura);
      if (g != null) {
        try {
          state = AjustesDeLectura.fromJson(
            jsonDecode(g) as Map<String, dynamic>,
          );
        } catch (_) {
          // Un ajuste ilegible vuelve a los de fábrica.
        }
      }
    });
    return const AjustesDeLectura();
  }

  void fijar(AjustesDeLectura a) {
    state = a;
    ref
        .read(databaseProvider)
        .fijarAjuste(kAjustesDeLectura, jsonEncode(a.toJson()));
  }
}

final NotifierProvider<AjustesDeLecturaController, AjustesDeLectura>
ajustesDeLecturaProvider =
    NotifierProvider<AjustesDeLecturaController, AjustesDeLectura>(
      AjustesDeLecturaController.new,
    );

/// Color en `#rrggbb` para el CSS del libro.
String cssDe(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
