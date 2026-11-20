import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../sync/application/sync_controller.dart';

/// Una fila de ajustes con icono, título, subtítulo y flecha.
class FilaAjuste extends StatelessWidget {
  const FilaAjuste({
    super.key,
    required this.icono,
    required this.titulo,
    this.subtitulo,
    this.alPulsar,
    this.final_,
    this.peligro = false,
  });

  final IconData icono;
  final String titulo;
  final String? subtitulo;
  final VoidCallback? alPulsar;

  /// Lo que va a la derecha en lugar de la flecha.
  final Widget? final_;
  final bool peligro;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final Color color = peligro ? const Color(0xFFE5484D) : c.text;
    return ListTile(
      onTap: alPulsar,
      leading: Icon(icono, color: peligro ? color : c.text2, size: 22),
      title: Text(
        titulo,
        style: TextStyle(
          fontFamily: NbFonts.ui,
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      subtitle: subtitulo == null
          ? null
          : Text(
              subtitulo!,
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontSize: 12.5,
                color: c.text3,
              ),
            ),
      trailing:
          final_ ??
          (alPulsar == null
              ? null
              : Icon(AppIcons.chevronRight, color: c.text3, size: 20)),
    );
  }
}

/// La etiqueta de una sección de ajustes.
class EtiquetaDeSeccion extends StatelessWidget {
  const EtiquetaDeSeccion(this.texto, {super.key});
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
    child: Text(
      texto.toUpperCase(),
      style: TextStyle(
        fontFamily: NbFonts.ui,
        fontSize: 11.5,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w700,
        color: context.nb.text3,
      ),
    ),
  );
}

/// El avatar de la persona: su foto o su inicial.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.foto,
    required this.inicial,
    required this.lado,
  });
  final ImageProvider? foto;
  final String inicial;
  final double lado;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Container(
      width: lado,
      height: lado,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.soft,
        shape: BoxShape.circle,
        border: Border.all(color: c.line2, width: 1.5),
        image: foto == null
            ? null
            : DecorationImage(image: foto!, fit: BoxFit.cover),
      ),
      child: foto != null
          ? null
          : Text(
              inicial,
              style: TextStyle(
                fontFamily: NbFonts.display,
                fontSize: lado * 0.4,
                fontWeight: FontWeight.w800,
                color: c.accent,
              ),
            ),
    );
  }
}

/// Un dato pequeño en una tarjeta: el número arriba, qué es debajo.
class MiniDato extends StatelessWidget {
  const MiniDato({
    super.key,
    required this.valor,
    required this.etiqueta,
    this.icono,
  });
  final String valor;
  final String etiqueta;
  final IconData? icono;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (icono != null) ...<Widget>[
              Icon(icono, color: c.accent, size: 18),
              const SizedBox(height: 10),
            ],
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                valor,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: NbFonts.display,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              etiqueta,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cómo está la relación con el PC, con su color e icono.
(Color, IconData, String) estadoDelPc(NbColors c, EstadoSync s) {
  if (s.pc == null) {
    return (c.text3, AppIcons.laptop, tr('Sin PC emparejado'));
  }
  if (s.sincronizando) {
    return (c.accent, AppIcons.sync, tr('Sincronizando…'));
  }
  if (s.conectado) {
    return (
      const Color(0xFF3DDC84),
      AppIcons.wifi,
      tr('Conectado a {pc}', <String, Object?>{'pc': s.pc!.nombre}),
    );
  }
  return (
    const Color(0xFFFFA502),
    AppIcons.laptop,
    tr('{pc} · sin conexión ahora', <String, Object?>{'pc': s.pc!.nombre}),
  );
}
