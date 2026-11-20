import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/i18n.dart';
import '../../../core/security/secure_store.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/sub_header.dart';
import '../application/sync_controller.dart';
import '../data/sync_repository.dart';

/// Qué recibe el teléfono del PC: todo, nada, colecciones, autores, series,
/// materias o libros sueltos. Lo elegido llega con su ficha y su portada; el
/// libro en sí se descarga solo cuando se pide.
class SeleccionScreen extends ConsumerStatefulWidget {
  const SeleccionScreen({super.key});

  @override
  ConsumerState<SeleccionScreen> createState() => _SeleccionScreenState();
}

class _SeleccionScreenState extends ConsumerState<SeleccionScreen> {
  Seleccion? _sel;
  Estanterias? _estanterias;
  String? _fallo;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    unawaited(_cargar());
  }

  Future<void> _cargar() async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    if (pc == null) {
      return;
    }
    try {
      final SyncRepository r = ref.read(syncRepositoryProvider);
      final (Seleccion s, Estanterias e) = await ref
          .read(syncProvider.notifier)
          .conPc(
            (PairedPc pc) async =>
                (await r.seleccion(pc), await r.estanterias(pc)),
          );
      setState(() {
        _sel = s;
        _estanterias = e;
      });
    } catch (_) {
      setState(
        () => _fallo = tr('El PC no responde. Vuelve a intentarlo conectado.'),
      );
    }
  }

  Future<void> _guardar() async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    final Seleccion? s = _sel;
    if (pc == null || s == null) {
      return;
    }
    setState(() => _guardando = true);
    try {
      await ref
          .read(syncProvider.notifier)
          .conPc(
            (PairedPc pc) =>
                ref.read(syncRepositoryProvider).fijarSeleccion(pc, s),
          );
      unawaited(ref.read(syncProvider.notifier).sincronizar());
      if (mounted) {
        context.pop();
      }
    } catch (_) {
      setState(() => _fallo = tr('No se pudo guardar la selección.'));
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  List<String> _alternar(List<String> l, String clave) => l.contains(clave)
      ? (<String>[...l]..remove(clave))
      : <String>[...l, clave];

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final Seleccion? s = _sel;
    final Estanterias? e = _estanterias;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              SubHeader(
                title: tr('Elegir libros'),
                trailing: FilledButton(
                  onPressed: s == null || _guardando ? null : _guardar,
                  child: Text(tr('Guardar')),
                ),
              ),
              if (_fallo != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_fallo!, style: TextStyle(color: c.text2)),
                ),
              if (s == null || e == null)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          s.todo
                              ? tr(
                                  'Toda la biblioteca ({n} libros)',
                                  <String, Object?>{'n': e.total},
                                )
                              : tr(
                                  '{n} libros sueltos elegidos',
                                  <String, Object?>{'n': s.ediciones.length},
                                ),
                          style: TextStyle(color: c.text2),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _sel = const Seleccion(todo: true)),
                        child: Text(tr('Todo')),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _sel = const Seleccion()),
                        child: Text(tr('Nada')),
                      ),
                    ],
                  ),
                ),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: <Widget>[
                    Tab(text: tr('Colecciones')),
                    Tab(text: tr('Autores')),
                    Tab(text: tr('Series')),
                    Tab(text: tr('Materias')),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _lista(
                        e.colecciones,
                        s.colecciones,
                        AppIcons.collection,
                        s.todo,
                        (String k) => setState(
                          () => _sel = s.copiar(
                            colecciones: _alternar(s.colecciones, k),
                          ),
                        ),
                      ),
                      _lista(
                        e.autores,
                        s.autores,
                        AppIcons.author,
                        s.todo,
                        (String k) => setState(
                          () =>
                              _sel = s.copiar(autores: _alternar(s.autores, k)),
                        ),
                      ),
                      _lista(
                        e.series,
                        s.series,
                        AppIcons.series,
                        s.todo,
                        (String k) => setState(
                          () => _sel = s.copiar(series: _alternar(s.series, k)),
                        ),
                      ),
                      _lista(
                        e.materias,
                        s.materias,
                        AppIcons.subject,
                        s.todo,
                        (String k) => setState(
                          () => _sel = s.copiar(
                            materias: _alternar(s.materias, k),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    tr(
                      'Los libros sueltos se eligen en Biblioteca, Todo el PC.',
                    ),
                    style: TextStyle(color: c.text3, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _lista(
    List<Estanteria> todas,
    List<String> elegidas,
    IconData icono,
    bool todo,
    ValueChanged<String> alternar,
  ) {
    if (todas.isEmpty) {
      return Center(child: Text(tr('Nada que elegir aquí.')));
    }
    return ListView.builder(
      itemCount: todas.length,
      itemBuilder: (BuildContext ctx, int i) {
        final Estanteria x = todas[i];
        return CheckboxListTile(
          secondary: Icon(icono),
          title: Text(x.nombre),
          subtitle: Text(
            x.obras == 1
                ? tr('1 libro')
                : tr('{n} libros', <String, Object?>{'n': x.obras}),
          ),
          value: todo || elegidas.contains(x.clave),
          onChanged: todo ? null : (_) => alternar(x.clave),
        );
      },
    );
  }
}
