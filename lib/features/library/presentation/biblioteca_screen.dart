import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/barra_raiz.dart';
import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/util/responsive.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/chip_pill.dart';
import '../../../shared/widgets/sheet.dart';
import '../../local_books/libros_del_telefono.dart';
import '../../sync/application/sync_controller.dart';
import '../application/biblioteca.dart';
import '../application/estantes.dart';
import 'catalogo_pc.dart';
import 'libro_widgets.dart';

/// Biblioteca: los libros y sus estanterías (autores, series, colecciones y
/// materias). Leer, terminar, descargar o del teléfono son filtros, no
/// secciones. Con el PC emparejado, una pestaña más enseña su catálogo entero.
class BibliotecaScreen extends ConsumerWidget {
  const BibliotecaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool conPc =
        ref.watch(syncProvider.select((EstadoSync s) => s.pc)) != null;
    final List<Widget> pestanas = <Widget>[
      Tab(text: tr('Libros')),
      for (final Estante e in Estante.values) Tab(text: e.plural),
      if (conPc) Tab(text: tr('Todo el PC')),
    ];
    return DefaultTabController(
      key: ValueKey<bool>(conPc),
      length: pestanas.length,
      child: Column(
        children: <Widget>[
          BarraRaiz(titulo: tr('Biblioteca'), trailing: const _Menu()),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            dividerColor: context.nb.line,
            tabs: pestanas,
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                const _Libros(),
                for (final Estante e in Estante.values) _Estantes(estante: e),
                if (conPc) const CatalogoDelPc(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Menu extends ConsumerWidget {
  const _Menu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDatabase db = ref.read(databaseProvider);
    final bool ocultar = ref.watch(ocultarTelefonoProvider).value ?? false;
    final bool conPc =
        ref.watch(syncProvider.select((EstadoSync s) => s.pc)) != null;
    return PopupMenuButton<String>(
      icon: const Icon(AppIcons.more),
      onSelected: (String v) async {
        switch (v) {
          case 'anadir':
            final int n = await anadirLibrosDelTelefono(
              db,
              ref.read(documentosProvider),
            );
            if (context.mounted && n > 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    n == 1
                        ? tr('1 libro añadido.')
                        : tr('{n} libros añadidos.', <String, Object?>{'n': n}),
                  ),
                ),
              );
            }
          case 'ocultar':
            await db.fijarAjuste(kOcultarTelefono, ocultar ? '0' : '1');
          case 'elegir':
            await context.push(conPc ? '/seleccion' : '/emparejar');
        }
      },
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'elegir',
          child: Text(
            conPc ? tr('Elegir libros del PC') : tr('Emparejar con el PC'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'anadir',
          child: Text(tr('Añadir libros del teléfono')),
        ),
        PopupMenuItem<String>(
          value: 'ocultar',
          child: Text(
            ocultar
                ? tr('Mostrar los libros del teléfono')
                : tr('Ocultar los libros del teléfono'),
          ),
        ),
      ],
    );
  }
}

class _Libros extends ConsumerWidget {
  const _Libros();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final AppDatabase db = ref.read(databaseProvider);
    final Filtro filtro = ref.watch(filtroProvider).value ?? Filtro.todos;
    final Orden orden = ref.watch(ordenProvider).value ?? Orden.recientes;
    final bool rejilla = ref.watch(rejillaProvider).value ?? true;
    final List<Edicion> todos = ref.watch(librosVisiblesProvider);
    final bool hayTelefono = todos.any((Edicion e) => e.origen == 'telefono');
    final List<Edicion> lista = filtrarYOrdenar(
      todos,
      ref.watch(avanceProvider),
      filtro,
      orden,
    );

