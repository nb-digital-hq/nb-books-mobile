import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/barra_raiz.dart';
import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../core/utils/ids.dart';
import '../../data/db/database.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/chip_pill.dart';
import '../../shared/widgets/portada.dart';
import '../../shared/widgets/sheet.dart';
import '../library/application/biblioteca.dart';
import '../library/presentation/libro_widgets.dart' show porcentajeLegible;
import '../profile/perfil.dart';
import '../settings/pc_screen.dart';
import '../sync/application/sync_controller.dart';
import '../sync/data/sync_repository.dart';

final StreamProvider<List<Tarjeta>> pendientesProvider =
    StreamProvider<List<Tarjeta>>(
      (Ref ref) =>
          ref.watch(databaseProvider).vigilarTarjetasPendientes(ahoraIso()),
    );
final StreamProvider<int> _cuantasTarjetas = StreamProvider<int>(
  (Ref ref) => ref.watch(databaseProvider).vigilarCuantasTarjetas(),
);
final StreamProvider<List<Nota>> _notas = StreamProvider<List<Nota>>(
  (Ref ref) => ref.watch(databaseProvider).vigilarNotas(),
);
final StreamProvider<List<Palabra>> _vocabulario =
    StreamProvider<List<Palabra>>(
      (Ref ref) => ref.watch(databaseProvider).vigilarVocabulario(),
    );

/// Qué se ve en Estudio.
enum VistaDeEstudio { repaso, anotaciones, notas, vocabulario }

extension on VistaDeEstudio {
  String get nombre => switch (this) {
    VistaDeEstudio.repaso => tr('Repaso'),
    VistaDeEstudio.anotaciones => tr('Anotaciones'),
    VistaDeEstudio.notas => tr('Notas'),
    VistaDeEstudio.vocabulario => tr('Vocabulario'),
  };
  IconData get icono => switch (this) {
    VistaDeEstudio.repaso => AppIcons.cards,
    VistaDeEstudio.anotaciones => AppIcons.highlight,
    VistaDeEstudio.notas => AppIcons.notes,
    VistaDeEstudio.vocabulario => AppIcons.vocabulary,
  };
}

const String kVistaDeEstudio = 'estudio_vista';

/// La vista de Estudio guardada, leída en `main` antes del primer fotograma:
/// con la base ocupada sincronizando, el ajuste podía tardar segundos en llegar
/// y la pestaña se quedaba vacía o enseñaba otra vista un momento.
final Provider<String?> vistaDeEstudioInicialProvider = Provider<String?>(
  (Ref ref) => null,
);

VistaDeEstudio _vistaDe(String? v) => VistaDeEstudio.values.firstWhere(
  (VistaDeEstudio x) => x.name == v,
  orElse: () => VistaDeEstudio.repaso,
);

final StreamProvider<VistaDeEstudio> vistaDeEstudioProvider =
    StreamProvider<VistaDeEstudio>(
      (Ref ref) => ref
          .watch(databaseProvider)
          .vigilarAjuste(kVistaDeEstudio)
          .map(_vistaDe),
    );

/// Estudio: una cosa a la vez, elegida desde el título. Las tarjetas las
/// genera el PC; el repaso se hace aquí con el mismo cálculo.
class EstudioScreen extends ConsumerWidget {
  const EstudioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final VistaDeEstudio vista =
        ref.watch(vistaDeEstudioProvider).value ??
        _vistaDe(ref.read(vistaDeEstudioInicialProvider));
    final int pendientes = ref.watch(pendientesProvider).value?.length ?? 0;
    return Column(
      children: <Widget>[
        BarraRaiz(
          titulo: vista.nombre,
          tituloWidget: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _elegir(context, ref, vista, pendientes),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      vista.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: NbFonts.display,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.44,
                        color: c.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(AppIcons.expand, color: c.text2),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: switch (vista) {
            VistaDeEstudio.repaso => const _Repaso(),
            VistaDeEstudio.anotaciones => const _Anotaciones(),
            VistaDeEstudio.notas => const _Notas(),
            VistaDeEstudio.vocabulario => const _Vocabulario(),
          },
        ),
      ],
    );
  }

  Future<void> _elegir(
    BuildContext context,
    WidgetRef ref,
    VistaDeEstudio actual,
    int pendientes,
  ) async {
    final VistaDeEstudio? v = await mostrarHojaMenu<VistaDeEstudio>(
      context,
      builder: (BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final VistaDeEstudio x in VistaDeEstudio.values)
            ListTile(
              leading: Icon(x.icono),
              title: Text(x.nombre),
              subtitle: x == VistaDeEstudio.repaso && pendientes > 0
                  ? Text(
                      tr('{n} por repasar', <String, Object?>{'n': pendientes}),
                    )
                  : null,
              trailing: x == actual ? const Icon(AppIcons.check) : null,
              onTap: () => Navigator.pop(ctx, x),
            ),
        ],
      ),
    );
    if (v != null) {
      await ref.read(databaseProvider).fijarAjuste(kVistaDeEstudio, v.name);
    }
  }
}

