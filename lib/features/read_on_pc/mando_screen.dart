import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/i18n/i18n.dart';
import '../../core/network/salidas.dart';
import '../../core/security/secure_store.dart';
import '../../data/db/database.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/portada.dart';
import '../../shared/widgets/sub_header.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/providers.dart';
import '../../core/motor/motor.dart';
import '../library/application/biblioteca.dart';
import '../offline/descargas.dart';
import '../sync/application/sync_controller.dart';

/// Leer en el PC: el teléfono maneja el lector de NB Books como un mando. Las
/// órdenes van en un solo sentido; el PC solo contesta dónde está (ADR-010).
class MandoScreen extends ConsumerStatefulWidget {
  const MandoScreen({super.key, this.abrir, this.en});

  /// Una edición que abrir en el PC al conectar.
  final String? abrir;

  /// Dónde abrirla: el Locator en el que va el teléfono, para seguir en el PC
  /// en la misma frase.
  final Map<String, dynamic>? en;

  @override
  ConsumerState<MandoScreen> createState() => _MandoScreenState();
}

class _MandoScreenState extends ConsumerState<MandoScreen> {
  WebSocketChannel? _canal;
  StreamSubscription<dynamic>? _sub;
  Map<String, dynamic> _estado = const <String, dynamic>{};

  /// Hasta el primer estado no se sabe si el PC tiene un libro abierto: decir
  /// que no lo tiene y corregirse al momento confunde.
  bool _conEstado = false;
  bool _conectado = false;
  String? _fallo;
  double _velocidad = 0;

  /// El Locator que falta mandar cuando el PC haya abierto el libro.
  Map<String, dynamic>? _situarAlAbrir;
  double _acumulado = 0;
  Timer? _envio;

  /// Las teclas de volumen pasan página mientras esta pantalla está abierta.
  static const MethodChannel _teclas = MethodChannel('com.nbbooks/teclas');

