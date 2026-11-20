import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'tls_pinning.dart';

// La única puerta de red de la app. Todo lo que abre una conexión se construye
// aquí, y `tool/guardianes/red.dart` rechaza cualquier cliente HTTP, socket o
// imagen remota fuera de `lib/core/network/`. Cada destino lo pide la persona:
//  - el PC emparejado (lo autoriza al escanear su QR; TLS fijado por huella);
//  - la API pública de publicaciones de GitHub, solo al pulsar "Buscar
//    actualizaciones" (Android);
//  - Wikidata y Wikimedia Commons, solo con "Fotos de autores" encendido
//    (`wikimedia.dart`, ADR-012).
// No existe telemetría ni ningún otro destino.

/// La portada de una edición servida por el PC emparejado, para la vista "Todo
/// el catálogo", que no copia nada al teléfono. El certificado lo valida
/// `NbHttpOverrides` con la huella del PC.
ImageProvider portadaDelPc(String baseUrl, String edicion, String token) =>
    NetworkImage(
      '$baseUrl/api/v1/portada/$edicion',
      headers: <String, String>{'Authorization': 'Bearer $token'},
    );

/// El canal de Leer en el PC (WebSocket), con la huella fijada.
WebSocketChannel conectarControl(
  Uri url, {
  required String fingerprint,
  required String token,
}) => IOWebSocketChannel.connect(
  url,
  customClient: pinnedHttpClient(fingerprint),
  headers: <String, dynamic>{'Authorization': 'Bearer $token'},
);

/// Cliente de sondeo de un posible PC al emparejar por dirección: acepta
/// cualquier certificado solo para aprender su huella (TOFU), que después se
/// fija para siempre.
({Dio dio, String? Function() huella}) clienteDeSondeo(
  String host,
  int puerto, {
  required bool tls,
  required Duration espera,
}) {
  String? huella;
  final HttpClient client = HttpClient()..connectionTimeout = espera;
  client.badCertificateCallback = (X509Certificate cert, String h, int p) {
    huella = sha256.convert(cert.der).toString();
    return true;
  };
  final Dio dio = Dio(
    BaseOptions(
      baseUrl: 'https://$host:$puerto',
      connectTimeout: espera,
      receiveTimeout: espera,
      sendTimeout: espera,
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => client);
  return (dio: dio, huella: () => huella);
}

/// Cliente de la API de publicaciones de GitHub (comprobación manual de
/// actualizaciones). Sin credenciales ni identificadores del dispositivo.
Dio clienteDePublicaciones() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 60),
    headers: <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'NB-Books-Mobile',
    },
  ),
);
