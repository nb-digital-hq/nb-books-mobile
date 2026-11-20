import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../core/i18n/idioma_controller.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/sheet.dart';
import '../../shared/widgets/sub_header.dart';
import '../library/application/biblioteca.dart';
import '../library/application/fotos_de_autores.dart';
import '../reader/presentation/ajustes_de_lectura_sheet.dart';
import 'ajustes_comunes.dart';

/// Configuración: cómo se ve la app, cómo se leen los libros y qué se enseña.
class ConfiguracionScreen extends ConsumerWidget {
  const ConfiguracionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final bool ocultar = ref.watch(ocultarTelefonoProvider).value ?? false;
    final bool fotos = ref.watch(fotosDeAutoresActivasProvider).value ?? false;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            SubHeader(title: tr('Configuración')),
            EtiquetaDeSeccion(tr('Apariencia')),
            FilaAjuste(
              icono: AppIcons.palette,
              titulo: tr('Temas'),
              subtitulo: tr(
                nbThemeByKey(ref.watch(themeControllerProvider)).label,
              ),
              alPulsar: () => context.push('/temas'),
            ),
            FilaAjuste(
              icono: AppIcons.globe,
              titulo: tr('Idioma'),
              subtitulo: nombreDelIdioma(ref.watch(idiomaControllerProvider)),
              alPulsar: () => _elegirIdioma(context, ref),
            ),
            EtiquetaDeSeccion(tr('Lectura')),
            FilaAjuste(
              icono: AppIcons.typography,
              titulo: tr('Ajustes de lectura'),
              subtitulo: tr(
                'Letra, márgenes, fondo y cómo se pasan las páginas',
              ),
              alPulsar: () => mostrarAjustesDeLectura(context),
            ),
            EtiquetaDeSeccion(tr('Biblioteca')),
            FilaAjuste(
              icono: AppIcons.hide,
              titulo: tr('Ocultar los libros del teléfono'),
              subtitulo: tr('Solo se ven los que llegan del PC.'),
              alPulsar: () => _ocultar(ref, !ocultar),
              final_: Switch(
                value: ocultar,
                onChanged: (bool v) => _ocultar(ref, v),
              ),
            ),
            FilaAjuste(
              icono: AppIcons.author,
              titulo: tr('Fotos de autores'),
              subtitulo: tr(
                'Se buscan en Wikimedia con el nombre de cada autor y se guardan solo en el teléfono.',
              ),
              alPulsar: () => _fotos(ref, !fotos),
              final_: Switch(
                value: fotos,
                onChanged: (bool v) => _fotos(ref, v),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _ocultar(WidgetRef ref, bool v) =>
      ref.read(databaseProvider).fijarAjuste(kOcultarTelefono, v ? '1' : '0');

  Future<void> _fotos(WidgetRef ref, bool v) =>
      ref.read(fotosDeAutoresProvider.notifier).activar(v);
}

/// El nombre de cada idioma en su propio idioma, para que quien no entiende el
/// actual reconozca el suyo.
String nombreDelIdioma(Idioma i) => switch (i) {
  Idioma.sistema => tr('El del sistema'),
  Idioma.es => 'Español',
  Idioma.en => 'English',
  Idioma.pt => 'Português',
};

Future<void> _elegirIdioma(BuildContext context, WidgetRef ref) async {
  final Idioma actual = ref.read(idiomaControllerProvider);
  final Idioma? elegido = await mostrarHojaMenu<Idioma>(
    context,
    builder: (BuildContext ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final Idioma i in Idioma.values)
          ListTile(
            title: Text(nombreDelIdioma(i)),
            trailing: i == actual ? const Icon(AppIcons.check) : null,
            onTap: () => Navigator.of(ctx).pop(i),
          ),
      ],
    ),
  );
  if (elegido != null && elegido != actual) {
    ref.read(idiomaControllerProvider.notifier).elegir(elegido);
  }
}