  @override
  void initState() {
    super.initState();
    unawaited(_conectar());
    if (defaultTargetPlatform == TargetPlatform.android) {
      _teclas.setMethodCallHandler((MethodCall c) async {
        if (c.method == 'volumen') {
          _comando(
            (c.arguments as int) > 0 ? 'pagina-siguiente' : 'pagina-anterior',
          );
        }
      });
      unawaited(_teclas.invokeMethod<void>('capturarVolumen', true));
    }
  }

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_teclas.invokeMethod<void>('capturarVolumen', false));
      _teclas.setMethodCallHandler(null);
    }
    _envio?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_canal?.sink.close());
    super.dispose();
  }

  Future<void> _conectar() async {
    if (ref.read(syncProvider).pc == null) {
      setState(() => _fallo = tr('Empareja el teléfono con el PC primero.'));
      return;
    }
    // Comprobado antes de abrir el canal: el PC pudo cambiar de puerto.
    final PairedPc? pc = await ref.read(syncProvider.notifier).pcAlcanzable();
    if (!mounted) {
      return;
    }
    if (pc == null || pc.fingerprint == null) {
      setState(
        () => _fallo = tr(
          'No se encuentra el PC. Comprueba que NB Books está abierto, con los teléfonos permitidos, y en la misma red.',
        ),
      );
      return;
    }
    try {
      final WebSocketChannel c = conectarControl(
        Uri.parse('${pc.wsBaseUrl}/api/v1/control'),
        fingerprint: pc.fingerprint!,
        token: pc.deviceToken,
      );
      await c.ready;
      _canal = c;
      _sub = c.stream.listen(
        (dynamic m) {
          final Map<String, dynamic> d =
              jsonDecode(m as String) as Map<String, dynamic>;
          if (d['tipo'] == 'estado' && d['estado'] is Map<String, dynamic>) {
            final Map<String, dynamic> e = d['estado'] as Map<String, dynamic>;
            setState(() {
              _estado = e;
              _conEstado = true;
            });
            // El libro ya está abierto en el PC: ahora sí, a la frase.
            final Map<String, dynamic>? en = _situarAlAbrir;
            if (en != null && e['edicion'] == widget.abrir) {
              _situarAlAbrir = null;
              _ordenar(<String, dynamic>{'tipo': 'irAlLocator', 'locator': en});
            }
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _conectado = false;
              _fallo = tr('El PC cortó la conexión.');
            });
          }
        },
        onError: (Object _) {},
      );
      setState(() {
        _conectado = true;
        _fallo = null;
      });
      if (widget.abrir != null) {
        _situarAlAbrir = widget.en;
        _ordenar(<String, dynamic>{'tipo': 'abrir', 'edicion': widget.abrir});
      }
    } catch (_) {
      setState(() => _fallo = tr('No se pudo conectar con el lector del PC.'));
    }
  }

  void _ordenar(Map<String, dynamic> orden) {
    if (!_conectado) {
      return;
    }
    HapticFeedback.selectionClick();
    _canal?.sink.add(jsonEncode(orden));
  }

  void _comando(String id) =>
      _ordenar(<String, dynamic>{'tipo': 'comando', 'id': id});

  /// Desplazar con el dedo: se agrupan los movimientos para no mandar una orden
  /// por fotograma.
  void _arrastre(double dy) {
    _acumulado += dy;
    _envio ??= Timer(const Duration(milliseconds: 60), () {
      _envio = null;
      final double px = (_acumulado * 2.5).clamp(-4000, 4000);
      _acumulado = 0;
      if (px.abs() >= 1) {
        _ordenar(<String, dynamic>{'tipo': 'desplazar', 'dy': -px});
      }
    });
  }

  Future<void> _elegirLibro() async {
    final List<Edicion> libros =
        (ref.read(edicionesProvider).value ?? const <Edicion>[])
            .where((Edicion e) => e.origen == 'pc')
            .toList();
    final Edicion? e = await showModalBottomSheet<Edicion>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (BuildContext ctx, ScrollController sc) => ListView.builder(
          controller: sc,
          itemCount: libros.length + 1,
          itemBuilder: (BuildContext ctx, int i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  tr('Abrir en el PC'),
                  style: const TextStyle(
                    fontFamily: NbFonts.display,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }
            final Edicion l = libros[i - 1];
            return ListTile(
              leading: SizedBox(
                width: 36,
                height: 54,
                child: Portada(
                  titulo: l.titulo,
                  autor: autoresDe(l),
                  ruta: l.rutaPortada,
                  radio: 4,
                ),
              ),
              title: Text(
                l.titulo,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(autoresDe(l), maxLines: 1),
              onTap: () => Navigator.pop(ctx, l),
            );
          },
        ),
      ),
    );
    if (e != null) {
      _ordenar(<String, dynamic>{'tipo': 'abrir', 'edicion': e.id});
    }
  }

  String? get _edicion => _estado['edicion'] as String?;

  Edicion? _local() {
    final String? id = _edicion;
    if (id == null) {
      return null;
    }
    return (ref.read(edicionesProvider).value ?? const <Edicion>[])
        .where((Edicion e) => e.id == id)
        .firstOrNull;
  }

  /// El índice del libro que tiene abierto el PC. Si el libro está en el
  /// teléfono, el índice es el suyo, con cada entrada en su Locator exacto; si
  /// no, los capítulos por su número.
  Future<void> _indice() async {
    final Edicion? e = _local();
    final List<(String, Map<String, dynamic>)> entradas =
        <(String, Map<String, dynamic>)>[];
    final String? ruta =
        e?.ruta ??
        (e == null
            ? null
            : ref.read(syncRepositoryProvider).temporalDe(e)?.path);
    if (e != null && ruta != null) {
      try {
        final Apertura a = await Motor.abrir(ruta, e.tipo);
        for (final EntradaDelIndice x in a.indice) {
          entradas.add((
            ('  ' * x.nivel) + x.titulo,
            <String, dynamic>{'tipo': 'irAlLocator', 'locator': x.locator},
          ));
        }
        Motor.cerrar(a.id);
      } on MotorException {
        // Sin índice propio, se ofrecen los capítulos del PC.
      }
    }
    if (entradas.isEmpty) {
      final int n = (_estado['capitulosTotales'] as num?)?.toInt() ?? 0;
      for (int k = 0; k < n; k++) {
        entradas.add((
          tr('Capítulo {n}', <String, Object?>{'n': k + 1}),
          <String, dynamic>{'tipo': 'irA', 'progresion': (k + 0.01) / n},
        ));
      }
    }
    if (!mounted || entradas.isEmpty) {
      return;
    }
    final Map<String, dynamic>? orden = await _hoja(
      tr('Índice'),
      <(String, String?, Map<String, dynamic>)>[
        for (final (String t, Map<String, dynamic> o) in entradas) (t, null, o),
      ],
    );
    if (orden != null) {
      _ordenar(orden);
    }
  }

  /// Las anotaciones del libro abierto en el PC, para ir a una.
  Future<void> _anotaciones() async {
    final String? id = _edicion;
    if (id == null) {
      return;
    }
    final List<Anotacion> lista = await ref
        .read(databaseProvider)
        .vigilarAnotaciones(id)
        .first;
    if (!mounted) {
      return;
    }
    if (lista.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Este libro no tiene anotaciones todavía.'))),
      );
      return;
    }
    final Map<String, dynamic>? orden = await _hoja(
      tr('Anotaciones'),
      <(String, String?, Map<String, dynamic>)>[
        for (final Anotacion a in lista)
          if (a.tipo != 'ink')
            () {
              final Map<String, dynamic> l =
                  jsonDecode(a.locator) as Map<String, dynamic>;
              final String cita =
                  (l['text'] as Map<String, dynamic>?)?['highlight']
                      as String? ??
                  tr('Marcador');
              return (
                a.tipo == 'bookmark' ? tr('Marcador') : cita,
                a.tipo == 'note' ? a.texto : null,
                <String, dynamic>{'tipo': 'irAlLocator', 'locator': l},
              );
            }(),
      ],
    );
    if (orden != null) {
      _ordenar(orden);
    }
  }

  Future<Map<String, dynamic>?> _hoja(
    String titulo,
    List<(String, String?, Map<String, dynamic>)> filas,
  ) => showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (BuildContext ctx, ScrollController sc) => ListView(
        controller: sc,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              titulo,
              style: const TextStyle(
                fontFamily: NbFonts.display,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          for (final (String t, String? sub, Map<String, dynamic> o) in filas)
            ListTile(
              title: Text(t, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: sub == null ? null : Text(sub, maxLines: 2),
              onTap: () => Navigator.pop(ctx, o),
            ),
        ],
      ),
    ),
  );

  /// Sigue en el teléfono en la frase en la que va el PC.
  Future<void> _seguirAqui() async {
    final Edicion? e = _local();
    final Map<String, dynamic>? l = _estado['locator'] as Map<String, dynamic>?;
    if (e == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Ese libro no está elegido para el teléfono.')),
        ),
      );
      return;
    }
    final bool aqui =
        e.ruta != null ||
        ref.read(syncRepositoryProvider).temporalDe(e) != null;
    if (!aqui) {
      final String? fallo = await ref
          .read(descargasProvider.notifier)
          .descargar(e, temporal: true);
      if (fallo != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr('No se pudo abrir. Comprueba la conexión con el PC.'),
              ),
            ),
          );
        }
        return;
      }
    }
    if (mounted) {
      unawaited(context.push('/leer/${e.id}', extra: l));
    }
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final String titulo = _estado['titulo'] as String? ?? '';
    final String? capitulo = _estado['capitulo'] as String?;
    final double progreso = (_estado['progresion'] as num?)?.toDouble() ?? 0;
    final Map<String, dynamic>? locator =
        _estado['locator'] as Map<String, dynamic>?;
    final Map<String, dynamic>? texto =
        locator?['text'] as Map<String, dynamic>?;
    final String? frase = texto?['highlight'] is String
        ? fraseLegible(
            texto!['highlight'] as String,
            despues: texto['after'] as String?,
            alEmpezar: texto['before'] == null,
          )
        : null;
    final String voz = _estado['voz'] as String? ?? 'parada';
    final bool fondo = _estado['fondoSonoro'] == true;
    final bool inmersivo = _estado['inmersivo'] == true;
    final bool hayLibro = titulo.isNotEmpty;
    if (_estado['avance'] is num && _envio == null) {
      _velocidad = (_estado['avance'] as num).toDouble();
    }

    final List<_Accion> acciones = <_Accion>[
      _Accion(AppIcons.toc, tr('Índice'), _indice),
      _Accion(AppIcons.annotations, tr('Anotaciones'), _anotaciones),
      _Accion(AppIcons.bookmark, tr('Marcador'), () => _comando('marcador')),
      _Accion(
        voz == 'hablando' ? AppIcons.pause : AppIcons.voice,
        voz == 'hablando'
            ? tr('Pausar la voz')
            : voz == 'pausada'
            ? tr('Seguir la voz')
            : tr('Leer en voz alta'),
        () => _comando('voz'),
        activo: voz != 'parada',
      ),
      _Accion(
        AppIcons.sound,
        tr('Fondo sonoro'),
        () => _comando('fondo-sonoro'),
        activo: fondo,
      ),
      _Accion(
        AppIcons.palette,
        _nombreDelModo(_estado['modo'] as String?),
        () => _comando('modo-de-lectura'),
      ),
      _Accion(
        AppIcons.textSmaller,
        tr('Letra menor'),
        () => _comando('letra-menor'),
      ),
      _Accion(
        AppIcons.textBigger,
        tr('Letra mayor'),
        () => _comando('letra-mayor'),
      ),
      _Accion(
        AppIcons.immersion,
        tr('Inmersión'),
        () => _comando('inmersion'),
        activo: inmersivo,
      ),
      _Accion(
        AppIcons.fullscreen,
        tr('Pantalla completa'),
        () => _comando('pantalla-completa'),
      ),
      _Accion(AppIcons.autoAdvance, tr('Avance'), () {
        setState(() => _velocidad = _velocidad > 0 ? 0 : 2);
        _ordenar(<String, dynamic>{'tipo': 'avance', 'velocidad': _velocidad});
      }, activo: _velocidad > 0),
      _Accion(AppIcons.phone, tr('Seguir aquí'), _seguirAqui),
    ];

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SubHeader(
              title: tr('Leer en el PC'),
              trailing: IconButton(
                tooltip: tr('Abrir un libro en el PC'),
                icon: const Icon(AppIcons.library),
                onPressed: _conectado ? _elegirLibro : null,
              ),
            ),
            if (_fallo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Column(
                  children: <Widget>[
                    Text(
                      _fallo!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.text2),
                    ),
                    TextButton(
                      onPressed: _conectar,
                      child: Text(tr('Reintentar')),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: <Widget>[
                  Text(
                    hayLibro
                        ? titulo
                        : _conEstado
                        ? tr('El lector del PC no tiene ningún libro abierto.')
                        : tr('Conectando con el PC…'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NbFonts.display,
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                      color: c.text,
                    ),
                  ),
                  if (capitulo != null)
                    Text(
                      capitulo,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.text2),
                    ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          value: progreso.clamp(0.0, 1.0),
                          onChanged: !hayLibro
                              ? null
                              : (double v) => setState(
                                  () => _estado = <String, dynamic>{
                                    ..._estado,
                                    'progresion': v,
                                  },
                                ),
                          onChangeEnd: (double v) => _ordenar(<String, dynamic>{
                            'tipo': 'irA',
                            'progresion': v,
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${(progreso * 100).round()} %',
                          textAlign: TextAlign.end,
                          style: TextStyle(color: c.text2),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                onVerticalDragUpdate: (DragUpdateDetails d) =>
                    _arrastre(d.delta.dy),
                onHorizontalDragEnd: (DragEndDetails d) {
                  final double v = d.primaryVelocity ?? 0;
                  if (v.abs() > 250) {
                    _comando(v < 0 ? 'pagina-siguiente' : 'pagina-anterior');
                  }
                },
                onTapUp: (TapUpDetails d) {
                  final double w = MediaQuery.sizeOf(context).width;
                  _comando(
                    d.localPosition.dx < w / 2
                        ? 'pagina-anterior'
                        : 'pagina-siguiente',
                  );
                },
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: c.bg2,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: c.line),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (frase != null && frase.trim().isNotEmpty) ...<Widget>[
                        Text(
                          tr('VA POR AQUÍ'),
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w800,
                            color: c.accent,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '«$frase»',
                          textAlign: TextAlign.center,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 16,
                            height: 1.45,
                            color: c.text,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        defaultTargetPlatform == TargetPlatform.android
                            ? tr(
                                'Toca a los lados para pasar página. Desliza hacia arriba o abajo para desplazarte. Las teclas de volumen también pasan página.',
                              )
                            : tr(
                                'Toca a los lados para pasar página. Desliza hacia arriba o abajo para desplazarte.',
                              ),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.text3, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_velocidad > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: <Widget>[
                    Icon(AppIcons.autoAdvance, size: 18, color: c.text2),
                    Expanded(
                      child: Slider(
                        value: _velocidad.clamp(0.5, 10),
                        min: 0.5,
                        max: 10,
                        label: tr('Velocidad'),
                        onChanged: (double v) => setState(() => _velocidad = v),
                        onChangeEnd: (double v) => _ordenar(<String, dynamic>{
                          'tipo': 'avance',
                          'velocidad': v,
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  _Boton(
                    AppIcons.prevChapter,
                    tr('Capítulo anterior'),
                    () => _comando('capitulo-anterior'),
                  ),
                  _Boton(
                    AppIcons.prevPage,
                    tr('Página anterior'),
                    () => _comando('pagina-anterior'),
                  ),
                  _Boton(
                    AppIcons.nextPage,
                    tr('Página siguiente'),
                    () => _comando('pagina-siguiente'),
                  ),
                  _Boton(
                    AppIcons.nextChapter,
                    tr('Capítulo siguiente'),
                    () => _comando('capitulo-siguiente'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.25,
                children: <Widget>[
                  for (final _Accion a in acciones)
                    _Pequeno(
                      a,
                      habilitado:
                          _conectado &&
                          (hayLibro || a.icono == AppIcons.library),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Accion {
  const _Accion(this.icono, this.texto, this.alPulsar, {this.activo = false});
  final IconData icono;
  final String texto;
  final VoidCallback alPulsar;
  final bool activo;
}

/// Una acción del mando con su nombre debajo: se ve qué hace sin adivinarlo.
class _Pequeno extends StatelessWidget {
  const _Pequeno(this.a, {required this.habilitado});
  final _Accion a;
  final bool habilitado;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final Color color = !habilitado
        ? c.text3
        : a.activo
        ? c.accent
        : c.text;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: habilitado ? a.alPulsar : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: a.activo ? c.soft : c.bg2,
              shape: BoxShape.circle,
              border: Border.all(color: a.activo ? c.accent : c.line),
            ),
            child: Icon(a.icono, size: 21, color: color),
          ),
          const SizedBox(height: 4),
          // Encoge un poco el nombre largo ("Pantalla completa") en lugar de
          // cortarlo: un botón tiene que decir entero lo que hace.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              a.texto,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Boton extends StatelessWidget {
  const _Boton(this.icono, this.texto, this.alPulsar);
  final IconData icono;
  final String texto;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return IconButton.filledTonal(
      tooltip: texto,
      iconSize: 28,
      style: IconButton.styleFrom(
        backgroundColor: c.bg3,
        foregroundColor: c.text,
        minimumSize: const Size(60, 60),
      ),
      onPressed: alPulsar,
      icon: Icon(icono),
    );
  }
}

/// El modo de lectura del PC con su nombre, para que el botón diga en cuál está
/// y no solo que cambia de modo.
String _nombreDelModo(String? m) => switch (m) {
  'dia' => tr('Día'),
  'sepia' => tr('Sepia'),
  'nocturno' => tr('Noche'),
  'altoContraste' => tr('Alto contraste'),
  'papelMonocromo' => tr('Papel monocromo'),
  'papelAtenuado' => tr('Papel atenuado'),
  _ => tr('Modo'),
};

/// La cita de un Locator lista para leerla en el mando.
///
/// La cita es un trozo de longitud fija del texto del capítulo, el mismo que
/// sirve para anclar, y no se toca: solo se arregla al enseñarla. Si corta una
/// palabra, se quita el trozo y se ponen puntos suspensivos. Al principio de un
/// documento ([alEmpezar], sin texto antes), el texto empieza por el título del
/// documento y después por el encabezado, que suelen ser el mismo ("IV IV …"):
/// se deja uno.
String fraseLegible(String cita, {String? despues, bool alEmpezar = false}) {
  String f = cita.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (alEmpezar) {
    final RegExpMatch? m = RegExp(r'^(.{1,40}?) \1(?=\s|$)').firstMatch(f);
    if (m != null) {
      f = f.substring(m.group(1)!.length + 1);
    }
  }
  final bool cortada =
      despues != null &&
      RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(despues) &&
      RegExp(r'[\p{L}\p{N}]$', unicode: true).hasMatch(f);
  if (cortada) {
    final int corte = f.lastIndexOf(' ');
    if (corte > 0) {
      f = '${f.substring(0, corte)}…';
    }
  }
  return f;
}
