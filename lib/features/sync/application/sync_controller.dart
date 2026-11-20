import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nsd/nsd.dart' show Service;

import '../../../core/di/providers.dart';
import '../../../core/network/nb_api_client.dart';
import '../../../core/network/pinned_http_overrides.dart';
import '../../../core/security/secure_store.dart';
import '../../library/application/fotos_de_autores.dart';
import '../data/discovery_service.dart';
import '../data/pairing_repository.dart';
import '../data/qr_payload.dart';
import '../data/sync_repository.dart';

/// Cómo está el enlace con el PC, de cara a quien lee.
enum Enlace { sinEnlace, desconectado, conectado }

class EstadoSync {
  const EstadoSync({
    this.pc,
    this.enlace = Enlace.sinEnlace,
    this.sincronizando = false,
    this.ultimo,
    this.error,
  });

  final PairedPc? pc;
  final Enlace enlace;
  final bool sincronizando;
  final ResultadoDeSync? ultimo;

  /// Código estable del último fallo, o null.
  final String? error;

  bool get conectado => enlace == Enlace.conectado;

  EstadoSync con({
    PairedPc? pc,
    Enlace? enlace,
    bool? sincronizando,
    ResultadoDeSync? ultimo,
    String? error,
    bool limpiarError = false,
  }) => EstadoSync(
    pc: pc ?? this.pc,
    enlace: enlace ?? this.enlace,
    sincronizando: sincronizando ?? this.sincronizando,
    ultimo: ultimo ?? this.ultimo,
    error: limpiarError ? null : (error ?? this.error),
  );
}

final Provider<PairingRepository> pairingRepositoryProvider =
    Provider<PairingRepository>(
      (Ref ref) => PairingRepository(ref.watch(secureStoreProvider)),
    );

final Provider<SyncRepository> syncRepositoryProvider =
    Provider<SyncRepository>((Ref ref) {
      final SecureStore store = ref.watch(secureStoreProvider);
      final String docs = ref.watch(documentosProvider).path;
      return SyncRepository(
        db: ref.watch(databaseProvider),
        dioFor: (PairedPc pc) => NbApiClient.create(
          baseUrl: pc.baseUrl,
          fingerprint: pc.fingerprint,
          token: store.deviceToken,
        ),
        carpetaDeLibros: Directory('$docs/libros'),
        carpetaDePortadas: Directory('$docs/portadas'),
      );
    });

/// El emparejamiento, la conexión y la sincronización con el PC.
class SyncController extends Notifier<EstadoSync> {
  Timer? _periodico;
  bool _repetir = false;

  PairingRepository get _pairing => ref.read(pairingRepositoryProvider);
  SyncRepository get _sync => ref.read(syncRepositoryProvider);

  @override
  EstadoSync build() {
    ref.onDispose(() => _periodico?.cancel());
    final PairedPc? pc = ref.read(initialPairingProvider);
    if (pc != null) {
      NbHttpOverrides.fingerprint = pc.fingerprint;
      Future<void>(sincronizar);
      _programar();
      return EstadoSync(pc: pc, enlace: Enlace.desconectado);
    }
    return const EstadoSync();
  }

  /// Sincroniza cada pocos minutos mientras la app está abierta: lo ligero
  /// viaja siempre, sin que nadie lo pida.
  void _programar() {
    _periodico?.cancel();
    _periodico = Timer.periodic(
      const Duration(minutes: 3),
      (_) => sincronizar(),
    );
  }

