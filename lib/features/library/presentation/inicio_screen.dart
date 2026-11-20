import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/barra_raiz.dart';
import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/chip_pill.dart';
import '../../../shared/widgets/portada.dart';
import '../../../shared/widgets/section_head.dart';
import '../../offline/descargas.dart';
import '../../profile/perfil.dart';
import '../../study/estudio_screen.dart';
import '../../sync/application/sync_controller.dart';
import '../application/biblioteca.dart';
import '../application/estantes.dart';
import 'libro_widgets.dart';

/// Una semilla por día: las secciones que eligen al azar cambian cada día y no
/// en cada reconstrucción, que haría saltar la pantalla.
int _semillaDelDia() {
  final DateTime h = DateTime.now();
  return h.year * 10000 + h.month * 100 + h.day;
}

/// Inicio: lo que se está leyendo, el ritmo de lectura, lo que toca repasar y
/// propuestas sacadas de la propia biblioteca (la serie que sigue, más del
/// autor que se lee, libros por empezar, materias y colecciones). Nada viene
/// de fuera: todo sale de lo que la persona eligió.
class InicioScreen extends ConsumerWidget {
  const InicioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final EstadoSync sync = ref.watch(syncProvider);
    final List<Edicion> libros = ref.watch(librosVisiblesProvider);
    final Map<String, (double, String)> avance = ref.watch(avanceProvider);
    final Estadisticas est = ref.watch(estadisticasProvider);
    final int repasar = ref.watch(pendientesProvider).value?.length ?? 0;
    final List<Coleccion> colecciones =
        ref.watch(coleccionesProvider).value ?? const <Coleccion>[];
    final String nombre = ref.watch(nombrePerfilProvider).value ?? '';

    double av(Edicion e) => avance[e.id]?.$1 ?? 0;
    final Set<String> usados = <String>{};
    List<Edicion> sinUsar(Iterable<Edicion> l, int n) {
      final List<Edicion> r = <Edicion>[];
      for (final Edicion e in l) {
        if (r.length >= n) {
          break;
        }
        if (usados.add(e.id)) {
          r.add(e);
        }
      }
      return r;
    }

    // Seguir leyendo: lo empezado y sin terminar, lo último primero.
    final List<Edicion> leyendo = sinUsar(
      filtrarYOrdenar(libros, avance, Filtro.enCurso, Orden.leidos),
      12,
    );

    // La serie que sigue: de cada serie con algún libro terminado o empezado,
    // el primero que falta por empezar.
    final List<Edicion> siguienteEnSerie = <Edicion>[];
    for (final Grupo g in agrupar(libros, Estante.serie)) {
      if (!g.libros.any((Edicion e) => avance.containsKey(e.id))) {
        continue;
      }
      final Edicion? s = g.libros
          .where((Edicion e) => !avance.containsKey(e.id))
          .firstOrNull;
      if (s != null) {
        siguienteEnSerie.add(s);
      }
    }

    // Más del autor que se está leyendo.
    String? autor;
    List<Edicion> delAutor = const <Edicion>[];
    final Edicion? ultimo =
        leyendo.firstOrNull ??
        filtrarYOrdenar(
          libros,
          avance,
          Filtro.terminados,
          Orden.leidos,
        ).firstOrNull;
    if (ultimo != null) {
      autor = listaJson(ultimo.autores).whereType<String>().firstOrNull;
      if (autor != null) {
        delAutor =
            agrupar(libros, Estante.autor)
                .where((Grupo g) => g.clave == autor)
                .firstOrNull
                ?.libros
                .where((Edicion e) => !avance.containsKey(e.id))
                .toList() ??
            const <Edicion>[];
      }
    }

    final List<Edicion> recientes = filtrarYOrdenar(
      libros,
      avance,
      Filtro.todos,
      Orden.recientes,
    ).take(14).toList();

    final List<Edicion> porEmpezar = filtrarYOrdenar(
      libros,
      avance,
      Filtro.sinEmpezar,
      Orden.titulo,
    )..shuffle(math.Random(_semillaDelDia()));

