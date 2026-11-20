import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/security/secure_store.dart';
import '../../data/db/database.dart';
import '../sync/application/sync_controller.dart';

/// Cómo va cada descarga en curso, de 0 a 1, por edición.
class DescargasController extends Notifier<Map<String, double>> {
  final Map<String, CancelToken> _cancelar = <String, CancelToken>{};

  @override
  Map<String, double> build() => const <String, double>{};

  /// Descarga un libro. Solo se descargan libros, y solo a petición: lo ligero
  /// viaja siempre con la sincronización.
  ///
  /// Con [temporal], el libro va a la caché de lectura sin descargar: se puede
  /// leer ya, pero no cuenta como descargado y se recorta solo.
  Future<String?> descargar(Edicion e, {bool temporal = false}) async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    if (pc == null || state.containsKey(e.id)) {
      return pc == null ? 'sin_pc' : null;
    }
    final CancelToken t = CancelToken();
    _cancelar[e.id] = t;
    state = <String, double>{...state, e.id: 0};
    try {
      await ref
          .read(syncProvider.notifier)
          .conPc(
            (PairedPc pc) => ref
                .read(syncRepositoryProvider)
                .descargar(
                  pc,
                  e,
                  cancelar: t,
                  temporal: temporal,
                  progreso: (int r, int total) {
                    if (total > 0) {
                      state = <String, double>{...state, e.id: r / total};
                    }
                  },
                ),
          );
      return null;
    } on DioException catch (x) {
      return CancelToken.isCancel(x) ? null : 'error_red';
    } catch (_) {
      return 'error_descarga';
    } finally {
      _cancelar.remove(e.id);
      state = <String, double>{...state}..remove(e.id);
    }
  }

  void cancelar(String id) => _cancelar[id]?.cancel();
}

final NotifierProvider<DescargasController, Map<String, double>>
descargasProvider = NotifierProvider<DescargasController, Map<String, double>>(
  DescargasController.new,
);

/// Cómo va la descarga de una edición, o null si no se está descargando.
final ProviderFamily<double?, String> descargaDe =
    Provider.family<double?, String>(
      (Ref ref, String id) =>
          ref.watch(descargasProvider.select((Map<String, double> m) => m[id])),
    );
