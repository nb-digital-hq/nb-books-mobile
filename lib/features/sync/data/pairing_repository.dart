import 'package:dio/dio.dart';

import '../../../core/network/nb_api_client.dart';
import '../../../core/network/salidas.dart';
import '../../../core/security/secure_store.dart';
import 'pairing_models.dart';
import 'qr_payload.dart';

/// Fábrica de [Dio] inyectable (los tests pasan una con mock adapter).
typedef DioFactory =
    Dio Function({
      required String baseUrl,
      String? fingerprint,
      Future<String?> Function()? token,
    });

/// Endpoint del PC descubierto al conectar por IP: host + puerto + huella TLS
/// aprendida (TOFU). [fingerprint] es null si el PC habla en claro (sin TLS).
class DiscoveredEndpoint {
  const DiscoveredEndpoint({
    required this.host,
    required this.puerto,
    this.fingerprint,
    this.tls = true,
  });

  final String host;
  final int puerto;
  final String? fingerprint;
  final bool tls;
}

/// Descubre un endpoint NB Books en [host] (puerto fijo o escaneo). Inyectable
/// para tests; la implementación real hace TOFU sobre `/api/v1/ping`.
typedef EndpointDiscovery =
    Future<DiscoveredEndpoint?> Function(String host, int? puerto);

/// Error de emparejamiento con un código estable para la UI.
class PairingException implements Exception {
  PairingException(this.code);
  final String code;
  @override
  String toString() => 'PairingException($code)';
}

/// Cliente del handshake: `POST /api/v1/pair`, `GET /api/v1/ping` y persistencia
/// segura de las credenciales (docs/architecture/pc-contract.md §2, §4.1–4.2).
class PairingRepository {
  PairingRepository(
    this._store, {
    DioFactory? dioFactory,
    EndpointDiscovery? discovery,
  }) : _dioFactory = dioFactory ?? NbApiClient.create {
    _discovery = discovery ?? _descubrirReal;
  }

  final SecureStore _store;
  final DioFactory _dioFactory;
  late final EndpointDiscovery _discovery;

  /// Rango de puertos del servidor del PC (docs/architecture/pc-contract.md §1).
  static const int _puertoMin = 8831;
  static const int _puertoMax = 8899;
  static const Duration _pingTimeout = Duration(milliseconds: 1500);

  Future<PairedPc> pair(
    QrPairingPayload qr, {
    required String deviceName,
    required String platform,
  }) async {
    final Dio dio = _dioFactory(
      baseUrl: qr.baseUrl,
      fingerprint: qr.tlsFingerprint,
    );
    final Response<dynamic> res;
    try {
      res = await dio.post<dynamic>(
        '/api/v1/pair',
        data: <String, dynamic>{
          'token': qr.token,
          'nombre_dispositivo': deviceName,
          'plataforma': platform,
        },
      );
    } on DioException catch (e) {
      throw PairingException(_codeFor(e));
    }

    final PairResponse pr = PairResponse.fromJson(_asMap(res.data));
    if (!pr.ok || pr.deviceToken.isEmpty) {
      throw PairingException(pr.error ?? 'respuesta_invalida');
    }

    final PairedPc pc = PairedPc(
      deviceToken: pr.deviceToken,
      fingerprint: qr.tlsFingerprint,
      host: qr.host,
      port: qr.puerto,
      // `/pair` devuelve en `nombre` el nombre del DISPOSITIVO (eco del que
      // mandamos), no el del PC: el PC se identifica por su servicio.
      nombre: qr.servicio.isEmpty ? 'NB Books' : qr.servicio,
    );
    await _store.savePairing(pc);
    return pc;
  }

  /// Emparejamiento por IP (sin QR): descubre el endpoint en [direccion] (host o
  /// `host:puerto`), aprende la huella TLS por TOFU y llama a `/pair` con el
  /// [codigo] de un solo uso. Reusa [pair] una vez resuelto el endpoint.
  Future<PairedPc> pairPorIp({
    required String direccion,
    required String codigo,
    required String deviceName,
    required String platform,
  }) async {
    final (String host, int? puerto) = _parseDireccion(direccion);
    if (host.isEmpty) {
      throw PairingException('direccion_invalida');
    }
    final DiscoveredEndpoint? ep = await _discovery(host, puerto);
    if (ep == null) {
      throw PairingException('pc_no_encontrado');
    }
    final QrPairingPayload payload = QrPairingPayload(
      host: ep.host,
      puerto: ep.puerto,
      token: codigo,
      tlsFingerprint: ep.fingerprint ?? '',
    );
    return pair(payload, deviceName: deviceName, platform: platform);
  }

