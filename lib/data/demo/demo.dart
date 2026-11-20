import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;

import '../../core/motor/motor.dart';
import '../db/database.dart';

/// La edición de demostración (`--dart-define=NB_SEED=true`): libros
/// inventados que se generan en el propio teléfono. Ningún texto con derechos
/// entra en el repositorio, ni siquiera para las capturas.
const bool kSembrar = bool.fromEnvironment('NB_SEED');

class _Libro {
  const _Libro(this.titulo, this.autor, this.idioma, this.capitulos);
  final String titulo;
  final String autor;
  final String idioma;
  final List<(String, List<String>)> capitulos;
}

const List<String> _frases = <String>[
  'La niebla bajaba del monte como un animal cansado y se tendía sobre los tejados.',
  'Nadie en el pueblo recordaba quién había plantado el primer almendro de la plaza.',
  'Aquella mañana el cartero trajo una carta sin remitente y con el sello del revés.',
  'El faro llevaba diez años apagado, pero los barcos seguían evitando las rocas.',
  'Marta guardaba las llaves de todas las casas, aunque ya no quedaba nadie a quien abrir.',
  'En la biblioteca municipal había un estante que siempre estaba un poco más frío.',
  'El reloj de la estación marcaba las cuatro desde que se fue el último tren.',
  'Escribir un mapa de lo que no existe exige la misma paciencia que dibujar lo real.',
  'Los cuadernos de su abuela estaban llenos de recetas que nadie se atrevía a cocinar.',
  'Cuando llovía, el río cambiaba de nombre y los vecinos cambiaban de humor.',
  'La maestra decía que cada palabra nueva es una ventana que no se puede volver a cerrar.',
  'Sobre la mesa quedaron tres tazas, dos sillas y una conversación a medias.',
];

List<String> _parrafos(int semilla, int n) => <String>[
  for (int i = 0; i < n; i++)
    <String>[
      for (int j = 0; j < 4; j++)
        _frases[(semilla * 7 + i * 3 + j * 5) % _frases.length],
    ].join(' '),
];

final List<_Libro> _libros = <_Libro>[
  _Libro(
    'El faro de las cuatro',
    'Lucía Arrabal',
    'es',
    <(String, List<String>)>[
      for (int c = 1; c <= 6; c++) ('Capítulo $c', _parrafos(c, 14)),
    ],
  ),
  _Libro(
    'Cuadernos de la plaza',
    'Tomás Herrán',
    'es',
    <(String, List<String>)>[
      for (int c = 1; c <= 5; c++) ('Cuaderno $c', _parrafos(c + 10, 12)),
    ],
  ),
  _Libro(
    'Mapas de lo que no existe',
    'Irene Solís',
    'es',
    <(String, List<String>)>[
      for (int c = 1; c <= 4; c++) ('Lección $c', _parrafos(c + 20, 16)),
    ],
  ),
];

/// Siembra los libros de demostración la primera vez, si se pidió.
Future<void> sembrarDemoSiHaceFalta(AppDatabase db, Directory docs) async {
  if (!kSembrar || await db.ajuste('demo_sembrada') == '1') {
    return;
  }
  final Directory dir = Directory('${docs.path}/telefono')
    ..createSync(recursive: true);
  for (final _Libro l in _libros) {
    final File f = File('${dir.path}/${l.titulo.hashCode}.epub')
      ..writeAsBytesSync(_epub(l));
    final String huella = await Motor.huella(f.path);
    await db
        .into(db.ediciones)
        .insertOnConflictUpdate(
          EdicionesCompanion.insert(
            id: 'telefono-${huella.split(':').last.substring(0, 32)}',
            titulo: l.titulo,
            autores: Value<String>(jsonEncode(<String>[l.autor])),
            idioma: Value<String?>(l.idioma),
            sinopsis: const Value<String?>(
              'Un libro inventado para la demostración de NB Books Mobile.',
            ),
            huella: Value<String?>(huella),
            bytes: Value<int>(f.lengthSync()),
            tipo: 'application/epub+zip',
            origen: const Value<String>('telefono'),
            ruta: Value<String?>(f.path),
            anadidaEn: ahoraIso(),
          ),
        );
  }
  await db.fijarAjuste('demo_sembrada', '1');
}

