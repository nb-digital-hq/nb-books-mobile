import 'dart:typed_data';

import 'package:dio/dio.dart';

// Tercer destino (ADR-012): Wikidata y Wikimedia Commons, para las fotos de
// autores. Solo si la persona enciende "Fotos de autores" en Configuración, y
// solo se envía el nombre de cada autor. Nada de esto toca el PC.

/// Los únicos anfitriones a los que se pregunta. Una URL de otro sitio que
/// devolviera Wikidata o Commons no se sigue.
const Set<String> kAnfitrionesWikimedia = <String>{
  'www.wikidata.org',
  'commons.wikimedia.org',
  'upload.wikimedia.org',
  'thumb.wikimedia.org',
};

/// Ocupaciones de Wikidata (P106) que cuentan como "escribe libros". Exigir una
/// evita la foto de un homónimo futbolista o actor.
const Set<String> kOcupacionesDeAutor = <String>{
  'Q36180', // escritor
  'Q6625963', // novelista
  'Q49757', // poeta
  'Q482980', // autor
  'Q214917', // dramaturgo
  'Q11774202', // ensayista
  'Q4853732', // escritor de literatura infantil
  'Q18844224', // escritor de ciencia ficción
  'Q1930187', // periodista
  'Q4964182', // filósofo
  'Q1231865', // pedagogo
  'Q201788', // historiador
  'Q901', // científico
  'Q1622272', // profesor universitario
  'Q28389', // guionista
  'Q333634', // traductor
  'Q15949613', // cuentista
  'Q12144794', // prosista
  'Q3332711', // escritor de ficción
};

/// Una foto encontrada, con lo que su licencia exige mostrar.
class FotoEncontrada {
  const FotoEncontrada({
    required this.bytes,
    required this.autoria,
    required this.licencia,
    required this.pagina,
  });

  final Uint8List bytes;

  /// Quién hizo la foto, en texto plano (puede venir vacío).
  final String autoria;

  /// Nombre corto de la licencia, p. ej. "CC BY-SA 4.0" o "Public domain".
  final String licencia;

  /// La página del archivo en Commons, para la atribución.
  final String pagina;
}

/// Cliente de Wikimedia. El agente identifica la app, como pide la política de
/// Wikimedia, sin nada del dispositivo ni de la persona.
Dio clienteDeWikimedia() {
  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: <String, String>{
        'User-Agent':
            'NB-Books-Mobile/1.0 (https://github.com/nb-digital-hq/nb-books-mobile)',
      },
      followRedirects: false,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (RequestOptions o, RequestInterceptorHandler h) {
        if (o.uri.scheme != 'https' ||
            !kAnfitrionesWikimedia.contains(o.uri.host)) {
          h.reject(DioException(requestOptions: o, message: 'destino ajeno'));
          return;
        }
        h.next(o);
      },
    ),
  );
  return dio;
}

/// Busca la foto de un autor: candidatos de Wikidata por nombre, el primero que
/// sea una persona con oficio de escritor y foto (P18), y esa foto de Commons a
/// 400 px. Null si no hay ninguna; lanza [DioException] si falla la red.
Future<FotoEncontrada?> buscarFotoDeAutor(
  Dio dio,
  String nombre, {
  String idioma = 'en',
}) async {
  final Map<String, dynamic> busqueda =
      await _json(dio, 'https://www.wikidata.org/w/api.php', <String, String>{
        'action': 'wbsearchentities',
        'search': nombre,
        'language': idioma,
        'uselang': idioma,
        'type': 'item',
        'limit': '7',
        'format': 'json',
      });
  final List<String> ids = idsDeBusqueda(busqueda);
  if (ids.isEmpty) {
    return null;
  }
  final Map<String, dynamic> entidades =
      await _json(dio, 'https://www.wikidata.org/w/api.php', <String, String>{
        'action': 'wbgetentities',
        'ids': ids.join('|'),
        'props': 'claims',
        'format': 'json',
      });
  final String? archivo = archivoDeAutor(entidades, ids);
  if (archivo == null) {
    return null;
  }
  final Map<String, dynamic> info = await _json(
    dio,
    'https://commons.wikimedia.org/w/api.php',
    <String, String>{
      'action': 'query',
      'titles': 'File:$archivo',
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata',
      'iiurlwidth': '400',
      'format': 'json',
    },
  );
  final ({String url, String autoria, String licencia, String pagina})? img =
      imagenDeCommons(info);
  if (img == null) {
    return null;
  }
  final Response<List<int>> r = await dio.get<List<int>>(
    img.url,
    options: Options(responseType: ResponseType.bytes),
  );
  final List<int>? bytes = r.data;
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  return FotoEncontrada(
    bytes: Uint8List.fromList(bytes),
    autoria: img.autoria,
    licencia: img.licencia,
    pagina: img.pagina,
  );
}

