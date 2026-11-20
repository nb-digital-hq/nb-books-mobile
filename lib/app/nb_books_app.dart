import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/i18n/i18n.dart';
import '../core/i18n/idioma_controller.dart';
import '../core/router/app_router.dart';
import '../features/sync/application/sync_controller.dart';
import '../shared/theme/nb_theme.dart';
import '../shared/theme/theme_controller.dart';

/// El widget raíz: tema, idioma y router. Al volver a primer plano sincroniza,
/// que es cuando más probable es que el PC tenga algo nuevo.
class NbBooksApp extends ConsumerStatefulWidget {
  const NbBooksApp({super.key});

  @override
  ConsumerState<NbBooksApp> createState() => _NbBooksAppState();
}

class _NbBooksAppState extends ConsumerState<NbBooksApp> {
  AppLifecycleListener? _ciclo;

  @override
  void initState() {
    super.initState();
    _ciclo = AppLifecycleListener(
      onResume: () => ref.read(syncProvider.notifier).sincronizar(),
    );
  }

  @override
  void dispose() {
    _ciclo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String tema = ref.watch(themeControllerProvider);
    final Idioma preferido = ref.watch(idiomaControllerProvider);
    final Idioma idioma = idiomaActivo;
    final GoRouter router = ref.watch(appRouterProvider);
    ref.watch(syncProvider.select((EstadoSync s) => s.pc));
    return MaterialApp.router(
      // La clave por idioma reconstruye el árbol al cambiarlo: los textos se
      // resuelven con [tr] al construir, no se guardan en constantes.
      key: ValueKey<Idioma>(idioma),
      title: 'NB Books',
      locale: localeDe(idioma),
      supportedLocales: const <Locale>[
        Locale('es'),
        Locale('en'),
        Locale('pt'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      localeResolutionCallback: (Locale? l, Iterable<Locale> _) {
        if (preferido == Idioma.sistema && l != null) {
          fijarIdioma(Idioma.sistema, delSistema: l);
        }
        return localeDe(idiomaActivo);
      },
      debugShowCheckedModeBanner: false,
      theme: NbTheme.build(tema),
      routerConfig: router,
    );
  }
}