  /// Descubrimiento real: escanea HTTPS aprendiendo la huella (TOFU). NB Books
  /// no habla en claro, así que no hay degradación a HTTP.
  Future<DiscoveredEndpoint?> _descubrirReal(String host, int? puerto) {
    final List<int> puertos = puerto != null
        ? <int>[puerto]
        : <int>[for (int p = _puertoMin; p <= _puertoMax; p++) p];
    return _escanear(host, puertos, tls: true);
  }

  Future<DiscoveredEndpoint?> _escanear(
    String host,
    List<int> puertos, {
    required bool tls,
  }) async {
    const int lote = 12;
    for (int i = 0; i < puertos.length; i += lote) {
      final int fin = (i + lote < puertos.length) ? i + lote : puertos.length;
      final List<DiscoveredEndpoint?> res = await Future.wait(
        <Future<DiscoveredEndpoint?>>[
          for (final int p in puertos.sublist(i, fin))
            _ping1(host, p, tls: tls),
        ],
      );
      for (final DiscoveredEndpoint? r in res) {
        if (r != null) {
          return r; // el primero del lote (puerto más bajo)
        }
      }
    }
    return null;
  }

  /// Un intento de `/ping` a `host:puerto`. En TLS aprende la huella (TOFU:
  /// acepta el cert solo para leer su SHA-256). Devuelve el endpoint si responde
  /// como un servidor NB Books; null en cualquier otro caso.
  Future<DiscoveredEndpoint?> _ping1(
    String host,
    int puerto, {
    required bool tls,
  }) async {
    final ({Dio dio, String? Function() huella}) sondeo = clienteDeSondeo(
      host,
      puerto,
      tls: tls,
      espera: _pingTimeout,
    );
    final Dio dio = sondeo.dio;
    try {
      final Response<dynamic> res = await dio.get<dynamic>('/api/v1/ping');
      final dynamic data = res.data;
      final bool ok = data is Map && data['ok'] == true;
      final bool esNbBooks = data is Map && data['servicio'] == 'NB Books';
      if (res.statusCode == 200 && ok && esNbBooks) {
        return DiscoveredEndpoint(
          host: host,
          puerto: puerto,
          fingerprint: tls ? sondeo.huella() : null,
          tls: tls,
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  /// Parsea "host", "host:puerto", "https://host:puerto" o "[ipv6]:puerto".
  /// Devuelve (host, puerto?) — puerto null si no se indicó.
  static (String, int?) _parseDireccion(String direccion) {
    String s = direccion.trim();
    s = s.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    s = s.replaceAll(RegExp(r'/+$'), '');
    final RegExpMatch? ipv6 = RegExp(r'^\[(.+)\](?::(\d+))?$').firstMatch(s);
    if (ipv6 != null) {
      final String? p = ipv6.group(2);
      return (ipv6.group(1)!.trim(), p != null ? int.tryParse(p) : null);
    }
    final int idx = s.lastIndexOf(':');
    if (idx > 0 && idx < s.length - 1) {
      final int? p = int.tryParse(s.substring(idx + 1));
      if (p != null) {
        return (s.substring(0, idx).trim(), p);
      }
    }
    return (s.trim(), null);
  }

  Future<PingResponse> ping(PairedPc pc) async {
    final Dio dio = _dioFactory(
      baseUrl: pc.baseUrl,
      fingerprint: pc.fingerprint,
    );
    final Response<dynamic> res = await dio.get<dynamic>('/api/v1/ping');
    return PingResponse.fromJson(_asMap(res.data));
  }

  Future<bool> reachable(PairedPc pc) async {
    try {
      return (await ping(pc)).ok;
    } on DioException {
      return false;
    }
  }

  Future<void> unpair() => _store.clear();

  static Map<String, dynamic> _asMap(dynamic data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};

  /// Traduce un fallo de red a un código estable para la UI. Distingue la causa
  /// real en vez del genérico "misma red": un timeout o una conexión rechazada
  /// con ambos en la misma WiFi suele ser un firewall del PC o el **aislamiento
  /// de clientes** del punto de acceso (redes de invitados/algunas mallas), no la
  /// red en sí; el mensaje genérico despistaba al usuario.
  static String _codeFor(DioException e) {
    if (e.response?.statusCode == 401) {
      return 'token_invalido_o_expirado';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'red_timeout';
      case DioExceptionType.badCertificate:
        return 'red_tls';
      case DioExceptionType.connectionError:
        return 'red_inalcanzable';
      default:
        return 'error_red';
    }
  }
}
