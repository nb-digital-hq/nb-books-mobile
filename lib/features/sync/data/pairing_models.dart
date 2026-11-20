/// Respuesta de `POST /api/v1/pair` (docs/architecture/pc-contract.md, sección 2).
class PairResponse {
  const PairResponse({
    required this.ok,
    required this.deviceToken,
    this.dispositivoId,
    this.error,
  });

  factory PairResponse.fromJson(Map<String, dynamic> j) => PairResponse(
    ok: j['ok'] as bool? ?? false,
    deviceToken: j['device_token'] as String? ?? '',
    dispositivoId: j['dispositivo_id'] as String?,
    error: j['error'] as String?,
  );

  final bool ok;
  final String deviceToken;
  final String? dispositivoId;
  final String? error;
}

/// Respuesta de `GET /api/v1/ping`.
class PingResponse {
  const PingResponse({
    required this.ok,
    required this.servicio,
    required this.versionProtocolo,
  });

  factory PingResponse.fromJson(Map<String, dynamic> j) => PingResponse(
    ok: j['ok'] as bool? ?? false,
    servicio: j['servicio'] as String? ?? '',
    versionProtocolo: (j['version_protocolo'] as num?)?.toInt() ?? 0,
  );

  final bool ok;
  final String servicio;
  final int versionProtocolo;
}
