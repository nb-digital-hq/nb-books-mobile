import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../library/presentation/libro_widgets.dart' show porcentajeLegible;
import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../core/motor/motor.dart';
import '../../../core/utils/ids.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/theme_controller.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../sync/application/sync_controller.dart';
import '../application/ajustes_de_lectura.dart';
import 'ajustes_de_lectura_sheet.dart';
import 'lector_html.dart';

/// El lector: un capítulo saneado por el motor de NB Books en una vista web, o
/// la página de un PDF o un cómic como imagen. Toda posición es un Locator que
/// calcula el motor; la vista solo dice qué cita está mirando.
class LectorScreen extends ConsumerStatefulWidget {
  const LectorScreen({super.key, required this.edicionId, this.destino});

  final String edicionId;

  /// Un Locator al que ir al abrir: un resultado de búsqueda, una anotación o
  /// la posición del PC. Sin él, donde se quedó este teléfono.
  final Map<String, dynamic>? destino;

  @override
  ConsumerState<LectorScreen> createState() => _LectorScreenState();
}

class _LectorScreenState extends ConsumerState<LectorScreen> {
  Edicion? _edicion;
  Apertura? _apertura;
  List<String> _lomo = const <String>[];
  String? _fallo;

  // Texto (EPUB).
  WebViewController? _web;
  bool _webLista = false;
  bool _reintentado = false;
  static const MethodChannel _canalLector = MethodChannel('com.nbbooks/lector');
  Timer? _vigilante;
  int _capitulo = 0;
  double _progresoCapitulo = 0;
  int _paginaCap = 0;
  int _paginasCap = 1;

  /// Mientras se arrastra la barra de posición, a dónde iría.
  double? _arrastre;

  /// Dónde empieza cada recurso del lomo en el texto del libro, de 0 a 1. Es
  /// la escala de la barra de posición y del porcentaje, la misma que la de la
  /// biblioteca.
  List<double> _inicios = const <double>[];

  /// El título de cada recurso del lomo, del índice del libro.
  final Map<String, String> _titulos = <String, String>{};
  Map<String, dynamic>? _pendiente;

  // Imagen (PDF y cómic).
  int _pagina = 1;
  String? _imagen;

  bool _controles = false;
  String _seleccion = '';
  Map<String, dynamic>? _locatorActual;
  // Se toma al crear la pantalla. Con `late` se evaluaba la primera vez que
  // se leía, que era al cerrar: toda sesión duraba cero segundos.
  final String _inicioSesion = ahoraIso();
  Map<String, dynamic>? _desdeSesion;

  final FlutterTts _tts = FlutterTts();
  bool _hablando = false;
  Timer? _avance;
  double _velocidad = 0;
  Timer? _guardar;