    final Widget chips = SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
        children: <Widget>[
          for (final Filtro f in Filtro.values)
            if (f != Filtro.telefono || hayTelefono || filtro == f)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChipPill(
                  label: f.nombre,
                  active: f == filtro,
                  onTap: () => db.fijarAjuste(kFiltro, f.name),
                ),
              ),
        ],
      ),
    );

    final Widget cabecera = Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              lista.length == 1
                  ? tr('1 libro')
                  : tr('{n} libros', <String, Object?>{'n': lista.length}),
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.text3,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              final Orden? o = await mostrarHojaMenu<Orden>(
                context,
                builder: (BuildContext ctx) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final Orden x in Orden.values)
                      ListTile(
                        title: Text(x.nombre),
                        trailing: x == orden
                            ? const Icon(AppIcons.check)
                            : null,
                        onTap: () => Navigator.pop(ctx, x),
                      ),
                  ],
                ),
              );
              if (o != null) {
                await db.fijarAjuste(kOrden, o.name);
              }
            },
            icon: const Icon(AppIcons.sort, size: 18),
            label: Text(orden.nombre),
          ),
          IconButton(
            tooltip: rejilla ? tr('Ver en lista') : tr('Ver en cuadrícula'),
            icon: Icon(rejilla ? AppIcons.list : AppIcons.grid, size: 20),
            onPressed: () => db.fijarAjuste(kRejilla, rejilla ? '0' : '1'),
          ),
        ],
      ),
    );

    final Widget cuerpo;
    if (lista.isEmpty) {
      cuerpo = SliverFillRemaining(
        hasScrollBody: false,
        child: _Vacio(filtro: filtro, nada: todos.isEmpty),
      );
    } else if (rejilla) {
      final int columnas = gridColumns(MediaQuery.sizeOf(context).width) + 1;
      cuerpo = SliverPadding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnas,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            childAspectRatio: 0.48,
          ),
          itemCount: lista.length,
          itemBuilder: (BuildContext ctx, int i) =>
              TarjetaDeLibro(edicion: lista[i]),
        ),
      );
    } else {
      cuerpo = SliverList.builder(
        itemCount: lista.length,
        itemBuilder: (BuildContext ctx, int i) =>
            FilaDeLibro(edicion: lista[i]),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(syncProvider.notifier).sincronizar(),
      child: CustomScrollView(
        primary: true,
        slivers: <Widget>[
          SliverToBoxAdapter(child: chips),
          SliverToBoxAdapter(child: cabecera),
          cuerpo,
        ],
      ),
    );
  }
}

class _Vacio extends StatelessWidget {
  const _Vacio({required this.filtro, required this.nada});
  final Filtro filtro;
  final bool nada;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final String texto = nada
        ? tr('No hay libros. Elige del PC o añade del teléfono.')
        : switch (filtro) {
            Filtro.enCurso => tr('No estás leyendo nada ahora mismo.'),
            Filtro.sinEmpezar => tr('Ya empezaste todos tus libros.'),
            Filtro.terminados => tr('Todavía no has terminado ningún libro.'),
            Filtro.descargados => tr(
              'No hay libros descargados. Descarga uno desde su ficha.',
            ),
            _ => tr('No hay libros aquí.'),
          };
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(AppIcons.library, size: 40, color: c.text3),
          const SizedBox(height: 12),
          Text(
            texto,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.text2, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Estantes extends ConsumerWidget {
  const _Estantes({required this.estante});
  final Estante estante;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final List<Grupo> grupos = agrupar(
      ref.watch(librosVisiblesProvider),
      estante,
      colecciones: ref.watch(coleccionesProvider).value ?? const <Coleccion>[],
    );
    if (grupos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            switch (estante) {
              Estante.autor => tr('Tus libros no tienen autoría todavía.'),
              Estante.serie => tr(
                'Ninguno de tus libros es parte de una serie.',
              ),
              Estante.coleccion => tr(
                'Las colecciones se crean en NB Books, en el PC, y llegan aquí con sus libros.',
              ),
              Estante.materia => tr('Tus libros no tienen materias todavía.'),
            },
            textAlign: TextAlign.center,
            style: TextStyle(color: c.text2, height: 1.4),
          ),
        ),
      );
    }
    return ListView.builder(
      primary: true,
      padding: const EdgeInsets.only(top: 6, bottom: 24),
      itemCount: grupos.length,
      itemBuilder: (BuildContext ctx, int i) =>
          FilaDeGrupo(grupo: grupos[i], estante: estante),
    );
  }
}