String _x(String t) =>
    t.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

Uint8List _epub(_Libro l) {
  final List<(String, List<int>)> e = <(String, List<int>)>[
    ('mimetype', utf8.encode('application/epub+zip')),
    (
      'META-INF/container.xml',
      utf8.encode(
        '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
    ),
  ];
  final StringBuffer manifiesto = StringBuffer();
  final StringBuffer lomo = StringBuffer();
  final StringBuffer nav = StringBuffer();
  for (int i = 0; i < l.capitulos.length; i++) {
    final (String titulo, List<String> parrafos) = l.capitulos[i];
    final String href = 'c${i + 1}.xhtml';
    manifiesto.write(
      '<item id="c${i + 1}" href="$href" media-type="application/xhtml+xml"/>',
    );
    lomo.write('<itemref idref="c${i + 1}"/>');
    nav.write('<li><a href="$href">${_x(titulo)}</a></li>');
    e.add((
      'OEBPS/$href',
      utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
        '<head><title>${_x(titulo)}</title></head><body><h1>${_x(titulo)}</h1>'
        '${parrafos.map((String p) => '<p>${_x(p)}</p>').join()}</body></html>',
      ),
    ));
  }
  e.add((
    'OEBPS/nav.xhtml',
    utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Índice</title></head><body>'
      '<nav epub:type="toc"><ol>$nav</ol></nav></body></html>',
    ),
  ));
  e.add((
    'OEBPS/content.opf',
    utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" '
      'version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">nb-demo-${l.titulo.hashCode}</dc:identifier>'
      '<dc:title>${_x(l.titulo)}</dc:title><dc:creator>${_x(l.autor)}</dc:creator>'
      '<dc:language>${l.idioma}</dc:language></metadata><manifest>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
      '$manifiesto</manifest><spine>$lomo</spine></package>',
    ),
  ));
  return _zipSinComprimir(e);
}

/// Un ZIP sin comprimir, que es lo que exige un EPUB para su `mimetype` y basta
/// para el resto. Escrito a mano para no traer una dependencia por esto.
Uint8List _zipSinComprimir(List<(String, List<int>)> entradas) {
  final BytesBuilder cuerpo = BytesBuilder();
  final BytesBuilder central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add(<int>[v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add(<int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);
  for (final (String nombre, List<int> datos) in entradas) {
    final List<int> n = utf8.encode(nombre);
    final int crc = _crc32(datos);
    final int desplazamiento = cuerpo.length;
    u32(cuerpo, 0x04034b50);
    u16(cuerpo, 20);
    u16(cuerpo, 0x0800);
    u16(cuerpo, 0);
    u16(cuerpo, 0);
    u16(cuerpo, 0);
    u32(cuerpo, crc);
    u32(cuerpo, datos.length);
    u32(cuerpo, datos.length);
    u16(cuerpo, n.length);
    u16(cuerpo, 0);
    cuerpo
      ..add(n)
      ..add(datos);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, crc);
    u32(central, datos.length);
    u32(central, datos.length);
    u16(central, n.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, desplazamiento);
    central.add(n);
  }
  final int inicioCentral = cuerpo.length;
  final int largoCentral = central.length;
  cuerpo.add(central.takeBytes());
  u32(cuerpo, 0x06054b50);
  u16(cuerpo, 0);
  u16(cuerpo, 0);
  u16(cuerpo, entradas.length);
  u16(cuerpo, entradas.length);
  u32(cuerpo, largoCentral);
  u32(cuerpo, inicioCentral);
  u16(cuerpo, 0);
  return cuerpo.takeBytes();
}

int _crc32(List<int> datos) {
  int crc = 0xffffffff;
  for (final int b in datos) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
