import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:nb_books_mobile/core/security/secure_store.dart';

/// Un PC de mentira: responde con las respuestas grabadas por NB Books en
/// `test/fixtures/contrato-pc/` y apunta lo que el teléfono le envía.
class PcFalso implements HttpClientAdapter {
  PcFalso({this.manifiesto});

  /// Manifiesto que se sirve en lugar del grabado.
  Map<String, dynamic>? manifiesto;

  final List<Map<String, dynamic>> envios = <Map<String, dynamic>>[];

  static const PairedPc pc = PairedPc(
    deviceToken: 't',
    fingerprint: null,
    host: '127.0.0.1',
    port: 8831,
    nombre: 'PC',
  );

  static Map<String, dynamic> grabada(String nombre) =>
      jsonDecode(
            File('test/fixtures/contrato-pc/$nombre.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  Dio dio() => Dio(BaseOptions(baseUrl: pc.baseUrl))..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object cuerpo;
    switch (o.path) {
      case '/api/v1/manifest':
        cuerpo = manifiesto ?? grabada('manifest');
      case '/api/v1/cambios':
        envios.add(o.data as Map<String, dynamic>);
        cuerpo = <String, dynamic>{
          'resultado': <String, dynamic>{'rechazados': <String>[]},
        };
      default:
        cuerpo = grabada(o.path.split('/').last);
    }
    return ResponseBody.fromString(
      jsonEncode(cuerpo),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