class _Repaso extends ConsumerStatefulWidget {
  const _Repaso();

  @override
  ConsumerState<_Repaso> createState() => _RepasoState();
}

class _RepasoState extends ConsumerState<_Repaso> {
  bool _vuelta = false;
  int _hechas = 0;

  Future<void> _calificar(Tarjeta t, String calificacion) async {
    final AppDatabase db = ref.read(databaseProvider);
    await db
        .into(db.repasos)
        .insert(
          RepasosCompanion.insert(
            id: nuevoId(),
            tarjeta: t.id,
            calificacion: calificacion,
            repasadoEn: ahoraIso(),
            pendiente: const Value<bool>(true),
          ),
        );
    await recalcularTarjeta(db, t.id);
    setState(() {
      _vuelta = false;
      _hechas++;
    });
    ref.read(syncProvider.notifier).sincronizar();
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final List<Tarjeta> lista =
        ref.watch(pendientesProvider).value ?? const <Tarjeta>[];
    final int total = ref.watch(_cuantasTarjetas).value ?? 0;
    if (lista.isEmpty) {
      return _Vacio(
        icono: _hechas > 0 ? AppIcons.done : AppIcons.cards,
        titulo: _hechas > 0
            ? tr('Repaso terminado')
            : total == 0
            ? tr('Sin tarjetas todavía')
            : tr('Nada que repasar hoy'),
        texto: _hechas > 0
            ? tr('Repasaste {n} tarjetas. Vuelve mañana.', <String, Object?>{
                'n': _hechas,
              })
            : total == 0
            ? tr(
                'Las tarjetas se crean en NB Books, en Estudio, y llegan aquí para repasarlas.',
              )
            : tr('Tienes {n} tarjetas al día.', <String, Object?>{'n': total}),
      );
    }
    final Tarjeta t = lista.first;
    final Edicion? libro = t.edicion == null
        ? null
        : (ref.watch(edicionesProvider).value ?? const <Edicion>[])
              .where((Edicion e) => e.id == t.edicion)
              .firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                tr('{n} por repasar', <String, Object?>{'n': lista.length}),
                style: TextStyle(
                  fontFamily: NbFonts.ui,
                  fontWeight: FontWeight.w700,
                  color: c.text2,
                ),
              ),
              const Spacer(),
              if (_hechas > 0)
                Text(
                  tr('{n} hechas', <String, Object?>{'n': _hechas}),
                  style: TextStyle(color: c.text3),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: _hechas / (_hechas + lista.length),
            minHeight: 4,
            color: c.accent,
            backgroundColor: c.line,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _vuelta = !_vuelta),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (Widget w, Animation<double> a) =>
                    FadeTransition(
                      opacity: a,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.97, end: 1).animate(a),
                        child: w,
                      ),
                    ),
                child: Container(
                  key: ValueKey<String>('${t.id}$_vuelta'),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: _vuelta ? c.soft : c.bg2,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: _vuelta ? c.accent : c.line),
                  ),
                  child: Column(
                    children: <Widget>[
                      Text(
                        _vuelta ? tr('RESPUESTA') : tr('PREGUNTA'),
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.4,
                          fontWeight: FontWeight.w800,
                          color: _vuelta ? c.accent : c.text3,
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: SingleChildScrollView(
                            child: Text(
                              _vuelta ? t.reverso : t.anverso,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: NbFonts.display,
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                color: c.text,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (libro != null)
                        Text(
                          libro.titulo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: c.text3),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!_vuelta)
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: () => setState(() => _vuelta = true),
              child: Text(tr('Ver la respuesta')),
            )
          else
            Row(
              children: <Widget>[
                for (final (String clave, String texto, Color color)
                    in <(String, String, Color)>[
                      ('again', tr('Otra vez'), const Color(0xFFE5484D)),
                      ('hard', tr('Difícil'), const Color(0xFFFFA502)),
                      ('good', tr('Bien'), const Color(0xFF3DDC84)),
                      ('easy', tr('Fácil'), c.accent),
                    ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          foregroundColor: color,
                          side: BorderSide(color: color.withValues(alpha: 0.6)),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: () => _calificar(t, clave),
                        child: Text(texto, maxLines: 1),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Qué anotaciones se ven.
enum _TipoDeAnotacion { todas, highlight, underline, note, bookmark }

class _Anotaciones extends ConsumerStatefulWidget {
  const _Anotaciones();

  @override
  ConsumerState<_Anotaciones> createState() => _AnotacionesState();
}

class _AnotacionesState extends ConsumerState<_Anotaciones> {
  _TipoDeAnotacion _tipo = _TipoDeAnotacion.todas;

  String _nombre(_TipoDeAnotacion t) => switch (t) {
    _TipoDeAnotacion.todas => tr('Todas'),
    _TipoDeAnotacion.highlight => tr('Resaltados'),
    _TipoDeAnotacion.underline => tr('Subrayados'),
    _TipoDeAnotacion.note => tr('Notas'),
    _TipoDeAnotacion.bookmark => tr('Marcadores'),
  };

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final List<Anotacion> todas =
        (ref.watch(todasLasAnotacionesProvider).value ?? const <Anotacion>[])
            .where((Anotacion a) => a.tipo != 'ink')
            .toList();
    if (todas.isEmpty) {
      return _Vacio(
        icono: AppIcons.highlight,
        titulo: tr('Sin anotaciones'),
        texto: tr('Lo que resaltes, subrayes o anotes aparecerá aquí.'),
      );
    }
    final List<Anotacion> lista = <Anotacion>[
      for (final Anotacion a in todas)
        if (_tipo == _TipoDeAnotacion.todas || a.tipo == _tipo.name) a,
    ];
    final Map<String, Edicion> ediciones = <String, Edicion>{
      for (final Edicion e
          in ref.watch(edicionesProvider).value ?? const <Edicion>[])
        e.id: e,
    };
    // Agrupadas por libro, el libro anotado más recientemente primero.
    final Map<String, List<Anotacion>> porLibro = <String, List<Anotacion>>{};
    for (final Anotacion a in lista) {
      porLibro.putIfAbsent(a.edicion, () => <Anotacion>[]).add(a);
    }
    final List<Widget> filas = <Widget>[];
    for (final MapEntry<String, List<Anotacion>> m in porLibro.entries) {
      final Edicion? e = ediciones[m.key];
      filas.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                child: Portada(
                  titulo: e?.titulo ?? '',
                  ruta: e?.rutaPortada,
                  radio: 3,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  e?.titulo ?? tr('Libro que ya no está en el teléfono'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: NbFonts.ui,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
              ),
              Text('${m.value.length}', style: TextStyle(color: c.text3)),
            ],
          ),
        ),
      );
      for (final Anotacion a in m.value) {
        filas.add(
          _Deslizable(
            a: a,
            child: _Anotacion(a: a, e: e),
          ),
        );
      }
    }
    return Column(
      children: <Widget>[
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            children: <Widget>[
              for (final _TipoDeAnotacion t in _TipoDeAnotacion.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChipPill(
                    label: _nombre(t),
                    active: t == _tipo,
                    onTap: () => setState(() => _tipo = t),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: lista.isEmpty
              ? _Vacio(
                  icono: AppIcons.highlight,
                  titulo: tr('Nada de este tipo'),
                  texto: tr('Prueba con otro filtro.'),
                )
              : ListView(
                  primary: true,
                  padding: const EdgeInsets.only(bottom: 24),
                  children: filas,
                ),
        ),
      ],
    );
  }
}

/// Deslizar una anotación la quita, con un momento para deshacerlo.
class _Deslizable extends ConsumerWidget {
  const _Deslizable({required this.a, required this.child});
  final Anotacion a;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    return Dismissible(
      key: ValueKey<String>(a.id),
      direction: DismissDirection.endToStart,
      background: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
        child: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: c.bg3,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(AppIcons.trash, color: c.text2),
        ),
      ),
      onDismissed: (_) async {
        final AppDatabase db = ref.read(databaseProvider);
        final ScaffoldMessengerState avisos = ScaffoldMessenger.of(context);
        await db.darDeBaja(a.id);
        avisos.showSnackBar(
          SnackBar(
            // Con acción, el aviso se quedaría hasta tocarlo y taparía la
            // barra de anotar al abrir un libro.
            persist: false,
            content: Text(tr('Anotación quitada.')),
            action: SnackBarAction(
              label: tr('Deshacer'),
              onPressed: () => db.recuperar(a.id),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _Anotacion extends StatelessWidget {
  const _Anotacion({required this.a, required this.e});
  final Anotacion a;
  final Edicion? e;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final Map<String, dynamic> l =
        jsonDecode(a.locator) as Map<String, dynamic>;
    final String? cita =
        (l['text'] as Map<String, dynamic>?)?['highlight'] as String?;
    final double? p =
        ((l['locations'] as Map<String, dynamic>?)?['totalProgression'] as num?)
            ?.toDouble();
    final Color marca = switch (a.tipo) {
      'highlight' => c.accent,
      'underline' => c.text2,
      'note' => const Color(0xFFFFA502),
      _ => c.text3,
    };
    return _Tarjeta(
      alPulsar: e?.ruta == null
          ? null
          : () => context.push('/leer/${a.edicion}', extra: l),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: marca,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    a.tipo == 'bookmark'
                        ? tr('Marcador')
                        : (cita ?? a.texto ?? ''),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 15,
                      height: 1.45,
                      color: c.text,
                    ),
                  ),
                  if (a.tipo == 'note' &&
                      (a.texto ?? '').trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      a.texto!.trim(),
                      style: TextStyle(
                        fontFamily: NbFonts.ui,
                        fontSize: 13.5,
                        color: c.text2,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    <String>[
                      if (p != null) porcentajeLegible(p),
                      haceCuanto(a.creadaEn),
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: c.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notas extends ConsumerWidget {
  const _Notas();

  Future<void> _editar(BuildContext context, WidgetRef ref, Nota? n) async {
    final TextEditingController titulo = TextEditingController(text: n?.titulo);
    final TextEditingController cuerpo = TextEditingController(text: n?.cuerpo);
    final bool? guardar = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(n == null ? tr('Nota nueva') : tr('Editar la nota')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: titulo,
                decoration: InputDecoration(labelText: tr('Título')),
              ),
              const SizedBox(height: 12),
              TextField(controller: cuerpo, minLines: 4, maxLines: 12),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancelar')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Guardar')),
          ),
        ],
      ),
    );
    if (guardar != true) {
      return;
    }
    final AppDatabase db = ref.read(databaseProvider);
    // La revisión que se vio viaja con el cambio: si la nota cambió en el PC
    // mientras tanto, el PC la guarda como nota nueva y no se pierde ninguna.
    await db
        .into(db.notas)
        .insertOnConflictUpdate(
          NotasCompanion.insert(
            id: n?.id ?? nuevoId(),
            titulo: titulo.text.trim(),
            cuerpo: cuerpo.text,
            revision: Value<int>(n?.revision ?? 0),
            actualizadaEn: ahoraIso(),
            pendiente: const Value<bool>(true),
          ),
        );
    ref.read(syncProvider.notifier).sincronizar();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Nota> lista = ref.watch(_notas).value ?? const <Nota>[];
    return Stack(
      children: <Widget>[
        if (lista.isEmpty)
          _Vacio(
            icono: AppIcons.notes,
            titulo: tr('Sin notas'),
            texto: tr(
              'Las notas de Estudio del PC llegan aquí, y puedes escribir las tuyas.',
            ),
          )
        else
          ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 96),
            itemCount: lista.length,
            itemBuilder: (BuildContext ctx, int i) {
              final Nota n = lista[i];
              return _Tarjeta(
                alPulsar: () => _editar(context, ref, n),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      n.titulo.isEmpty ? tr('Sin título') : n.titulo,
                      style: TextStyle(
                        fontFamily: NbFonts.ui,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: context.nb.text,
                      ),
                    ),
                    if (n.cuerpo.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        n.cuerpo.trim(),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.nb.text2, height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      haceCuanto(n.actualizadaEn),
                      style: TextStyle(fontSize: 12, color: context.nb.text3),
                    ),
                  ],
                ),
              );
            },
          ),
        Positioned(
          right: 18,
          bottom: 18,
          child: FloatingActionButton.extended(
            onPressed: () => _editar(context, ref, null),
            icon: const Icon(AppIcons.plus),
            label: Text(tr('Nota nueva')),
          ),
        ),
      ],
    );
  }
}

class _Vocabulario extends ConsumerWidget {
  const _Vocabulario();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final List<Palabra> lista =
        ref.watch(_vocabulario).value ?? const <Palabra>[];
    if (lista.isEmpty) {
      return _Vacio(
        icono: AppIcons.vocabulary,
        titulo: tr('Sin vocabulario'),
        texto: tr('Las palabras que consultes en NB Books aparecerán aquí.'),
      );
    }
    return ListView.builder(
      primary: true,
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      itemCount: lista.length,
      itemBuilder: (BuildContext ctx, int i) => _Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              lista[i].lema,
              style: TextStyle(
                fontFamily: NbFonts.display,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: c.text,
              ),
            ),
            if (lista[i].termino != lista[i].lema) ...<Widget>[
              const SizedBox(height: 4),
              Text(lista[i].termino, style: TextStyle(color: c.text2)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Una tarjeta de la lista de Estudio.
class _Tarjeta extends StatelessWidget {
  const _Tarjeta({required this.child, this.alPulsar});
  final Widget child;
  final VoidCallback? alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: Material(
        color: c.bg2,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: alPulsar,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.line),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Vacio extends StatelessWidget {
  const _Vacio({
    required this.icono,
    required this.titulo,
    required this.texto,
  });
  final IconData icono;
  final String titulo;
  final String texto;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: c.soft, shape: BoxShape.circle),
              child: Icon(icono, size: 32, color: c.accent),
            ),
            const SizedBox(height: 16),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: NbFonts.display,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: c.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              texto,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.text2, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