    // Cada libro sale en una sola sección, en este orden.
    final List<Edicion> serie = sinUsar(siguienteEnSerie, 12);
    final List<Edicion> masDelAutor = sinUsar(delAutor, 12);
    final List<Edicion> nuevos = sinUsar(recientes, 14);
    final List<Edicion> empezar = sinUsar(porEmpezar, 12);

    final List<Grupo> materias = agrupar(libros, Estante.materia)
      ..sort((Grupo a, Grupo b) => b.libros.length.compareTo(a.libros.length));
    final List<Grupo> cols = agrupar(
      libros,
      Estante.coleccion,
      colecciones: colecciones,
    );

    final List<Widget> secciones = <Widget>[
      if (leyendo.isNotEmpty) ...<Widget>[
        _Pad(child: SectionHead(title: tr('Seguir leyendo'))),
        _Continuar(edicion: leyendo.first, avance: av(leyendo.first)),
        if (leyendo.length > 1)
          _Carril(libros: leyendo.skip(1).toList(), alto: 236),
      ],
      if (est.minutos > 0 || repasar > 0)
        _Pad(
          child: Row(
            children: <Widget>[
              if (est.minutos > 0) Expanded(child: _Ritmo(est: est)),
              if (est.minutos > 0 && repasar > 0) const SizedBox(width: 10),
              if (repasar > 0) Expanded(child: _PorRepasar(n: repasar)),
            ],
          ),
        ),
      if (serie.isNotEmpty) ...<Widget>[
        _Pad(child: SectionHead(title: tr('Sigue con la serie'))),
        _Carril(libros: serie),
      ],
      if (autor != null && masDelAutor.isNotEmpty) ...<Widget>[
        _Pad(
          child: SectionHead(
            title: tr('Más de {autor}', <String, Object?>{'autor': autor}),
            actionLabel: tr('Ver todo'),
            onAction: () => context.push(
              '/estante/${Estante.autor.name}/${Uri.encodeComponent(autor!)}',
            ),
          ),
        ),
        _Carril(libros: masDelAutor, conAutor: false),
      ],
      if (nuevos.isNotEmpty) ...<Widget>[
        _Pad(
          child: SectionHead(
            title: tr('Recién llegados'),
            actionLabel: tr('Ver todo'),
            onAction: () => context.go('/biblioteca'),
          ),
        ),
        _Carril(libros: nuevos),
      ],
      if (materias.isNotEmpty) ...<Widget>[
        _Pad(child: SectionHead(title: tr('Explora por materias'))),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final Grupo g in materias.take(12))
                ChipPill(
                  label: '${g.nombre}  ${g.libros.length}',
                  icon: AppIcons.subject,
                  onTap: () => context.push(
                    '/estante/${Estante.materia.name}/${Uri.encodeComponent(g.clave)}',
                  ),
                ),
            ],
          ),
        ),
      ],
      if (empezar.isNotEmpty) ...<Widget>[
        _Pad(child: SectionHead(title: tr('Para empezar hoy'))),
        _Carril(libros: empezar),
      ],
      if (cols.isNotEmpty) ...<Widget>[
        _Pad(child: SectionHead(title: tr('Tus colecciones'))),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: cols.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (BuildContext ctx, int i) =>
                _Coleccion(grupo: cols[i]),
          ),
        ),
      ],
    ];

    return RefreshIndicator(
      onRefresh: () => ref.read(syncProvider.notifier).sincronizar(),
      child: ListView(
        primary: true,
        padding: const EdgeInsets.only(bottom: 28),
        children: <Widget>[
          BarraRaiz(
            titulo: _saludo(nombre),
            trailing: _Enlace(sync: sync),
          ),
          if (sync.error == 'revocado' && sync.pc == null)
            _Aviso(
              texto: tr(
                'El PC ya no reconoce este teléfono. Empareja de nuevo para sincronizar.',
              ),
              accion: tr('Emparejar con el PC'),
              alPulsar: () => context.push('/emparejar'),
            )
          else if (sync.pc != null && sync.error == 'pc_no_encontrado')
            _Aviso(
              texto: tr(
                'No se encuentra el PC. Comprueba que NB Books está abierto, con los teléfonos permitidos, y en la misma red.',
              ),
              accion: tr('Reintentar'),
              alPulsar: () => ref.read(syncProvider.notifier).sincronizar(),
            ),
          if (sync.pc == null && libros.isEmpty) const _Bienvenida(),
          if (sync.pc != null && libros.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: <Widget>[
                  Text(
                    tr('Todavía no has elegido libros del PC.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.text2),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => context.push('/seleccion'),
                    icon: const Icon(AppIcons.select),
                    label: Text(tr('Elegir libros')),
                  ),
                ],
              ),
            ),
          ...secciones,
        ],
      ),
    );
  }

  static String _saludo(String nombre) {
    final int h = DateTime.now().hour;
    final String base = h < 6
        ? tr('Buenas noches')
        : h < 13
        ? tr('Buenos días')
        : h < 20
        ? tr('Buenas tardes')
        : tr('Buenas noches');
    return nombre.isEmpty ? base : '$base, ${nombre.split(' ').first}';
  }
}

