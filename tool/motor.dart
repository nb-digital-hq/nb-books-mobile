import 'dart:io';

import 'package:crypto/crypto.dart';

// Compila el motor de lectura para Android y deja junto a él la biblioteca de
// PDF, una por ABI, en `android/app/src/main/jniLibs/`. Es lo que hace
// `just setup` y la CI antes de `flutter build`.
//
// La biblioteca de PDF es la misma versión que usa NB Books en el escritorio
// (`scripts/fetch-pdfium.mjs`), sin motor de JavaScript, y se comprueba por su
// huella antes de tocar el disco: un archivo distinto no se instala.
//
// Uso: `dart run tool/motor.dart [--sin-pdfium]`.

const String _versionPdfium = 'chromium/7881';

class _Abi {
  const _Abi(this.android, this.rust, this.pdfium, this.huella);
  final String android;
  final String rust;
  final String pdfium;
  final String huella;
}

const List<_Abi> _abis = <_Abi>[
  _Abi(
    'arm64-v8a',
    'aarch64-linux-android',
    'pdfium-android-arm64.tgz',
    '16d23bb86c4188d59326dc509938f59df3c417ecfdd3d2ca2f160dc5bd49a839',
  ),
  _Abi(
    'armeabi-v7a',
    'armv7-linux-androideabi',
    'pdfium-android-arm.tgz',
    '57f7f5c349a3268f39b1737f830e50e271aa3116417abed2c30d0c0840b1b58b',
  ),
  _Abi(
    'x86_64',
    'x86_64-linux-android',
    'pdfium-android-x64.tgz',
    '58bd708d6083173008c63860dbffa93396a2fee00dd76747cbd782bcf4ff9bd4',
  ),
];

const String _jniLibs = 'android/app/src/main/jniLibs';

Future<int> _correr(String programa, List<String> args, {String? en}) async {
  final Process p = await Process.start(
    programa,
    args,
    workingDirectory: en,
    mode: ProcessStartMode.inheritStdio,
  );
  return p.exitCode;
}

Future<bool> _pdfium(_Abi abi) async {
  final File destino = File('$_jniLibs/${abi.android}/libpdfium.so');
  final File sello = File('$_jniLibs/${abi.android}/.pdfium');
  final String esperado = '$_versionPdfium ${abi.huella}\n';
  if (destino.existsSync() &&
      sello.existsSync() &&
      sello.readAsStringSync() == esperado) {
    return true;
  }
  final Uri url = Uri.parse(
    'https://github.com/bblanchon/pdfium-binaries/releases/download/'
    '$_versionPdfium/${abi.pdfium}',
  );
  final HttpClient cliente = HttpClient();
  try {
    final HttpClientRequest peticion = await cliente.getUrl(url);
    final HttpClientResponse respuesta = await peticion.close();
    if (respuesta.statusCode != 200) {
      stderr.writeln('PDFium ${abi.android}: HTTP ${respuesta.statusCode}');
      return false;
    }
    final List<int> bytes = <int>[
      for (final List<int> trozo in await respuesta.toList()) ...trozo,
    ];
    final String obtenida = sha256.convert(bytes).toString();
    if (obtenida != abi.huella) {
      stderr.writeln(
        'PDFium ${abi.android}: la huella no coincide, no se instala.\n'
        '  esperada: ${abi.huella}\n  obtenida: $obtenida',
      );
      return false;
    }
    final Directory tmp = Directory.systemTemp.createTempSync('nb-pdfium-');
    try {
      final File tgz = File('${tmp.path}/${abi.pdfium}')
        ..writeAsBytesSync(bytes);
      if (await _correr('tar', <String>[
            'xzf',
            tgz.path,
            '-C',
            tmp.path,
            'lib/libpdfium.so',
            'LICENSE',
          ]) !=
          0) {
        return false;
      }
      destino.parent.createSync(recursive: true);
      File('${tmp.path}/lib/libpdfium.so').copySync(destino.path);
      sello.writeAsStringSync(esperado);
    } finally {
      tmp.deleteSync(recursive: true);
    }
    return true;
  } finally {
    cliente.close();
  }
}

Future<void> main(List<String> args) async {
  final bool conPdfium = !args.contains('--sin-pdfium');
  final List<String> objetivos = <String>[
    for (final _Abi abi in _abis) ...<String>['-t', abi.android],
  ];
  final int compilado = await _correr('cargo', <String>[
    'ndk',
    ...objetivos,
    '-o',
    '../$_jniLibs',
    'build',
    '--release',
  ], en: 'native');
  if (compilado != 0) {
    stderr.writeln('No se pudo compilar el motor para Android.');
    exit(compilado);
  }
  // `cargo ndk` copia también las bibliotecas dinámicas de las dependencias que
  // las declaran; el motor ya las lleva enlazadas dentro, y sobran en el APK.
  for (final _Abi abi in _abis) {
    final Directory dir = Directory('$_jniLibs/${abi.android}');
    for (final FileSystemEntity f in dir.listSync()) {
      final String nombre = f.uri.pathSegments.last;
      if (nombre.endsWith('.so') &&
          nombre != 'libnb_books_motor.so' &&
          nombre != 'libpdfium.so') {
        f.deleteSync();
      }
    }
  }
  if (conPdfium) {
    for (final _Abi abi in _abis) {
      if (!await _pdfium(abi)) exit(1);
    }
  }
  stdout.writeln(
    'Motor listo para ${_abis.map((_Abi a) => a.android).join(', ')}.',
  );
}
