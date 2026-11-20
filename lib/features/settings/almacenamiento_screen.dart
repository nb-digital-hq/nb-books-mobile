import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/i18n.dart';
import '../../data/db/database.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/portada.dart';
import '../../shared/widgets/sub_header.dart';
import '../library/application/biblioteca.dart';
import '../profile/perfil.dart';
import '../sync/application/sync_controller.dart';
import 'ajustes_comunes.dart';

/// Descargas y espacio: cuánto ocupa cada libro en el teléfono, y la caché de
/// leer sin descargar.
class AlmacenamientoScreen extends ConsumerStatefulWidget {
  const AlmacenamientoScreen({super.key});

  @override
  ConsumerState<AlmacenamientoScreen> createState() =>
      _AlmacenamientoScreenState();
}

class _AlmacenamientoScreenState extends ConsumerState<AlmacenamientoScreen> {
  int _bytes(Edicion e) {
    try {
      return File(e.ruta!).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final List<Edicion> en =
        (ref.watch(edicionesProvider).value ?? const <Edicion>[])
            .where((Edicion e) => e.ruta != null)
            .toList();
    final Map<String, int> tam = <String, int>{
      for (final Edicion e in en) e.id: _bytes(e),
    };
    en.sort((Edicion a, Edicion b) => tam[b.id]!.compareTo(tam[a.id]!));
    final int delPc = en
        .where((Edicion e) => e.origen == 'pc')
        .fold<int>(0, (int t, Edicion e) => t + tam[e.id]!);
    final int delTelefono = en
        .where((Edicion e) => e.origen == 'telefono')
        .fold<int>(0, (int t, Edicion e) => t + tam[e.id]!);
    final int cache = ref.read(syncRepositoryProvider).bytesTemporales();
    final int total = delPc + delTelefono + cache;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            SubHeader(title: tr('Descargas y espacio')),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
              child: Text(
                bytesLegibles(total),
                style: TextStyle(
                  fontFamily: NbFonts.display,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: _Barra(
                partes: <(int, Color)>[
                  (delPc, c.accent),
                  (delTelefono, c.accent.withValues(alpha: 0.55)),
                  (cache, c.text3),
                ],
              ),
            ),
            _Leyenda(
              color: c.accent,
              texto: tr('Descargados del PC'),
              bytes: delPc,
            ),
            _Leyenda(
              color: c.accent.withValues(alpha: 0.55),
              texto: tr('Libros del teléfono'),
              bytes: delTelefono,
            ),
            _Leyenda(
              color: c.text3,
              texto: tr('Caché de leer sin descargar'),
              bytes: cache,
            ),
            const SizedBox(height: 8),
            FilaAjuste(
              icono: AppIcons.trash,
              titulo: tr('Vaciar la caché de lectura'),
              subtitulo: tr('Se vuelve a traer del PC al abrir el libro'),
              alPulsar: cache == 0
                  ? null
                  : () {
                      ref.read(syncRepositoryProvider).vaciarTemporales();
                      setState(() {});
                    },
            ),
            EtiquetaDeSeccion(tr('En el teléfono')),
            if (en.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  tr('No hay libros descargados. Descarga uno desde su ficha.'),
                  style: TextStyle(color: c.text2),
                ),
              ),
            for (final Edicion e in en)
              ListTile(
                onTap: () => context.push('/libro/${e.id}'),
                leading: SizedBox(
                  width: 36,
                  child: Portada(
                    titulo: e.titulo,
                    ruta: e.rutaPortada,
                    radio: 3,
                  ),
                ),
                title: Text(
                  e.titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${bytesLegibles(tam[e.id]!)} · '
                  '${e.origen == 'telefono' ? tr('del teléfono') : autoresDe(e)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: e.origen == 'pc'
                    ? IconButton(
                        tooltip: tr('Quitar del teléfono'),
                        icon: const Icon(AppIcons.downloadOff),
                        onPressed: () =>
                            ref.read(syncRepositoryProvider).quitarDescarga(e),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _Barra extends StatelessWidget {
  const _Barra({required this.partes});
  final List<(int, Color)> partes;

  @override
  Widget build(BuildContext context) {
    final int total = partes.fold<int>(0, (int t, (int, Color) p) => t + p.$1);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 12,
        color: context.nb.line,
        child: total == 0
            ? null
            : LayoutBuilder(
                builder: (BuildContext ctx, BoxConstraints box) => Row(
                  children: <Widget>[
                    for (final (int b, Color c) in partes)
                      if (b > 0)
                        Container(
                          width: (box.maxWidth * b / total).clamp(
                            2.0,
                            box.maxWidth,
                          ),
                          color: c,
                        ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _Leyenda extends StatelessWidget {
  const _Leyenda({
    required this.color,
    required this.texto,
    required this.bytes,
  });
  final Color color;
  final String texto;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(texto, style: TextStyle(color: c.text2)),
          ),
          Text(
            bytesLegibles(bytes),
            style: TextStyle(color: c.text, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
