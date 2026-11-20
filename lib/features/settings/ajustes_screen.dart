import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plataforma.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/sub_header.dart';
import '../profile/perfil.dart';
import '../sync/application/sync_controller.dart';
import 'ajustes_comunes.dart';

/// Ajustes: la tarjeta de la persona (abre su perfil) y los accesos a todo lo
/// demás. Cada acceso dice en su subtítulo lo que hay detrás.
class AjustesScreen extends ConsumerWidget {
  const AjustesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final EstadoSync sync = ref.watch(syncProvider);
    final String nombre = ref.watch(nombrePerfilProvider).value ?? '';
    final ImageProvider? foto = ref.watch(fotoPerfilProvider).value;
    final Estadisticas e = ref.watch(estadisticasProvider);
    final (Color color, IconData icono, String estado) = estadoDelPc(c, sync);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            SubHeader(title: tr('Ajustes')),
            InkWell(
              onTap: () => context.push('/perfil'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
                child: Row(
                  children: <Widget>[
                    Avatar(
                      foto: foto,
                      inicial: ref.watch(inicialPerfilProvider),
                      lado: 64,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            nombre.isEmpty ? tr('Tu perfil') : nombre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: NbFonts.display,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: c.text,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: <Widget>[
                              Icon(icono, size: 13, color: color),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  estado,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: NbFonts.ui,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: color,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(AppIcons.chevronRight, color: c.text3, size: 20),
                  ],
                ),
              ),
            ),
            // El resumen de lectura de un vistazo; el detalle está en el perfil.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    MiniDato(
                      valor: duracionLegible(e.minutosSemana),
                      etiqueta: tr('esta semana'),
                    ),
                    const SizedBox(width: 10),
                    MiniDato(
                      valor: '${e.racha}',
                      etiqueta: tr('días seguidos'),
                    ),
                    const SizedBox(width: 10),
                    MiniDato(
                      valor: '${e.terminados}',
                      etiqueta: tr('terminados'),
                    ),
                  ],
                ),
              ),
            ),
            FilaAjuste(
              icono: AppIcons.laptop,
              titulo: tr('NB Books en el PC'),
              subtitulo: sync.pc == null
                  ? tr('Emparejar, elegir libros y sincronizar')
                  : tr('{pc} · elegir libros y sincronizar', <String, Object?>{
                      'pc': sync.pc!.nombre,
                    }),
              alPulsar: () =>
                  context.push(sync.pc == null ? '/emparejar' : '/pc'),
            ),
            if (sync.pc != null)
              FilaAjuste(
                icono: AppIcons.remote,
                titulo: tr('Leer en el PC'),
                subtitulo: tr('El teléfono como mando del lector del PC'),
                alPulsar: () => context.push('/mando'),
              ),
            FilaAjuste(
              icono: AppIcons.storage,
              titulo: tr('Descargas y espacio'),
              subtitulo: tr('Lo que ocupa cada libro y la caché de lectura'),
              alPulsar: () => context.push('/almacenamiento'),
            ),
            FilaAjuste(
              icono: AppIcons.sliders,
              titulo: tr('Configuración'),
              subtitulo: tr('Temas, idioma, lectura y biblioteca'),
              alPulsar: () => context.push('/configuracion'),
            ),
            FilaAjuste(
              icono: AppIcons.info,
              titulo: tr('Acerca de'),
              subtitulo: esAndroid
                  ? tr('Versión y actualizaciones')
                  : tr('Versión y código fuente'),
              alPulsar: () => context.push('/acerca'),
            ),
          ],
        ),
      ),
    );
  }
}