  Future<String> _nombreDelTelefono() async {
    try {
      final DeviceInfoPlugin info = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.android) {
        final AndroidDeviceInfo a = await info.androidInfo;
        return '${a.manufacturer} ${a.model}'.trim();
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return (await info.iosInfo).name;
      }
    } catch (_) {
      // Sin datos del modelo, el nombre genérico sirve igual.
    }
    return 'Teléfono';
  }

  String get _plataforma =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  Future<void> _tras(PairedPc pc) async {
    NbHttpOverrides.fingerprint = pc.fingerprint;
    state = EstadoSync(pc: pc, enlace: Enlace.conectado);
    _programar();
  }

  /// Empareja con el contenido de un QR.
  Future<void> emparejarConQr(QrPairingPayload qr) async {
    state = state.con(limpiarError: true);
    try {
      final PairedPc pc = await _pairing.pair(
        qr,
        deviceName: await _nombreDelTelefono(),
        platform: _plataforma,
      );
      await _tras(pc);
    } on PairingException catch (e) {
      state = state.con(error: e.code);
      rethrow;
    }
  }

  /// Empareja tecleando la dirección del PC y el código.
  Future<void> emparejarConCodigo(String direccion, String codigo) async {
    state = state.con(limpiarError: true);
    try {
      final PairedPc pc = await _pairing.pairPorIp(
        direccion: direccion,
        codigo: codigo.trim().toUpperCase(),
        deviceName: await _nombreDelTelefono(),
        platform: _plataforma,
      );
      await _tras(pc);
    } on PairingException catch (e) {
      state = state.con(error: e.code);
      rethrow;
    }
  }

  /// Olvida el PC. Lo descargado y lo anotado se quedan en el teléfono.
  Future<void> desvincular() async {
    _periodico?.cancel();
    await _pairing.unpair();
    NbHttpOverrides.fingerprint = null;
    state = const EstadoSync();
  }

  /// Si el PC cambió de dirección en la red, lo busca por mDNS y se queda con
  /// la nueva sin volver a emparejar: el token y la huella siguen valiendo.
  Future<PairedPc?> _redescubrir(PairedPc pc) async {
    final Service? s = await DiscoveryService().findFirst();
    if (s == null || s.host == null || s.port == null) {
      return null;
    }
    final PairedPc nuevo = PairedPc(
      deviceToken: pc.deviceToken,
      fingerprint: pc.fingerprint,
      host: s.host!,
      port: s.port!,
      nombre: pc.nombre,
    );
    if (!await _pairing.reachable(nuevo)) {
      return null;
    }
    await ref.read(secureStoreProvider).updateEndpoint(s.host!, s.port!);
    return nuevo;
  }

  /// Hace algo con el PC en directo. Si falla por la red (no por una
  /// respuesta del PC), se busca el PC de nuevo y se reintenta una vez: así un
  /// PC que se reinició en otro puerto no deja la búsqueda, el catálogo o las
  /// descargas fallando hasta la próxima sincronización.
  Future<T> conPc<T>(Future<T> Function(PairedPc pc) f) async {
    final PairedPc? pc = state.pc;
    if (pc == null) {
      throw StateError('sin_pc');
    }
    try {
      return await f(pc);
    } on DioException catch (e) {
      if (e.response != null || CancelToken.isCancel(e)) {
        rethrow;
      }
      final PairedPc? nuevo = await pcAlcanzable();
      if (nuevo == null) {
        rethrow;
      }
      return f(nuevo);
    }
  }

  /// El PC, comprobado: si no responde donde estaba (se reinició y cambió de
  /// puerto, o cambió de dirección), se busca en la red y se guarda la nueva.
  /// Lo usan las operaciones en directo antes de pedir nada. Null si no está.
  Future<PairedPc?> pcAlcanzable() async {
    final PairedPc? pc = state.pc;
    if (pc == null) {
      return null;
    }
    if (await _pairing.reachable(pc)) {
      if (!state.conectado) {
        state = state.con(enlace: Enlace.conectado);
      }
      return pc;
    }
    final PairedPc? nuevo = await _redescubrir(pc);
    if (nuevo == null) {
      state = state.con(enlace: Enlace.desconectado, error: 'pc_no_encontrado');
      return null;
    }
    state = EstadoSync(
      pc: nuevo,
      enlace: Enlace.conectado,
      ultimo: state.ultimo,
    );
    return nuevo;
  }

  /// Sube lo pendiente y baja lo nuevo. Si ya hay una en marcha, se repite al
  /// acabar en lugar de solaparse.
  Future<void> sincronizar() async {
    PairedPc? pc = state.pc;
    if (pc == null) {
      return;
    }
    if (state.sincronizando) {
      _repetir = true;
      return;
    }
    state = state.con(sincronizando: true, limpiarError: true);
    try {
      if (!await _pairing.reachable(pc)) {
        pc = await _redescubrir(pc);
        if (pc == null) {
          state = state.con(
            enlace: Enlace.desconectado,
            sincronizando: false,
            error: 'pc_no_encontrado',
          );
          return;
        }
      }
      final ResultadoDeSync r = await _sync.sync(pc);
      state = EstadoSync(pc: pc, enlace: Enlace.conectado, ultimo: r);
      unawaited(_sync.portadasQueFaltan(pc));
      // Con la biblioteca al día, las fotos de los autores nuevos (si la
      // persona las pidió; si no, no sale nada).
      unawaited(ref.read(fotosDeAutoresProvider.notifier).completar());
    } on DioException catch (e) {
      state = state.con(
        enlace: e.response?.statusCode == 401
            ? Enlace.sinEnlace
            : Enlace.desconectado,
        sincronizando: false,
        error: e.response?.statusCode == 401 ? 'revocado' : 'error_red',
      );
      if (e.response?.statusCode == 401) {
        // El PC revocó este teléfono: se olvida el enlace y se dice.
        await _pairing.unpair();
        state = const EstadoSync(error: 'revocado');
      }
    } catch (_) {
      state = state.con(sincronizando: false, error: 'error_sync');
    }
    if (_repetir) {
      _repetir = false;
      unawaited(sincronizar());
    }
  }
}

final NotifierProvider<SyncController, EstadoSync> syncProvider =
    NotifierProvider<SyncController, EstadoSync>(SyncController.new);
