import 'dart:convert';

/// Contenido del QR de emparejamiento (docs/architecture/pc-contract.md, sección 2).
class QrPairingPayload {
  const QrPairingPayload({
    required this.host,
    required this.puerto,
    required this.token,
    this.version = 1,
    this.tlsFingerprint = '',
    this.servicio = 'NB Books',
  });

  final String host;
  final int puerto;
  final String token;
  final int version;
  final String tlsFingerprint;
  final String servicio;

  /// Intenta leer el texto crudo del QR; devuelve null si no es válido. Lo que
  /// viene de una cámara no es de fiar: cualquier fallo es "no válido".
  static QrPairingPayload? tryParse(String raw) {
    try {
      final Object? d = jsonDecode(raw);
      if (d is! Map<String, dynamic>) {
        return null;
      }
      final QrPairingPayload p = QrPairingPayload(
        host: d['host'] as String? ?? '',
        puerto: (d['puerto'] as num?)?.toInt() ?? 0,
        token: d['token'] as String? ?? '',
        version: (d['version'] as num?)?.toInt() ?? 1,
        tlsFingerprint: d['tls_fingerprint'] as String? ?? '',
        servicio: d['servicio'] as String? ?? 'NB Books',
      );
      // NB Books solo habla TLS: un QR sin huella no es suyo.
      if (p.host.isEmpty ||
          p.puerto <= 0 ||
          p.token.isEmpty ||
          p.tlsFingerprint.isEmpty) {
        return null;
      }
      return p;
    } catch (_) {
      return null;
    }
  }

  String get baseUrl => 'https://$host:$puerto';
  String get wsUrl => 'wss://$host:$puerto';
}