  // Se guardan al montar: al cerrar el lector hay que apuntar la sesión, y
  // en `dispose` ya no se puede leer de los proveedores.
  late final AppDatabase _db;
  late final SyncController _sync;
  bool get _esTexto => _apertura?.reflow ?? false;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseProvider);
    _sync = ref.read(syncProvider.notifier);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_abrir());
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _avance?.cancel();
    _guardar?.cancel();
    _vigilante?.cancel();
    _canalLector.setMethodCallHandler(null);
    unawaited(_tts.stop());
    unawaited(_cerrarSesion());
    final Apertura? a = _apertura;
    if (a != null) {
      Motor.cerrar(a.id);
    }
    super.dispose();
  }

  // --- Abrir --------------------------------------------------------------

  Future<void> _abrir() async {
    try {
      final Edicion? e = await _db.edicion(widget.edicionId);
      // Descargado, o traído a la caché para leer sin descargar.
      final String? ruta = e == null
          ? null
          : e.ruta != null && File(e.ruta!).existsSync()
          ? e.ruta
          : ref.read(syncRepositoryProvider).temporalDe(e)?.path;
      if (e == null || ruta == null) {
        setState(() => _fallo = tr('Este libro no está en el teléfono.'));
        return;
      }
      final Apertura a = await Motor.abrir(ruta, e.tipo);
      List<String> lomo = const <String>[];
      if (a.reflow) {
        lomo = await Motor.lomo(ruta);
      }
      Map<String, dynamic>? destino = widget.destino;
      if (destino == null) {
        final Posicion? p = await _db.posicion(e.id, 'telefono');
        if (p != null) {
          destino = jsonDecode(p.locator) as Map<String, dynamic>;
        }
      }
      setState(() {
        _edicion = e;
        _apertura = a;
        _lomo = lomo;
        for (final EntradaDelIndice x in a.indice) {
          final Object? h = x.locator['href'];
          if (h is String) {
            _titulos.putIfAbsent(h.split('#').first, () => x.titulo);
          }
        }
      });
      if (a.reflow) {
        _prepararWeb();
        unawaited(_medirCapitulos(a.id, lomo));
        await _ir(destino);
      } else {
        await _irAPagina(await _paginaDe(destino) ?? 1);
      }
    } on MotorException catch (e) {
      setState(() => _fallo = mensajeDelMotor(e.codigo));
    }
  }

  void _prepararWeb() {
    // Solo en depuración: en publicación nadie puede inspeccionar la página.
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(AndroidWebViewController.enableDebugging(true));
    }
    final WebViewController w = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('NB', onMessageReceived: _alMensaje)
      // Nada sale de la página: el capítulo ya viene saneado, y un enlace a la
      // red no se sigue nunca.
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest r) =>
              r.url.startsWith('about:') || r.url.startsWith('data:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
    _web = w;
    // En Android la página se carga cuando la vista ya está puesta y con la
    // prioridad fijada (MainActivity.mantenerLectores); si el aviso no llega,
    // se carga igual al poco.
    bool cargada = false;
    void cargar() {
      if (cargada || !mounted || _web != w) {
        return;
      }
      cargada = true;
      unawaited(w.loadHtmlString(kLectorHtml));
      _vigilante?.cancel();
      _vigilante = Timer(const Duration(seconds: 10), _sinRespuesta);
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      _canalLector.setMethodCallHandler((MethodCall c) async {
        if (c.method == 'vista') {
          cargar();
        }
      });
      Timer(const Duration(milliseconds: 1500), cargar);
    } else {
      cargar();
    }
  }

  /// Hay teléfonos que congelan el proceso del WebView mientras la app está en
  /// segundo plano y no siempre lo despiertan al volver: la página se queda en
  /// blanco sin decir nada. Se intenta una vez con otra página y, si tampoco
  /// responde, se dice qué hacer en lugar de dejar una hoja vacía.
  void _sinRespuesta() {
    if (!mounted || _webLista) {
      return;
    }
    if (!_reintentado) {
      _reintentado = true;
      setState(_prepararWeb);
      return;
    }
    setState(
      () => _fallo = tr(
        'El lector no responde. Cierra NB Books del todo y vuelve a abrirlo.',
      ),
    );
  }

  // --- Posiciones ---------------------------------------------------------

  Future<int?> _paginaDe(Map<String, dynamic>? locator) async {
    if (locator == null) {
      return null;
    }
    try {
      final Map<String, dynamic> r = await Motor.resolver(
        _apertura!.id,
        locator,
      );
      final Map<String, dynamic> p = r['position'] as Map<String, dynamic>;
      return p['kind'] == 'page' ? (p['value'] as num).toInt() : null;
    } on MotorException {
      return null;
    }
  }

  /// Va a un Locator: resuelve su capítulo con el motor y lo sitúa por su cita.
  Future<void> _ir(Map<String, dynamic>? locator) async {
    int capitulo = 0;
    Map<String, dynamic> situar = <String, dynamic>{};
    if (locator != null) {
      try {
        final Map<String, dynamic> r = await Motor.resolver(
          _apertura!.id,
          locator,
        );
        final Map<String, dynamic> p = r['position'] as Map<String, dynamic>;
        if (p['kind'] == 'fragment') {
          final String href =
              (p['value'] as Map<String, dynamic>)['href'] as String;
          capitulo = math.max(0, _lomo.indexOf(href));
        }
        final Map<String, dynamic>? texto =
            locator['text'] as Map<String, dynamic>?;
        final Map<String, dynamic>? loc =
            locator['locations'] as Map<String, dynamic>?;
        situar = <String, dynamic>{
          'cita': texto?['highlight'],
          'progresion': (loc?['progression'] as num?)?.toDouble() ?? 0,
        };
      } on MotorException {
        // Un Locator que ya no resuelve abre el principio, y se dice.
        _avisar(tr('No se encontró esa posición; se abre el principio.'));
      }
    }
    _desdeSesion ??= locator;
    await _pintarCapitulo(capitulo, situar);
  }

  Future<void> _pintarCapitulo(int i, Map<String, dynamic> situar) async {
    if (_lomo.isEmpty || i < 0 || i >= _lomo.length) {
      return;
    }
    final Pintado p = await Motor.pintar(_apertura!.id, <String, dynamic>{
      'kind': 'fragment',
      'value': <String, dynamic>{'href': _lomo[i], 'offset': 0},
    });
    if (p is! Marcado || !mounted) {
      return;
    }
    _capitulo = i;
    final String html = _conImagenesEnLinea(p.html);
    final String orden =
        'nb.cargar(${jsonEncode(html)}, ${jsonEncode(situar)});';
    if (_webLista) {
      await _aplicarEstilo();
      await _web!.runJavaScript(orden);
      await _pintarMarcas();
    } else {
      _pendiente = <String, dynamic>{'orden': orden};
    }
    setState(() {});
  }

  /// Las imágenes del capítulo vienen como rutas de la caché del motor; la vista
  /// no lee archivos, así que viajan dentro del marcado.
  String _conImagenesEnLinea(String html) =>
      html.replaceAllMapped(RegExp(r'''src="(/[^"]+)"'''), (Match m) {
        final File f = File(m.group(1)!);
        if (!f.existsSync()) {
          return m.group(0)!;
        }
        final String ext = f.path.split('.').last.toLowerCase();
        final String tipo = switch (ext) {
          'png' => 'image/png',
          'gif' => 'image/gif',
          'svg' => 'image/svg+xml',
          'webp' => 'image/webp',
          _ => 'image/jpeg',
        };
        return 'src="data:$tipo;base64,${base64Encode(f.readAsBytesSync())}"';
      });

  Future<void> _aplicarEstilo() async {
    if (_web == null) {
      return;
    }
    final AjustesDeLectura a = ref.read(ajustesDeLecturaProvider);
    final NbColors c = context.nb;
    final (Color fondo, Color texto) = a.colores(c.bg, c.text);
    await _web!.runJavaScript(
      'nb.estilo(${jsonEncode(<String, dynamic>{'fondo': cssDe(fondo), 'texto': cssDe(texto), 'acento': cssDe(c.accent), 'tam': a.tamano, 'interlineado': a.interlineado, 'margen': a.margen, 'fuente': a.serif ? "Georgia, 'Noto Serif', serif" : "'Roboto', 'Noto Sans', sans-serif", 'justificar': a.justificar, 'paginado': a.paginado})});',
    );
  }

  Future<void> _pintarMarcas() async {
    if (_web == null || _edicion == null) {
      return;
    }
    final List<Anotacion> todas = await _db
        .vigilarAnotaciones(_edicion!.id)
        .first;
    final List<Map<String, dynamic>> marcas = <Map<String, dynamic>>[];
    for (final Anotacion a in todas) {
      if (a.tipo == 'bookmark' || a.tipo == 'ink') {
        continue;
      }
      final Map<String, dynamic> l =
          jsonDecode(a.locator) as Map<String, dynamic>;
      if (l['href'] != _lomo[_capitulo]) {
        continue;
      }
      final Map<String, dynamic>? t = l['text'] as Map<String, dynamic>?;
      final String? cita = t?['highlight'] as String?;
      if (cita != null) {
        marcas.add(<String, dynamic>{
          'id': a.id,
          'tipo': a.tipo,
          'cita': cita,
          'antes': t?['before'],
        });
      }
    }
    await _web!.runJavaScript('nb.marcar(${jsonEncode(marcas)});');
  }

  Future<void> _alMensaje(JavaScriptMessage m) async {
    final Map<String, dynamic> d =
        jsonDecode(m.message) as Map<String, dynamic>;
    switch (d['tipo']) {
      case 'listo':
        _webLista = true;
        _vigilante?.cancel();
        await _aplicarEstilo();
        final Map<String, dynamic>? p = _pendiente;
        _pendiente = null;
        if (p != null) {
          await _web!.runJavaScript(p['orden'] as String);
          await _pintarMarcas();
        }
      case 'posicion':
        _progresoCapitulo = (d['progresion'] as num?)?.toDouble() ?? 0;
        _paginaCap = (d['pagina'] as num?)?.toInt() ?? 0;
        _paginasCap = (d['paginas'] as num?)?.toInt() ?? 1;
        final String? cita = d['cita'] as String?;
        if (cita != null) {
          _apuntar(cita);
        }
        if (mounted) {
          setState(() {});
        }
      case 'seleccion':
        if (mounted) {
          setState(() => _seleccion = (d['texto'] as String? ?? '').trim());
        }
      case 'pasar':
        await _pasar((d['dir'] as num).toInt());
      case 'toque':
        final int zona = (d['zona'] as num).toInt();
        if (zona == 0) {
          setState(() => _controles = !_controles);
        } else {
          await _pasar(zona);
        }
      case 'marca':
        await _abrirMarca(d['id'] as String);
    }
  }

  /// Apunta dónde va la lectura. El Locator lo construye el motor a partir de
  /// la cita, igual que en el PC; se escribe al parar, no en cada paso.
  void _apuntar(String cita) {
    _guardar?.cancel();
    _guardar = Timer(const Duration(milliseconds: 500), () async {
      try {
        final double pista = _dondeVoy();
        final Map<String, dynamic> l = await Motor.locatorDeCita(
          _apertura!.id,
          cita,
          pista: pista,
        );
        // Un párrafo que se repite en otro capítulo puede anclarse allí: lo
        // que se ve está en este, así que esa posición no se guarda.
        if (_lomo.isNotEmpty && l['href'] != _lomo[_capitulo]) {
          return;
        }
        _locatorActual = l;
        _desdeSesion ??= l;
        await _db.apuntarPosicion(
          _edicion!.id,
          jsonEncode(l),
          ((l['locations'] as Map<String, dynamic>?)?['totalProgression']
                  as num?)
              ?.toDouble(),
        );
        if (mounted) {
          setState(() {});
        }
      } on MotorException {
        // Una cita que el motor no ancla no mueve la posición guardada.
      }
    });
  }

  Future<void> _pasar(int dir) async {
    if (!_esTexto) {
      await _irAPagina(_pagina + dir);
      return;
    }
    final Object r = await _web!.runJavaScriptReturningResult(
      'nb.pagina($dir)',
    );
    final bool movio = r == true || r.toString() == 'true';
    if (!movio) {
      await _cambiarCapitulo(dir);
    }
  }

  Future<void> _cambiarCapitulo(int dir) async {
    final int n = _capitulo + dir;
    if (n < 0 || n >= _lomo.length) {
      return;
    }
    await _pintarCapitulo(
      n,
      dir < 0 ? <String, dynamic>{'alFinal': true} : <String, dynamic>{},
    );
  }

  // --- Imágenes -----------------------------------------------------------

  Future<void> _irAPagina(int n) async {
    if (n < 1) {
      return;
    }
    try {
      final Pintado p = await Motor.pintar(_apertura!.id, <String, dynamic>{
        'kind': 'page',
        'value': n,
      });
      if (p is! Imagen) {
        return;
      }
      final Map<String, dynamic> l = await Motor.locatorEn(
        _apertura!.id,
        <String, dynamic>{'kind': 'page', 'value': n},
      );
      _locatorActual = l;
      _desdeSesion ??= l;
      await _db.apuntarPosicion(
        _edicion!.id,
        jsonEncode(l),
        ((l['locations'] as Map<String, dynamic>?)?['totalProgression'] as num?)
            ?.toDouble(),
      );
      setState(() {
        _pagina = n;
        _imagen = p.ruta;
      });
    } on MotorException {
      // Más allá de la última página no hay nada que pintar.
    }
  }

  // --- Sesión, anotaciones y voz -----------------------------------------

  Future<void> _cerrarSesion() async {
    final Edicion? e = _edicion;
    final Map<String, dynamic>? desde = _desdeSesion;
    if (e == null || desde == null) {
      return;
    }
    await _db
        .into(_db.sesiones)
        .insert(
          SesionesCompanion.insert(
            id: nuevoId(),
            edicion: e.id,
            inicio: _inicioSesion,
            fin: Value<String?>(ahoraIso()),
            desde: jsonEncode(desde),
            hasta: Value<String?>(
              _locatorActual == null ? null : jsonEncode(_locatorActual),
            ),
            pendiente: const Value<bool>(true),
          ),
        );
    unawaited(_sync.sincronizar());
  }

  Future<void> _anotar(String tipo, {String? nota, String? seleccion}) async {
    final String cita = seleccion ?? _seleccion;
    if (cita.isEmpty || _edicion == null) {
      return;
    }
    try {
      final double pista = _dondeVoy();
      final Map<String, dynamic> l = await Motor.locatorDeCita(
        _apertura!.id,
        cita,
        pista: pista,
      );
      await _db.anotar(
        AnotacionesCompanion.insert(
          id: nuevoId(),
          edicion: _edicion!.id,
          tipo: tipo,
          texto: Value<String?>(nota),
          locator: jsonEncode(l),
          creadaEn: ahoraIso(),
          pendiente: const Value<bool>(true),
        ),
      );
      await _web?.runJavaScript('nb.soltarSeleccion();');
      setState(() => _seleccion = '');
      await _pintarMarcas();
      _avisar(switch (tipo) {
        'highlight' => tr('Resaltado guardado.'),
        'underline' => tr('Subrayado guardado.'),
        _ => tr('Nota guardada.'),
      });
    } on MotorException catch (e) {
      _avisar(mensajeDelMotor(e.codigo));
    }
  }

  Future<void> _marcador() async {
    final Map<String, dynamic>? l = _locatorActual;
    if (l == null || _edicion == null) {
      return;
    }
    await _db.anotar(
      AnotacionesCompanion.insert(
        id: nuevoId(),
        edicion: _edicion!.id,
        tipo: 'bookmark',
        locator: jsonEncode(l),
        creadaEn: ahoraIso(),
        pendiente: const Value<bool>(true),
      ),
    );
    _avisar(tr('Marcador puesto.'));
  }

  Future<void> _escribirNota() async {
    // La selección se guarda antes de abrir el diálogo: el teclado encoge la
    // página, el texto se recoloca y la selección de la página se pierde.
    final String seleccion = _seleccion;
    final TextEditingController t = TextEditingController();
    final String? nota = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(tr('Escribir una nota')),
        content: TextField(
          controller: t,
          autofocus: true,
          maxLines: 5,
          minLines: 2,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancelar')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, t.text.trim()),
            child: Text(tr('Guardar')),
          ),
        ],
      ),
    );
    if (nota != null && nota.isNotEmpty) {
      await _anotar('note', nota: nota, seleccion: seleccion);
    }
  }

  Future<void> _abrirMarca(String id) async {
    final Anotacion? a = await (_db.select(
      _db.anotaciones,
    )..where(($AnotacionesTable x) => x.id.equals(id))).getSingleOrNull();
    if (a == null || !mounted) {
      return;
    }
    final String? cita =
        ((jsonDecode(a.locator) as Map<String, dynamic>)['text']
                as Map<String, dynamic>?)?['highlight']
            as String?;
    final bool? quitar = await showModalBottomSheet<bool>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (cita != null)
                Text(
                  '«$cita»',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              if (a.texto != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(a.texto!),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(AppIcons.trash),
                  label: Text(tr('Quitar')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (quitar == true) {
      await _db.darDeBaja(id);
      await _pintarMarcas();
    }
  }

  Future<void> _alternarVoz() async {
    if (_hablando) {
      await _tts.stop();
      setState(() => _hablando = false);
      return;
    }
    String texto = '';
    if (_esTexto) {
      final Object r = await _web!.runJavaScriptReturningResult(
        'nb.textoDesdeAqui()',
      );
      texto = r is String ? r : r.toString();
      if (texto.startsWith('"')) {
        texto = jsonDecode(texto) as String;
      }
    } else if (_locatorActual != null) {
      texto = await Motor.textoDesde(_apertura!.id, _locatorActual!, 4000);
    }
    if (texto.trim().isEmpty) {
      _avisar(tr('No hay texto que leer aquí.'));
      return;
    }
    final String? idioma = _edicion?.idioma;
    if (idioma != null) {
      await _tts.setLanguage(idioma);
    }
    _tts.setCompletionHandler(() {
      if (mounted) {
        setState(() => _hablando = false);
      }
    });
    setState(() => _hablando = true);
    await _tts.speak(texto.length > 3900 ? texto.substring(0, 3900) : texto);
  }

  void _alternarAvance() {
    _avance?.cancel();
    if (_velocidad > 0) {
      setState(() => _velocidad = 0);
      return;
    }
    setState(() => _velocidad = 1);
    final bool paginado = ref.read(ajustesDeLecturaProvider).paginado;
    _avance = Timer.periodic(
      paginado || !_esTexto
          ? const Duration(seconds: 20)
          : const Duration(milliseconds: 50),
      (_) async {
        if (paginado || !_esTexto) {
          await _pasar(1);
          return;
        }
        final Object r = await _web!.runJavaScriptReturningResult(
          'nb.desplazar(2)',
        );
        if (!(r == true || r.toString() == 'true')) {
          await _cambiarCapitulo(1);
        }
      },
    );
  }

  Future<void> _irAlPc() async {
    final Posicion? p = await _db.posicion(_edicion!.id, 'pc');
    if (p == null) {
      _avisar(tr('Este libro no tiene posición en el PC.'));
      return;
    }
    final Map<String, dynamic> l =
        jsonDecode(p.locator) as Map<String, dynamic>;
    if (_esTexto) {
      await _ir(l);
    } else {
      await _irAPagina(await _paginaDe(l) ?? _pagina);
    }
    setState(() => _controles = false);
  }

  void _avisar(String texto) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _indice() async {
    final Apertura? a = _apertura;
    if (a == null) {
      return;
    }
    final EntradaDelIndice? e = await showModalBottomSheet<EntradaDelIndice>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (BuildContext ctx, ScrollController sc) => ListView(
          controller: sc,
          children: <Widget>[
            ListTile(
              title: Text(
                tr('Índice'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            for (final EntradaDelIndice x in a.indice)
              ListTile(
                contentPadding: EdgeInsets.only(
                  left: 16.0 + x.nivel * 16,
                  right: 16,
                ),
                title: Text(x.titulo),
                onTap: () => Navigator.pop(ctx, x),
              ),
          ],
        ),
      ),
    );
    if (e == null) {
      return;
    }
    if (_esTexto) {
      await _ir(e.locator);
    } else {
      await _irAPagina(await _paginaDe(e.locator) ?? _pagina);
    }
    setState(() => _controles = false);
  }

  Future<void> _ajustes() async {
    await mostrarAjustesDeLectura(context);
    await _aplicarEstilo();
    if (_esTexto && _webLista) {
      final double p = _progresoCapitulo;
      await _web!.runJavaScript('nb.situar({progresion: $p});');
    }
  }

  // --- Pintar -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final AjustesDeLectura a = ref.watch(ajustesDeLecturaProvider);
    // La página cambia a la vez que la hoja de ajustes o el tema, no al cerrarla:
    // es la vista previa sobre el propio libro.
    ref.listen<AjustesDeLectura>(
      ajustesDeLecturaProvider,
      (AjustesDeLectura? _, AjustesDeLectura _) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => _aplicarEstilo()),
    );
    ref.listen<String>(
      themeControllerProvider,
      (String? _, String _) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => _aplicarEstilo()),
    );
    final (Color fondo, Color texto) = a.colores(c.bg, c.text);
    if (_fallo != null) {
      return Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_fallo!, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    // El porcentaje es el del texto (el del Locator), el mismo que enseña la
    // biblioteca; el de capítulos solo mientras aún no hay Locator.
    final double? delLocator =
        ((_locatorActual?['locations']
                    as Map<String, dynamic>?)?['totalProgression']
                as num?)
            ?.toDouble();
    final double total = _esTexto
        ? (delLocator ?? _dondeVoy())
        : (_apertura == null || _apertura!.indice.isEmpty
              ? 0
              : _pagina / _apertura!.indice.length);
    return Scaffold(
      backgroundColor: fondo,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: SafeArea(
              child: _apertura == null
                  ? const Center(child: CircularProgressIndicator())
                  : _esTexto
                  // El pie no va en una columna con la vista web: un widget
                  // nativo con composición híbrida dentro de un Column quedaba
                  // tapado en las compilaciones de publicación.
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 26),
                      child: _vistaWeb(),
                    )
                  : _paginaComoImagen(),
            ),
          ),
          if (_apertura != null && _esTexto)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _pie(a, texto)),
            ),
          if (_controles) ..._barras(c, fondo, texto, total),
          if (_seleccion.isNotEmpty) _barraDeSeleccion(c),
        ],
      ),
    );
  }

  /// La vista web con composición híbrida en Android: con la de textura, la
  /// pulsación larga no selecciona texto y no habría forma de anotar.
  Widget _vistaWeb() {
    final Set<Factory<OneSequenceGestureRecognizer>> gestos =
        <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        };
    if (_web!.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        key: ObjectKey(_web),
        params: AndroidWebViewWidgetCreationParams(
          controller: _web!.platform,
          displayWithHybridComposition: true,
          gestureRecognizers: gestos,
        ),
      );
    }
    return WebViewWidget(
      key: ObjectKey(_web),
      controller: _web!,
      gestureRecognizers: gestos,
    );
  }

  Widget _paginaComoImagen() => GestureDetector(
    onTapUp: (TapUpDetails d) {
      final double w = MediaQuery.sizeOf(context).width;
      final double x = d.localPosition.dx;
      if (x < w * 0.25) {
        unawaited(_pasar(-1));
      } else if (x > w * 0.75) {
        unawaited(_pasar(1));
      } else {
        setState(() => _controles = !_controles);
      }
    },
    onHorizontalDragEnd: (DragEndDetails d) {
      final double v = d.primaryVelocity ?? 0;
      if (v.abs() > 200) {
        unawaited(_pasar(v < 0 ? 1 : -1));
      }
    },
    child: InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: _imagen == null
            ? const CircularProgressIndicator()
            : Image.file(File(_imagen!), gaplessPlayback: true),
      ),
    ),
  );

  List<Widget> _barras(NbColors c, Color fondo, Color texto, double total) {
    // Las barras toman los colores de la página, como el marco de un libro:
    // sobre papel crema, una barra gris de la app rompería la lectura.
    final TextStyle estilo = TextStyle(
      fontFamily: NbFonts.ui,
      color: texto,
      fontWeight: FontWeight.w600,
    );
    return <Widget>[
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Material(
          color: fondo,
          elevation: 3,
          shadowColor: Colors.black54,
          child: SafeArea(
            bottom: false,
            child: IconTheme.merge(
              data: IconThemeData(color: texto),
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: tr('Volver'),
                    icon: const Icon(AppIcons.back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      _edicion?.titulo ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: estilo,
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Índice'),
                    icon: const Icon(AppIcons.toc),
                    onPressed: _indice,
                  ),
                  IconButton(
                    tooltip: tr('Poner un marcador'),
                    icon: const Icon(AppIcons.bookmark),
                    onPressed: _marcador,
                  ),
                  if (_esTexto)
                    IconButton(
                      tooltip: tr('Ajustes del libro'),
                      icon: const Icon(AppIcons.typography),
                      onPressed: _ajustes,
                    ),
                  PopupMenuButton<String>(
                    icon: Icon(AppIcons.more, color: texto),
                    onSelected: (String v) async {
                      switch (v) {
                        case 'voz':
                          await _alternarVoz();
                        case 'avance':
                          _alternarAvance();
                        case 'pc':
                          await _irAlPc();
                        case 'seguir-pc':
                          // Pasa el libro al PC en la frase en la que va aquí.
                          final Map<String, dynamic>? l = _locatorActual;
                          if (l != null && context.mounted) {
                            await context.push(
                              '/mando',
                              extra: (_edicion!.id, l),
                            );
                          }
                      }
                    },
                    itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'voz',
                        child: Text(
                          _hablando
                              ? tr('Parar la lectura')
                              : tr('Leer en voz alta'),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'avance',
                        child: Text(
                          _velocidad > 0
                              ? tr('Parar el avance automático')
                              : tr('Avance automático'),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'pc',
                        child: Text(tr('Ir a donde voy en el PC')),
                      ),
                      if (_edicion?.origen == 'pc' &&
                          ref.read(syncProvider).pc != null)
                        PopupMenuItem<String>(
                          value: 'seguir-pc',
                          child: Text(tr('Seguir en el PC')),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Material(
          color: fondo,
          elevation: 3,
          shadowColor: Colors.black54,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 16, 8),
              child: IconTheme.merge(
                data: IconThemeData(color: texto),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: tr('Capítulo anterior'),
                      icon: const Icon(AppIcons.prevChapter),
                      onPressed: () => _esTexto
                          ? _cambiarCapitulo(-1)
                          : _irAPagina(_pagina - 10),
                    ),
                    IconButton(
                      tooltip: tr('Capítulo siguiente'),
                      icon: const Icon(AppIcons.nextChapter),
                      onPressed: () => _esTexto
                          ? _cambiarCapitulo(1)
                          : _irAPagina(_pagina + 10),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: (_arrastre ?? total).clamp(0.0, 1.0),
                        label: _etiquetaDe(_arrastre ?? total),
                        divisions: _esTexto ? null : _totalImagenes(),
                        onChanged: (double v) => setState(() => _arrastre = v),
                        onChangeEnd: (double v) async {
                          setState(() => _arrastre = null);
                          await _saltarA(v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        porcentajeLegible(_arrastre ?? total),
                        textAlign: TextAlign.end,
                        style: estilo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  int? _totalImagenes() {
    final int n = _apertura?.indice.length ?? 0;
    return n > 1 ? n - 1 : null;
  }

  /// Por dónde va la lectura en la escala del texto (la del Locator): es la
  /// pista que desempata una cita que se repite. En escala de capítulos, una
  /// palabra corta del primer capítulo de un libro largo se anclaba en otro.
  double _dondeVoy() {
    if (_inicios.length == _lomo.length && _inicios.isNotEmpty) {
      final double fin = _capitulo + 1 < _inicios.length
          ? _inicios[_capitulo + 1]
          : 1;
      return _inicios[_capitulo] +
          (fin - _inicios[_capitulo]) * _progresoCapitulo;
    }
    return _lomo.isEmpty ? 0 : (_capitulo + _progresoCapitulo) / _lomo.length;
  }

  /// Dónde empieza cada capítulo en la escala del texto, para la barra.
  Future<void> _medirCapitulos(BigInt id, List<String> lomo) async {
    final List<double> inicios = <double>[];
    for (final String href in lomo) {
      try {
        final Map<String, dynamic> l = await Motor.locatorEn(
          id,
          <String, dynamic>{
            'kind': 'fragment',
            'value': <String, dynamic>{'href': href, 'offset': 0},
          },
        );
        inicios.add(
          ((l['locations'] as Map<String, dynamic>?)?['totalProgression']
                      as num?)
                  ?.toDouble() ??
              (inicios.isEmpty ? 0 : inicios.last),
        );
      } on MotorException {
        inicios.add(inicios.isEmpty ? 0 : inicios.last);
      }
    }
    if (mounted) {
      setState(() => _inicios = inicios);
    }
  }

  /// El capítulo en el que cae un punto del texto y cuánto se ha avanzado en
  /// él. Sin medidas todavía, los capítulos cuentan por igual.
  (int, double) _capituloDe(double v) {
    if (_inicios.length != _lomo.length || _inicios.isEmpty) {
      final double x = (v * _lomo.length).clamp(0, _lomo.length - 0.0001);
      return (x.floor(), x - x.floor());
    }
    int i = 0;
    while (i + 1 < _inicios.length && _inicios[i + 1] <= v) {
      i++;
    }
    final double fin = i + 1 < _inicios.length ? _inicios[i + 1] : 1;
    final double largo = fin - _inicios[i];
    return (i, largo <= 0 ? 0 : ((v - _inicios[i]) / largo).clamp(0.0, 1.0));
  }

  /// Lo que se ve al arrastrar la barra: el capítulo al que se llegaría.
  String _etiquetaDe(double v) {
    if (!_esTexto || _lomo.isEmpty) {
      return '${(v * 100).round()} %';
    }
    return _titulos[_lomo[_capituloDe(v).$1]] ?? '${(v * 100).round()} %';
  }

  /// Salta a un punto del libro: el capítulo que le toca y, dentro, la parte
  /// proporcional.
  Future<void> _saltarA(double v) async {
    if (!_esTexto) {
      final int n = _apertura?.indice.length ?? 0;
      if (n > 0) {
        await _irAPagina((v * (n - 1)).round());
      }
      return;
    }
    if (_lomo.isEmpty) {
      return;
    }
    final (int i, double dentro) = _capituloDe(v);
    await _pintarCapitulo(i, <String, dynamic>{'progresion': dentro});
  }

  /// El pie mientras se lee: dónde se está, sin tapar el texto.
  Widget _pie(AjustesDeLectura a, Color texto) {
    final String titulo = _lomo.isEmpty ? '' : _titulos[_lomo[_capitulo]] ?? '';
    final String donde = a.paginado && _paginasCap > 1
        ? tr('{p} de {n}', <String, Object?>{
            'p': _paginaCap + 1,
            'n': _paginasCap,
          })
        : '${(_progresoCapitulo * 100).round()} %';
    final TextStyle s = TextStyle(
      fontFamily: NbFonts.ui,
      fontSize: 11.5,
      color: texto.withValues(alpha: 0.5),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return SizedBox(
      height: 26,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: a.margen),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                titulo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: s,
              ),
            ),
            const SizedBox(width: 12),
            Text(donde, style: s),
          ],
        ),
      ),
    );
  }

  Widget _barraDeSeleccion(NbColors c) => Positioned(
    left: 12,
    right: 12,
    bottom: 24,
    child: SafeArea(
      child: Material(
        color: c.bg3,
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              _accion(AppIcons.note, tr('Nota'), _escribirNota),
              _accion(
                AppIcons.highlight,
                tr('Resaltar'),
                () => _anotar('highlight'),
              ),
              _accion(
                AppIcons.underline,
                tr('Subrayar'),
                () => _anotar('underline'),
              ),
              _accion(AppIcons.copy, tr('Copiar'), () async {
                await Clipboard.setData(ClipboardData(text: _seleccion));
                _avisar(tr('Copiado.'));
              }),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _accion(IconData icono, String texto, VoidCallback f) => TextButton(
    onPressed: f,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icono, size: 22),
        const SizedBox(height: 2),
        Text(texto, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
}

/// El mensaje de un fallo del motor, en el idioma de la app.
String mensajeDelMotor(String codigo) => switch (codigo) {
  'FILE_NOT_FOUND' => tr('No se encuentra el archivo del libro.'),
  'FORMAT_UNSUPPORTED' => tr('Este formato no se puede abrir.'),
  'DOCUMENT_CORRUPTED' => tr('El archivo está dañado.'),
  'COMPONENT_UNAVAILABLE' => tr('Falta el motor para este formato.'),
  _ => tr('No se pudo abrir el libro.'),
};
