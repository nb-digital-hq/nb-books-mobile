import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/i18n.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../application/ajustes_de_lectura.dart';

/// Tipografía, márgenes y fondo del libro, con vista previa en el propio libro.
Future<void> mostrarAjustesDeLectura(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => const _Hoja(),
    );

class _Hoja extends ConsumerWidget {
  const _Hoja();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AjustesDeLectura a = ref.watch(ajustesDeLecturaProvider);
    final AjustesDeLecturaController c = ref.read(
      ajustesDeLecturaProvider.notifier,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              tr('Ajustes del libro'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                for (final FondoDeLectura f in FondoDeLectura.values)
                  _Muestra(
                    fondo: f,
                    activo: f == a.fondo,
                    alPulsar: () => c.fijar(a.con(fondo: f)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _Deslizador(
              etiqueta: tr('Tamaño de letra'),
              valor: a.tamano,
              min: 12,
              max: 32,
              pasos: 20,
              alCambiar: (double v) => c.fijar(a.con(tamano: v)),
            ),
            _Deslizador(
              etiqueta: tr('Interlineado'),
              valor: a.interlineado,
              min: 1.2,
              max: 2.2,
              pasos: 10,
              alCambiar: (double v) => c.fijar(a.con(interlineado: v)),
            ),
            _Deslizador(
              etiqueta: tr('Márgenes'),
              valor: a.margen,
              min: 8,
              max: 48,
              pasos: 10,
              alCambiar: (double v) => c.fijar(a.con(margen: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Letra con remates')),
              value: a.serif,
              onChanged: (bool v) => c.fijar(a.con(serif: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Justificar el texto')),
              value: a.justificar,
              onChanged: (bool v) => c.fijar(a.con(justificar: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Pasar páginas')),
              subtitle: Text(tr('Apagado, el capítulo se desplaza seguido.')),
              value: a.paginado,
              onChanged: (bool v) => c.fijar(a.con(paginado: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Deslizador extends StatelessWidget {
  const _Deslizador({
    required this.etiqueta,
    required this.valor,
    required this.min,
    required this.max,
    required this.pasos,
    required this.alCambiar,
  });

  final String etiqueta;
  final double valor;
  final double min;
  final double max;
  final int pasos;
  final ValueChanged<double> alCambiar;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      SizedBox(width: 120, child: Text(etiqueta)),
      Expanded(
        child: Slider(
          value: valor.clamp(min, max),
          min: min,
          max: max,
          divisions: pasos,
          onChanged: alCambiar,
        ),
      ),
    ],
  );
}

/// Un fondo de lectura como se verá: el color de la página con su letra.
class _Muestra extends ConsumerWidget {
  const _Muestra({
    required this.fondo,
    required this.activo,
    required this.alPulsar,
  });
  final FondoDeLectura fondo;
  final bool activo;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final (Color papel, Color tinta) = ref
        .watch(ajustesDeLecturaProvider)
        .con(fondo: fondo)
        .colores(c.bg, c.text);
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: alPulsar,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: papel,
                shape: BoxShape.circle,
                border: Border.all(
                  color: activo ? c.accent : c.line2,
                  width: activo ? 3 : 1,
                ),
              ),
              child: Text(
                'Aa',
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: tinta,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              nombreDelFondo(fondo),
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontSize: 12,
                fontWeight: activo ? FontWeight.w800 : FontWeight.w500,
                color: activo ? c.text : c.text2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
