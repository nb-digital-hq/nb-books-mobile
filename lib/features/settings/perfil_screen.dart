import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../data/db/database.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/sub_header.dart';
import '../profile/perfil.dart';
import '../sync/application/sync_controller.dart';
import 'ajustes_comunes.dart';

/// El perfil: foto, nombre y lo leído. El nombre y la foto son del teléfono y
/// no viajan al PC.
class PerfilScreen extends ConsumerWidget {
  const PerfilScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final String nombre = ref.watch(nombrePerfilProvider).value ?? '';
    final ImageProvider? foto = ref.watch(fotoPerfilProvider).value;
    final Estadisticas e = ref.watch(estadisticasProvider);
    final (Color color, _, String estado) = estadoDelPc(
      c,
      ref.watch(syncProvider),
    );

    Widget fila(Widget a, Widget b) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: Row(children: <Widget>[a, const SizedBox(width: 10), b]),
    );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            SubHeader(title: tr('Perfil')),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
              child: Column(
                children: <Widget>[
                  GestureDetector(
                    onTap: () => _menuFoto(context, ref, foto != null),
                    child: Stack(
                      children: <Widget>[
                        Avatar(
                          foto: foto,
                          inicial: ref.watch(inicialPerfilProvider),
                          lado: 96,
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: c.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.bg, width: 2),
                            ),
                            child: Icon(AppIcons.edit, color: c.ink, size: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () => _editarNombre(context, ref, nombre),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            nombre.isEmpty ? tr('Ponte un nombre') : nombre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: NbFonts.display,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: nombre.isEmpty ? c.text3 : c.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(AppIcons.edit, color: c.text3, size: 18),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    estado,
                    style: TextStyle(
                      fontFamily: NbFonts.ui,
                      fontSize: 13,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: _Semana(e: e),
            ),
            fila(
              MiniDato(
                icono: AppIcons.timer,
                valor: duracionLegible(e.minutos),
                etiqueta: tr('leyendo en total'),
              ),
              MiniDato(
                icono: AppIcons.streak,
                valor: '${e.racha}',
                etiqueta: tr('días seguidos'),
              ),
            ),
            fila(
              MiniDato(
                icono: AppIcons.read,
                valor: '${e.leyendo}',
                etiqueta: tr('leyendo ahora'),
              ),
              MiniDato(
                icono: AppIcons.done,
                valor: '${e.terminados}',
                etiqueta: tr('terminados'),
              ),
            ),
            fila(
              MiniDato(
                icono: AppIcons.library,
                valor: '${e.libros}',
                etiqueta: tr('en tu biblioteca'),
              ),
              MiniDato(
                icono: AppIcons.highlight,
                valor: '${e.anotaciones}',
                etiqueta: tr('anotaciones'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editarNombre(
    BuildContext context,
    WidgetRef ref,
    String actual,
  ) async {
    final TextEditingController ctrl = TextEditingController(text: actual);
    final String? nuevo = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(tr('Tu nombre')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: tr('Escribe tu nombre')),
          onSubmitted: (String v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancelar')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Guardar')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (nuevo != null) {
      await ref.read(databaseProvider).fijarAjuste(kNombrePerfil, nuevo);
    }
  }

  Future<void> _menuFoto(
    BuildContext context,
    WidgetRef ref,
    bool tieneFoto,
  ) async {
    final String? accion = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(AppIcons.image),
              title: Text(tr('Elegir una foto')),
              onTap: () => Navigator.pop(ctx, 'elegir'),
            ),
            if (tieneFoto)
              ListTile(
                leading: const Icon(AppIcons.trash, color: Color(0xFFE5484D)),
                title: Text(
                  tr('Quitar la foto'),
                  style: const TextStyle(color: Color(0xFFE5484D)),
                ),
                onTap: () => Navigator.pop(ctx, 'quitar'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    final AppDatabase db = ref.read(databaseProvider);
    final String? previa = await db.ajuste(kFotoPerfil);
    if (accion == 'quitar') {
      await db.fijarAjuste(kFotoPerfil, '');
      _borrar(previa);
      return;
    }
    if (accion != 'elegir') {
      return;
    }
    try {
      final List<PlatformFile> r = await FilePicker.pickFiles(
        type: FileType.image,
      );
      final String? origen = r.isEmpty ? null : r.single.path;
      if (origen == null) {
        return;
      }
      // Se copia a la carpeta de la app: la del selector es temporal. El
      // nombre cambia en cada foto para que la imagen no salga de la caché.
      final String destino =
          '${ref.read(documentosProvider).path}/perfil-'
          '${DateTime.now().millisecondsSinceEpoch}';
      await File(origen).copy(destino);
      await db.fijarAjuste(kFotoPerfil, destino);
      _borrar(previa);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('No se pudo usar esa imagen.'))),
        );
      }
    }
  }

  void _borrar(String? ruta) {
    if (ruta == null || ruta.isEmpty) {
      return;
    }
    try {
      File(ruta).deleteSync();
    } catch (_) {
      // Una foto que ya no está no impide nada.
    }
  }
}

/// La semana en barras: cuánto se leyó cada día.
class _Semana extends StatelessWidget {
  const _Semana({required this.e});
  final Estadisticas e;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final int maximo = e.diasSemana.fold<int>(
      1,
      (int a, int b) => b > a ? b : a,
    );
    final DateTime hoy = DateTime.now();
    final List<String> dias = <String>[
      tr('L'),
      tr('M'),
      tr('X'),
      tr('J'),
      tr('V'),
      tr('S'),
      tr('D'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: c.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                tr('Esta semana'),
                style: TextStyle(
                  fontFamily: NbFonts.ui,
                  fontWeight: FontWeight.w700,
                  color: c.text,
                ),
              ),
              const Spacer(),
              Text(
                duracionLegible(e.minutosSemana),
                style: TextStyle(
                  fontFamily: NbFonts.display,
                  fontWeight: FontWeight.w800,
                  color: c.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 74,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (int i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Container(
                          width: 18,
                          height: 4 + 48 * e.diasSemana[i] / maximo,
                          decoration: BoxDecoration(
                            color: e.diasSemana[i] > 0 ? c.accent : c.line,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          dias[hoy.subtract(Duration(days: 6 - i)).weekday - 1],
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == 6 ? FontWeight.w800 : null,
                            color: i == 6 ? c.text : c.text3,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