Future<Map<String, dynamic>> _json(
  Dio dio,
  String url,
  Map<String, String> q,
) async {
  final Response<Map<String, dynamic>> r = await dio.get<Map<String, dynamic>>(
    url,
    queryParameters: q,
  );
  return r.data ?? const <String, dynamic>{};
}

/// Los identificadores de una respuesta de `wbsearchentities`, en su orden.
List<String> idsDeBusqueda(Map<String, dynamic> j) => <String>[
  for (final Object? e in (j['search'] as List<Object?>? ?? const <Object?>[]))
    if (e is Map<String, dynamic> && e['id'] is String) e['id'] as String,
];

/// El archivo de Commons (P18) del primer candidato, en el orden de [ids], que
/// sea una persona (P31 = Q5) con un oficio de [kOcupacionesDeAutor].
String? archivoDeAutor(Map<String, dynamic> j, List<String> ids) {
  final Map<String, dynamic> todas =
      j['entities'] as Map<String, dynamic>? ?? const <String, dynamic>{};
  for (final String id in ids) {
    final Map<String, dynamic>? claims =
        (todas[id] as Map<String, dynamic>?)?['claims']
            as Map<String, dynamic>?;
    if (claims == null) {
      continue;
    }
    final Set<String> instancia = _valoresItem(claims['P31']);
    final Set<String> oficios = _valoresItem(claims['P106']);
    if (!instancia.contains('Q5') ||
        oficios.intersection(kOcupacionesDeAutor).isEmpty) {
      continue;
    }
    for (final Object? c in (claims['P18'] as List<Object?>? ?? const [])) {
      final Object? v = _valor(c);
      if (v is String && v.isNotEmpty) {
        return v;
      }
    }
  }
  return null;
}

/// La miniatura, la autoría y la licencia de una respuesta de `imageinfo`.
({String url, String autoria, String licencia, String pagina})? imagenDeCommons(
  Map<String, dynamic> j,
) {
  final Map<String, dynamic>? paginas =
      (j['query'] as Map<String, dynamic>?)?['pages'] as Map<String, dynamic>?;
  for (final Object? p in paginas?.values ?? const <Object?>[]) {
    final List<Object?>? info =
        (p as Map<String, dynamic>?)?['imageinfo'] as List<Object?>?;
    final Map<String, dynamic>? i = info?.firstOrNull as Map<String, dynamic>?;
    if (i == null) {
      continue;
    }
    final String url = (i['thumburl'] ?? i['url'] ?? '') as String;
    final Uri? u = Uri.tryParse(url);
    if (u == null ||
        u.scheme != 'https' ||
        !kAnfitrionesWikimedia.contains(u.host)) {
      continue;
    }
    final Map<String, dynamic> meta =
        i['extmetadata'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    String campo(String k) => textoPlano(
      ((meta[k] as Map<String, dynamic>?)?['value'] ?? '').toString(),
    );
    return (
      // Sin los parámetros de campaña que Commons añade a la miniatura.
      url: Uri(scheme: 'https', host: u.host, path: u.path).toString(),
      autoria: campo('Artist'),
      licencia: campo('LicenseShortName'),
      pagina: (i['descriptionurl'] ?? '') as String,
    );
  }
  return null;
}

/// Commons da la autoría en HTML; aquí se enseña como texto.
String textoPlano(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Object? _valor(Object? claim) =>
    (((claim as Map<String, dynamic>?)?['mainsnak']
            as Map<String, dynamic>?)?['datavalue']
        as Map<String, dynamic>?)?['value'];

Set<String> _valoresItem(Object? lista) => <String>{
  for (final Object? c in (lista as List<Object?>? ?? const <Object?>[]))
    if (_valor(c) case final Map<String, dynamic> v when v['id'] is String)
      v['id'] as String,
};