class _Pad extends StatelessWidget {
  const _Pad({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 0), child: child);
}

/// Un carril horizontal de portadas.
class _Carril extends StatelessWidget {
  const _Carril({required this.libros, this.alto = 250, this.conAutor = true});
  final List<Edicion> libros;
  final double alto;
  final bool conAutor;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: alto,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      itemCount: libros.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (BuildContext ctx, int i) =>
          TarjetaDeLibro(edicion: libros[i], ancho: 124, conAutor: conAutor),
    ),
  );
}

/// El libro que se está leyendo, en grande y con su botón para seguir.
class _Continuar extends ConsumerWidget {
  const _Continuar({required this.edicion, required this.avance});
  final Edicion edicion;
  final double avance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    // Un libro que se lee sin descargar también se sigue desde aquí: desde la
    // caché si aún está, o trayéndolo del PC si está conectado.
    final bool conPc =
        ref.watch(syncProvider.select((EstadoSync s) => s.pc)) != null;
    final bool enTelefono =
        edicion.ruta != null ||
        ref.read(syncRepositoryProvider).enCache(edicion) ||
        (conPc && edicion.origen == 'pc');
    Future<void> abrir() async {
      if (edicion.ruta == null &&
          !ref.read(syncRepositoryProvider).enCache(edicion)) {
        final String? fallo = await ref
            .read(descargasProvider.notifier)
            .descargar(edicion, temporal: true);
        if (fallo != null) {
          if (context.mounted) {
            unawaited(context.push('/libro/${edicion.id}'));
          }
          return;
        }
      }
      if (context.mounted) {
        unawaited(context.push('/leer/${edicion.id}'));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
      child: Material(
        color: c.bg2,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enTelefono
              ? abrir
              : () => context.push('/libro/${edicion.id}'),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: c.line),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[c.soft, c.bg2],
              ),
            ),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 92,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Color(0x66000000), blurRadius: 12),
                      ],
                    ),
                    child: Portada(
                      titulo: edicion.titulo,
                      autor: autoresDe(edicion),
                      ruta: edicion.rutaPortada,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        edicion.titulo,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: NbFonts.display,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: c.text,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        autoresDe(edicion),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.text2),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: LinearProgressIndicator(
                              value: avance.clamp(0.02, 1.0),
                              minHeight: 5,
                              color: c.accent,
                              backgroundColor: c.line,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            porcentajeLegible(avance),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: c.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: enTelefono
                            ? abrir
                            : () => context.push('/libro/${edicion.id}'),
                        icon: const Icon(AppIcons.read, size: 18),
                        label: Text(
                          enTelefono ? tr('Continuar') : tr('Ver el libro'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// El ritmo de la semana, que lleva al perfil.
class _Ritmo extends StatelessWidget {
  const _Ritmo({required this.est});
  final Estadisticas est;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final int maximo = est.diasSemana.fold<int>(1, math.max);
    return _Cajita(
      alPulsar: () => context.push('/perfil'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(AppIcons.streak, size: 16, color: c.accent),
              const SizedBox(width: 6),
              Text(
                est.racha == 1
                    ? tr('1 día seguido')
                    : tr('{n} días seguidos', <String, Object?>{
                        'n': est.racha,
                      }),
                style: TextStyle(fontSize: 12, color: c.text2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            duracionLegible(est.minutosSemana),
            style: TextStyle(
              fontFamily: NbFonts.display,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: c.text,
            ),
          ),
          Text(
            tr('esta semana'),
            style: TextStyle(fontSize: 12, color: c.text3),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 22,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (final int m in est.diasSemana)
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      height: 3 + 19 * m / maximo,
                      decoration: BoxDecoration(
                        color: m > 0 ? c.accent : c.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
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

/// Lo que toca repasar hoy, que lleva al repaso.
class _PorRepasar extends ConsumerWidget {
  const _PorRepasar({required this.n});
  final int n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    return _Cajita(
      alPulsar: () async {
        await ref
            .read(databaseProvider)
            .fijarAjuste(kVistaDeEstudio, VistaDeEstudio.repaso.name);
        if (context.mounted) {
          context.go('/estudio');
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(AppIcons.cards, size: 16, color: c.accent),
              const SizedBox(width: 6),
              Text(
                tr('Repaso'),
                style: TextStyle(fontSize: 12, color: c.text2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$n',
            style: TextStyle(
              fontFamily: NbFonts.display,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: c.text,
            ),
          ),
          Text(
            n == 1 ? tr('tarjeta para hoy') : tr('tarjetas para hoy'),
            style: TextStyle(fontSize: 12, color: c.text3),
          ),
          const SizedBox(height: 8),
          Text(
            tr('Repasar ahora'),
            style: TextStyle(fontWeight: FontWeight.w800, color: c.accent),
          ),
        ],
      ),
    );
  }
}

class _Cajita extends StatelessWidget {
  const _Cajita({required this.child, required this.alPulsar});
  final Widget child;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Material(
      color: c.bg2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: alPulsar,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.line),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Coleccion extends StatelessWidget {
  const _Coleccion({required this.grupo});
  final Grupo grupo;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.push(
        '/estante/${Estante.coleccion.name}/${Uri.encodeComponent(grupo.clave)}',
      ),
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AbanicoDePortadas(libros: grupo.libros, alto: 70),
            const Spacer(),
            Text(
              grupo.nombre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontWeight: FontWeight.w800,
                color: c.text,
              ),
            ),
            Text(
              grupo.libros.length == 1
                  ? tr('1 libro')
                  : tr('{n} libros', <String, Object?>{
                      'n': grupo.libros.length,
                    }),
              style: TextStyle(fontSize: 12, color: c.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _Enlace extends ConsumerWidget {
  const _Enlace({required this.sync});
  final EstadoSync sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    if (sync.pc == null) {
      return IconButton(
        tooltip: tr('Emparejar con el PC'),
        icon: Icon(AppIcons.qr, color: c.text2),
        onPressed: () => context.push('/emparejar'),
      );
    }
    return IconButton(
      tooltip: sync.conectado
          ? tr('Sincronizar ahora')
          : tr('Sin conexión con el PC'),
      onPressed: () => ref.read(syncProvider.notifier).sincronizar(),
      icon: sync.sincronizando
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(AppIcons.sync, color: sync.conectado ? c.accent : c.text3),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({
    required this.texto,
    required this.accion,
    required this.alPulsar,
  });

  final String texto;
  final String accion;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(texto, style: TextStyle(color: c.text2, height: 1.4)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: alPulsar, child: Text(accion)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bienvenida extends StatelessWidget {
  const _Bienvenida();

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.bg2,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(AppIcons.read, color: c.accent, size: 32),
            const SizedBox(height: 12),
            Text(
              tr('Tu biblioteca de NB Books, también aquí'),
              style: TextStyle(
                fontFamily: NbFonts.display,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: c.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'Empareja el teléfono con NB Books en tu PC para elegir libros, o añade los que ya tengas en el teléfono.',
              ),
              style: TextStyle(color: c.text2, height: 1.4),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => context.push('/emparejar'),
                  icon: const Icon(AppIcons.qr),
                  label: Text(tr('Emparejar con el PC')),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/biblioteca'),
                  icon: const Icon(AppIcons.import),
                  label: Text(tr('Añadir del teléfono')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
