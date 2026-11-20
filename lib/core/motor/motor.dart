import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'puente/api.dart' as nativo;
import 'puente/frb_generated.dart';

// La única puerta al motor de lectura de NB Books (ADR-008). Nada fuera de
// `lib/core/motor/` llama al puente generado: `tool/guardianes/motor.dart` lo
// comprueba. Aquí se traduce el JSON del motor a tipos de Dart y nada más; lo
// que el motor calcula no se vuelve a calcular en el teléfono.

/// Un fallo del motor con su código estable (`FILE_NOT_FOUND`,
/// `FORMAT_UNSUPPORTED`, ...). La interfaz lo traduce.
class MotorException implements Exception {
  const MotorException(this.codigo);
  final String codigo;
  @override
  String toString() => 'MotorException($codigo)';
}

/// Lo que el motor dice de un documento al abrirlo.
class Apertura {
  const Apertura({
    required this.id,
    required this.mediaType,
    required this.capacidades,
    required this.indice,
  });

  final BigInt id;
  final String mediaType;
  final Map<String, dynamic> capacidades;

  /// Las entradas del índice, aplanadas en orden de lectura.
  final List<EntradaDelIndice> indice;

  bool get reflow => capacidades['reflow'] == true;
  bool get seleccionDeTexto => capacidades['textSelection'] == true;
}

class EntradaDelIndice {
  const EntradaDelIndice(this.titulo, this.locator, this.nivel);
  final String titulo;
  final Map<String, dynamic> locator;
  final int nivel;
}

/// Lo que pinta una posición: marcado saneado o la imagen de una página.
sealed class Pintado {
  const Pintado();
}

class Marcado extends Pintado {
  const Marcado(this.html);
  final String html;
}

class Imagen extends Pintado {
  const Imagen(this.ruta);
  final String ruta;
}

bool _listo = false;

Future<T> _llamar<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on nativo.FalloDelMotor catch (e) {
    throw MotorException(e.codigo);
  }
}

