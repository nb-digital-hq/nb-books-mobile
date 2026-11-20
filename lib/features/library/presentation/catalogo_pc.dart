import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../core/network/salidas.dart';
import '../../../core/security/secure_store.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/portada.dart';
import '../../sync/application/sync_controller.dart';
import '../../sync/data/sync_repository.dart';

/// "Todo el catálogo": lo pide al PC por páginas, sin copiar nada. Elegir un
/// libro aquí lo añade a la selección y llega con la siguiente sincronización.
class CatalogoDelPc extends ConsumerStatefulWidget {
  const CatalogoDelPc({super.key});

  @override
  ConsumerState<CatalogoDelPc> createState() => _CatalogoDelPcState();
}

class _CatalogoDelPcState extends ConsumerState<CatalogoDelPc> {
  final List<FichaDelPc> _fichas = <FichaDelPc>[];
  final ScrollController _scroll = ScrollController();
  String _q = '';
  bool _cargando = false;
  bool _fin = false;
  String? _fallo;
  String? _token;
  Timer? _espera;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        unawaited(_mas());
      }
    });
    unawaited(_reiniciar());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _espera?.cancel();
    super.dispose();
  }

  Future<void> _reiniciar() async {
    _fichas.clear();
    _fin = false;
    _token = await ref.read(secureStoreProvider).deviceToken();
    await _mas();
  }

  Future<void> _mas() async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    if (_cargando || _fin || pc == null) {
      return;
    }
    setState(() => _cargando = true);
    try {
      final List<FichaDelPc> nuevas = await ref
          .read(syncProvider.notifier)
          .conPc(
            (PairedPc pc) => ref
                .read(syncRepositoryProvider)
                .catalogo(pc, q: _q, desde: _fichas.length),
          );
      setState(() {
        _fichas.addAll(nuevas);
        _fin = nuevas.isEmpty;
        _fallo = null;
      });
    } catch (_) {
      setState(
        () => _fallo = tr(
          'El PC no responde. Este catálogo solo se ve conectado.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _elegir(FichaDelPc f) async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    if (pc == null) {
      return;
    }
    final SyncRepository repo = ref.read(syncRepositoryProvider);
    try {
      final bool hecho = await ref.read(syncProvider.notifier).conPc((
        PairedPc pc,
      ) async {
        final Seleccion s = await repo.seleccion(pc);
        if (s.todo || s.ediciones.contains(f.id)) {
          return false;
        }
        await repo.fijarSeleccion(
          pc,
          s.copiar(ediciones: <String>[...s.ediciones, f.id]),
        );
        return true;
      });
      if (!hecho) {
        return;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('No se pudo guardar la selección.'))),
        );
      }
      return;
    }
    final int i = _fichas.indexOf(f);
    setState(
      () => _fichas[i] = FichaDelPc(
        id: f.id,
        titulo: f.titulo,
        autores: f.autores,
        portada: f.portada,
        seleccionada: true,
      ),
    );
    unawaited(ref.read(syncProvider.notifier).sincronizar());
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final PairedPc? pc = ref.watch(syncProvider.select((EstadoSync s) => s.pc));
    if (pc == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                tr('Empareja el teléfono con el PC para ver su catálogo.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.text2),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => context.push('/emparejar'),
                icon: const Icon(AppIcons.qr),
                label: Text(tr('Emparejar con el PC')),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(AppIcons.search),
              hintText: tr('Título o autor'),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onChanged: (String v) {
              _espera?.cancel();
              _espera = Timer(const Duration(milliseconds: 350), () {
                _q = v.trim();
                unawaited(_reiniciar());
              });
            },
          ),
        ),
        if (_fallo != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_fallo!, style: TextStyle(color: c.text2)),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: _fichas.length + (_cargando ? 1 : 0),
            itemBuilder: (BuildContext ctx, int i) {
              if (i >= _fichas.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final FichaDelPc f = _fichas[i];
              return ListTile(
                leading: SizedBox(
                  width: 40,
                  child: Portada(
                    titulo: f.titulo,
                    radio: 3,
                    imagen: f.portada && _token != null
                        ? portadaDelPc(pc.baseUrl, f.id, _token!)
                        : null,
                  ),
                ),
                title: Text(
                  f.titulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  f.autores.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: f.seleccionada
                    ? Icon(AppIcons.selected, color: c.accent)
                    : IconButton(
                        tooltip: tr('Elegir para el teléfono'),
                        icon: const Icon(AppIcons.select),
                        onPressed: () => _elegir(f),
                      ),
                onTap: f.seleccionada
                    ? () => context.push('/libro/${f.id}')
                    : () => _elegir(f),
              );
            },
          ),
        ),
      ],
    );
  }
}
