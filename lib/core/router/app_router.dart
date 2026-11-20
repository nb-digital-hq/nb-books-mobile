import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_shell.dart';
import '../../app/tab_reselect.dart';
import '../../features/about/presentation/acerca_screen.dart';
import '../../features/library/presentation/biblioteca_screen.dart';
import '../../features/library/presentation/ficha_screen.dart';
import '../../features/library/presentation/inicio_screen.dart';
import '../../features/read_on_pc/mando_screen.dart';
import '../../features/reader/presentation/lector_screen.dart';
import '../../features/search/buscar_screen.dart';
import '../../features/library/presentation/estante_screen.dart';
import '../../features/settings/ajustes_screen.dart';
import '../../features/settings/almacenamiento_screen.dart';
import '../../features/settings/configuracion_screen.dart';
import '../../features/settings/pc_screen.dart';
import '../../features/settings/perfil_screen.dart';
import '../../features/settings/temas_screen.dart';
import '../../features/study/estudio_screen.dart';
import '../../features/sync/presentation/emparejar_screen.dart';
import '../../features/sync/presentation/seleccion_screen.dart';

final GlobalKey<NavigatorState> _raiz = GlobalKey<NavigatorState>(
  debugLabel: 'raiz',
);

GoRoute _pestana(String ruta, int i, Widget pantalla) => GoRoute(
  path: ruta,
  builder: (BuildContext context, GoRouterState state) =>
      ScrollArribaAlReseleccionar(tab: i, child: pantalla),
);

/// Las pestañas viven en un [StatefulShellRoute] con la barra inferior; el
/// lector, la ficha y los ajustes se apilan encima a pantalla completa.
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>(
  (Ref ref) => GoRouter(
    navigatorKey: _raiz,
    initialLocation: '/inicio',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        parentNavigatorKey: _raiz,
        builder:
            (
              BuildContext context,
              GoRouterState state,
              StatefulNavigationShell shell,
            ) => AppShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[_pestana('/inicio', 0, const InicioScreen())],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              _pestana('/biblioteca', 1, const BibliotecaScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[_pestana('/buscar', 2, const BuscarScreen())],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[_pestana('/estudio', 3, const EstudioScreen())],
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/libro/:id',
        builder: (BuildContext context, GoRouterState state) =>
            FichaScreen(id: state.pathParameters['id']!),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/leer/:id',
        builder: (BuildContext context, GoRouterState state) => LectorScreen(
          edicionId: state.pathParameters['id']!,
          destino: state.extra as Map<String, dynamic>?,
        ),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/emparejar',
        builder: (BuildContext context, GoRouterState state) =>
            const EmparejarScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/seleccion',
        builder: (BuildContext context, GoRouterState state) =>
            const SeleccionScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/mando',
        builder: (BuildContext context, GoRouterState state) =>
            switch (state.extra) {
              final String id => MandoScreen(abrir: id),
              // Seguir en el PC desde el lector: el libro y la frase.
              final (String, Map<String, dynamic>) x => MandoScreen(
                abrir: x.$1,
                en: x.$2,
              ),
              _ => const MandoScreen(),
            },
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/ajustes',
        builder: (BuildContext context, GoRouterState state) =>
            const AjustesScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/perfil',
        builder: (BuildContext context, GoRouterState state) =>
            const PerfilScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/pc',
        builder: (BuildContext context, GoRouterState state) =>
            const PcScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/almacenamiento',
        builder: (BuildContext context, GoRouterState state) =>
            const AlmacenamientoScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/configuracion',
        builder: (BuildContext context, GoRouterState state) =>
            const ConfiguracionScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/temas',
        builder: (BuildContext context, GoRouterState state) =>
            const TemasScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/estante/:tipo/:valor',
        builder: (BuildContext context, GoRouterState state) => EstanteScreen(
          tipo: state.pathParameters['tipo']!,
          valor: state.pathParameters['valor']!,
        ),
      ),
      GoRoute(
        parentNavigatorKey: _raiz,
        path: '/acerca',
        builder: (BuildContext context, GoRouterState state) =>
            const AcercaScreen(),
      ),
    ],
  ),
);
