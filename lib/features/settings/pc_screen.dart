import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/sub_header.dart';
import '../sync/application/sync_controller.dart';
import '../sync/data/sync_repository.dart';
import 'ajustes_comunes.dart';

final StreamProvider<String?> _ultima = StreamProvider<String?>(
  (Ref ref) =>
      ref.watch(databaseProvider).vigilarAjuste(SyncRepository.kUltima),
);

/// NB Books en el PC: estado de la conexión, sincronizar, qué llega y
/// desvincular.
class PcScreen extends ConsumerWidget {
  const PcScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final EstadoSync s = ref.watch(syncProvider);
    final (Color color, IconData icono, String estado) = estadoDelPc(c, s);
    final String? ultima = ref.watch(_ultima).value;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            SubHeader(title: tr('NB Books en el PC')),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: c.bg2,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(icono, color: color),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            estado,
                            style: TextStyle(
                              fontFamily: NbFonts.display,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: c.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (s.pc != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '${s.pc!.host}:${s.pc!.port}',
                        style: TextStyle(color: c.text3, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      ultima == null
                          ? tr('Todavía no se ha sincronizado.')
                          : tr(
                              'Última sincronización: {cuando}',
                              <String, Object?>{'cuando': haceCuanto(ultima)},
                            ),
                      style: TextStyle(color: c.text3, fontSize: 13),
                    ),
                    if (s.ultimo != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        tr(
                          'Llegaron {r} cambios y subieron {e}.',
                          <String, Object?>{
                            'r': s.ultimo!.recibidos,
                            'e': s.ultimo!.enviados,
                          },
                        ),
                        style: TextStyle(color: c.text3, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: s.sincronizando || s.pc == null
                          ? null
                          : () => ref.read(syncProvider.notifier).sincronizar(),
                      icon: s.sincronizando
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(AppIcons.sync),
                      label: Text(tr('Sincronizar ahora')),
                    ),
                  ],
                ),
              ),
            ),
            FilaAjuste(
              icono: AppIcons.select,
              titulo: tr('Elegir libros'),
              subtitulo: tr('Colecciones, autores, series, materias o todo'),
              alPulsar: () => context.push('/seleccion'),
            ),
            FilaAjuste(
              icono: AppIcons.remote,
              titulo: tr('Leer en el PC'),
              subtitulo: tr('El teléfono como mando del lector del PC'),
              alPulsar: () => context.push('/mando'),
            ),
            FilaAjuste(
              icono: AppIcons.qr,
              titulo: tr('Emparejar con otro PC'),
              subtitulo: tr('Sustituye al PC actual'),
              alPulsar: () => context.push('/emparejar'),
            ),
            FilaAjuste(
              icono: AppIcons.close,
              titulo: tr('Desvincular'),
              subtitulo: tr(
                'Lo descargado y lo anotado se quedan en el teléfono.',
              ),
              peligro: true,
              alPulsar: () async {
                final bool? si = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext ctx) => AlertDialog(
                    title: Text(tr('¿Desvincular el PC?')),
                    content: Text(
                      tr(
                        'Para volver a sincronizar tendrás que emparejar otra vez.',
                      ),
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(tr('Cancelar')),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(tr('Desvincular')),
                      ),
                    ],
                  ),
                );
                if (si == true) {
                  await ref.read(syncProvider.notifier).desvincular();
                  if (context.mounted) {
                    context.pop();
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "hace 5 min", "hace 2 h", "ayer"… para un instante ISO.
String haceCuanto(String iso, {DateTime? ahora}) {
  final DateTime? t = DateTime.tryParse(iso);
  if (t == null) {
    return '';
  }
  final Duration d = (ahora ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) {
    return tr('ahora mismo');
  }
  if (d.inMinutes < 60) {
    return tr('hace {n} min', <String, Object?>{'n': d.inMinutes});
  }
  if (d.inHours < 24) {
    return tr('hace {n} h', <String, Object?>{'n': d.inHours});
  }
  if (d.inDays == 1) {
    return tr('ayer');
  }
  return tr('hace {n} días', <String, Object?>{'n': d.inDays});
}