Map<String, dynamic> _objeto(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// El motor de lectura. Una sola instancia por proceso.
abstract final class Motor {
  /// Carga la biblioteca nativa y prepara la caché. Idempotente.
  static Future<void> iniciar() async {
    if (_listo) {
      return;
    }
    await MotorNativo.init();
    final Directory cache = await getApplicationCacheDirectory();
    nativo.preparar(cache: '${cache.path}/motor');
    _listo = true;
  }

  static bool get listo => _listo;

  static List<String> tiposAdmitidos() => nativo.tiposAdmitidos();

  static int versionDelLocator() => nativo.versionDelLocator();

  static Future<Apertura> abrir(String ruta, String tipo) => _llamar(() async {
    final Map<String, dynamic> a = _objeto(
      await nativo.abrir(ruta: ruta, tipo: tipo),
    );
    final List<EntradaDelIndice> indice = <EntradaDelIndice>[];
    void aplanar(List<dynamic> entradas, int nivel) {
      for (final dynamic e in entradas) {
        final Map<String, dynamic> m = e as Map<String, dynamic>;
        indice.add(
          EntradaDelIndice(
            m['title'] as String? ?? '',
            m['locator'] as Map<String, dynamic>,
            nivel,
          ),
        );
        aplanar(m['children'] as List<dynamic>? ?? <dynamic>[], nivel + 1);
      }
    }

    aplanar(
      (a['navigation'] as Map<String, dynamic>)['entries'] as List<dynamic>,
      0,
    );
    return Apertura(
      id: BigInt.from(a['id'] as int),
      mediaType: a['mediaType'] as String,
      capacidades: a['capabilities'] as Map<String, dynamic>,
      indice: indice,
    );
  });

  static void cerrar(BigInt id) => nativo.cerrar(id: id);

  /// Pinta una posición nativa: `{kind: fragment, value: {href, offset}}` o
  /// `{kind: page, value: n}`.
  static Future<Pintado> pintar(BigInt id, Map<String, dynamic> posicion) =>
      _llamar(() async {
        final Map<String, dynamic> r = _objeto(
          await nativo.pintar(id: id, posicion: jsonEncode(posicion)),
        );
        return r['kind'] == 'image'
            ? Imagen(r['path'] as String)
            : Marcado(r['html'] as String);
      });

  /// Dónde cae un Locator: la posición nativa y su precisión.
  static Future<Map<String, dynamic>> resolver(
    BigInt id,
    Map<String, dynamic> locator,
  ) => _llamar(
    () async =>
        _objeto(await nativo.resolver(id: id, locator: jsonEncode(locator))),
  );

  static Future<Map<String, dynamic>> locatorEn(
    BigInt id,
    Map<String, dynamic> posicion,
  ) => _llamar(
    () async =>
        _objeto(await nativo.locatorEn(id: id, posicion: jsonEncode(posicion))),
  );

  /// El Locator de una cita: así se ancla una selección y se apunta dónde se
  /// quedó la lectura, igual que en el PC.
  static Future<Map<String, dynamic>> locatorDeCita(
    BigInt id,
    String cita, {
    double? pista,
  }) => _llamar(
    () async =>
        _objeto(await nativo.locatorDeCita(id: id, cita: cita, pista: pista)),
  );

  static Future<String> textoDesde(
    BigInt id,
    Map<String, dynamic> locator,
    int largo,
  ) => _llamar(
    () => nativo.textoDesde(id: id, locator: jsonEncode(locator), largo: largo),
  );

  static Future<Map<String, dynamic>> tamanoDePagina(
    BigInt id,
    Map<String, dynamic> posicion,
  ) => _llamar(
    () async => _objeto(
      await nativo.tamanoDePagina(id: id, posicion: jsonEncode(posicion)),
    ),
  );

  /// Los fragmentos de texto con su Locator, para buscar dentro de un libro.
  static Future<List<(Map<String, dynamic>, String)>> fragmentos(
    BigInt id, {
    int maximo = 1200,
  }) => _llamar(() async {
    final List<dynamic> l =
        jsonDecode(await nativo.fragmentos(id: id, maximo: maximo))
            as List<dynamic>;
    return <(Map<String, dynamic>, String)>[
      for (final dynamic par in l)
        ((par as List<dynamic>)[0] as Map<String, dynamic>, par[1] as String),
    ];
  });

  /// Título, autoría e idioma que declara el propio archivo.
  static Future<Map<String, dynamic>> metadatos(String ruta, String tipo) =>
      _llamar(
        () async => _objeto(await nativo.metadatos(ruta: ruta, tipo: tipo)),
      );

  /// Los capítulos de un EPUB en orden de lectura.
  static Future<List<String>> lomo(String ruta) =>
      _llamar(() => nativo.lomo(ruta: ruta));

  /// La huella `sha256:...` de un archivo, la misma que calcula el PC.
  static Future<String> huella(String ruta) =>
      _llamar(() => nativo.huella(ruta: ruta));

  /// Reproduce los repasos de una tarjeta sobre su base con el SM-2 del PC.
  static Future<Map<String, dynamic>> reproducirRepasos({
    required Map<String, dynamic> base,
    required List<(String, String)> repasos,
  }) => _llamar(() async {
    final String entrada = jsonEncode(<String, Object?>{
      'repeticiones': base['repeticiones'] ?? 0,
      'intervaloDias': base['intervalo_dias'] ?? 0,
      'facilidad': base['facilidad'] ?? 2.5,
      'venceEn': base['vence_en'],
      'repasadaEn': base['repasada_en'],
      'repasos': <List<String>>[
        for (final (String cuando, String cal) in repasos)
          <String>[cuando, cal],
      ],
    });
    return _objeto(await nativo.reproducirRepasos(entrada: entrada));
  });
}
