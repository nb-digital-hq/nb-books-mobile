import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../core/network/wikimedia.dart';
import '../../../data/db/database.dart';
import 'estantes.dart';

/// Ajuste "Fotos de autores" (ADR-012). Apagado de fábrica.
const String kFotosDeAutores = 'fotos_autores';

/// Un autor que no tiene foto en Wikidata se vuelve a mirar pasado este tiempo,
/// no en cada conexión.
const Duration kReintentoSinFoto = Duration(days: 30);

final StreamProvider<bool> fotosDeAutoresActivasProvider = StreamProvider<bool>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kFotosDeAutores)
      .map((String? v) => v == '1'),
);

/// Lo que se sabe de la foto de un autor.
class FotoDeAutor {
  const FotoDeAutor({
    this.archivo,
    this.autoria = '',
    this.licencia = '',
    this.pagina = '',
    required this.buscada,
  });

  factory FotoDeAutor.deJson(Map<String, dynamic> j) => FotoDeAutor(
    archivo: j['archivo'] as String?,
    autoria: j['autoria'] as String? ?? '',
    licencia: j['licencia'] as String? ?? '',
    pagina: j['pagina'] as String? ?? '',
    buscada: DateTime.fromMillisecondsSinceEpoch(
      (j['buscada'] as num?)?.toInt() ?? 0,
    ),
  );

  /// Ruta absoluta de la foto en el teléfono; null si no se encontró.
  final String? archivo;
  final String autoria;
  final String licencia;
  final String pagina;
  final DateTime buscada;

  Map<String, Object?> aJson() => <String, Object?>{
    'archivo': archivo,
    'autoria': autoria,
    'licencia': licencia,
    'pagina': pagina,
    'buscada': buscada.millisecondsSinceEpoch,
  };

  /// La atribución que exige la licencia de Commons, en una línea.
  String get credito => <String>[
    if (autoria.isNotEmpty) autoria,
    if (licencia.isNotEmpty) licencia,
    'Wikimedia Commons',
  ].join(' · ');
}

/// La clave de un autor en el índice: el nombre sin mayúsculas ni espacios de
/// sobra, para que "Bram Stoker" y "bram  stoker" sean el mismo.
String claveDeAutor(String nombre) =>
    nombre.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Si hace falta preguntar por [nombre]: nunca se ha buscado, o se buscó sin
/// éxito hace más de [kReintentoSinFoto].
bool hayQueBuscar(FotoDeAutor? f, DateTime ahora) =>
    f == null ||
    (f.archivo == null && ahora.difference(f.buscada) > kReintentoSinFoto);

/// Los autores de la biblioteca, sin repetir.
List<String> autoresDeLaBiblioteca(List<Edicion> libros) {
  final Map<String, String> vistos = <String, String>{};
  for (final Grupo g in agrupar(libros, Estante.autor)) {
    vistos.putIfAbsent(claveDeAutor(g.nombre), () => g.nombre);
  }
  return vistos.values.toList();
}

typedef Buscador = Future<FotoEncontrada?> Function(String nombre);

/// Las fotos de autores guardadas en el teléfono, por [claveDeAutor]. Viven en
/// `documentos/autores/` con un índice JSON; no van a la base de datos porque
/// son una caché que se puede borrar entera sin perder nada de la persona.
class FotosDeAutores extends Notifier<Map<String, FotoDeAutor>> {
  bool _enMarcha = false;

  Directory get _carpeta =>
      Directory('${ref.read(documentosProvider).path}/autores');
  File get _indice => File('${_carpeta.path}/indice.json');

  /// Sustituible en las pruebas.
  Buscador? buscador;

  @override
  Map<String, FotoDeAutor> build() {
    Future<void>(_cargar);
    return const <String, FotoDeAutor>{};
  }

  Future<void> _cargar() async {
    try {
      final Map<String, dynamic> j =
          jsonDecode(await _indice.readAsString()) as Map<String, dynamic>;
      state = <String, FotoDeAutor>{
        for (final MapEntry<String, dynamic> e in j.entries)
          e.key: FotoDeAutor.deJson(e.value as Map<String, dynamic>),
      };
    } catch (_) {
      // Sin índice o ilegible: se empieza de cero, es solo una caché.
    }
  }

  Future<void> _guardar() async {
    await _carpeta.create(recursive: true);
    await _indice.writeAsString(
      jsonEncode(<String, Object?>{
        for (final MapEntry<String, FotoDeAutor> e in state.entries)
          e.key: e.value.aJson(),
      }),
    );
  }

  /// Enciende o apaga el ajuste. Al apagarlo se borran las fotos: lo que no se
  /// quiere ver no se guarda. Al encenderlo se buscan enseguida.
  Future<void> activar(bool si) async {
    await ref
        .read(databaseProvider)
        .fijarAjuste(kFotosDeAutores, si ? '1' : '0');
    if (si) {
      await completar();
    } else {
      state = const <String, FotoDeAutor>{};
      if (await _carpeta.exists()) {
        await _carpeta.delete(recursive: true);
      }
    }
  }

  /// Busca las fotos que faltan, de una en una para no cargar a Wikimedia. Se
  /// llama al conectar con el PC y al encender el ajuste. Si se cae la red, se
  /// para y se sigue en la próxima conexión.
  Future<void> completar() async {
    final AppDatabase db = ref.read(databaseProvider);
    if (_enMarcha || await db.ajuste(kFotosDeAutores) != '1') {
      return;
    }
    _enMarcha = true;
    final Dio? dio = buscador == null ? clienteDeWikimedia() : null;
    final Buscador buscar =
        buscador ??
        (String n) => buscarFotoDeAutor(dio!, n, idioma: idiomaActivo.name);
    try {
      final List<String> autores = autoresDeLaBiblioteca(
        await db.select(db.ediciones).get(),
      );
      for (final String nombre in autores) {
        final String clave = claveDeAutor(nombre);
        final DateTime ahora = DateTime.now();
        if (!hayQueBuscar(state[clave], ahora)) {
          continue;
        }
        if (await db.ajuste(kFotosDeAutores) != '1') {
          return;
        }
        final FotoEncontrada? f;
        try {
          f = await buscar(nombre);
        } on DioException {
          return;
        }
        String? ruta;
        if (f != null) {
          await _carpeta.create(recursive: true);
          ruta =
              '${_carpeta.path}/${sha1.convert(utf8.encode(clave)).toString().substring(0, 16)}.jpg';
          await File(ruta).writeAsBytes(f.bytes, flush: true);
        }
        state = <String, FotoDeAutor>{
          ...state,
          clave: FotoDeAutor(
            archivo: ruta,
            autoria: f?.autoria ?? '',
            licencia: f?.licencia ?? '',
            pagina: f?.pagina ?? '',
            buscada: ahora,
          ),
        };
        await _guardar();
      }
    } finally {
      _enMarcha = false;
      dio?.close();
    }
  }
}

final NotifierProvider<FotosDeAutores, Map<String, FotoDeAutor>>
fotosDeAutoresProvider =
    NotifierProvider<FotosDeAutores, Map<String, FotoDeAutor>>(
      FotosDeAutores.new,
    );

/// La foto de un autor, si está activado el ajuste y se encontró.
final fotoDeAutorProvider = Provider.family<FotoDeAutor?, String>((
  Ref ref,
  String nombre,
) {
  if (!(ref.watch(fotosDeAutoresActivasProvider).value ?? false)) {
    return null;
  }
  final FotoDeAutor? f = ref.watch(
    fotosDeAutoresProvider,
  )[claveDeAutor(nombre)];
  return f?.archivo == null ? null : f;
});
