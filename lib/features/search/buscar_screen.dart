import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/barra_raiz.dart';
import '../../core/di/providers.dart';
import '../../core/i18n/i18n.dart';
import '../../core/security/secure_store.dart';
import '../../data/db/database.dart';
import '../../shared/theme/nb_colors.dart';
import '../../shared/theme/nb_theme.dart';
import '../../shared/widgets/app_icons.dart';
import '../../shared/widgets/chip_pill.dart';
import '../../shared/widgets/section_head.dart';
import '../library/application/biblioteca.dart';
import '../library/application/estantes.dart';
import '../library/application/fotos_de_autores.dart';
import '../library/presentation/libro_widgets.dart';
import '../sync/application/sync_controller.dart';
import '../sync/data/sync_repository.dart';

const String kRecientes = 'busquedas_recientes';

final StreamProvider<List<String>> _recientes = StreamProvider<List<String>>(
  (Ref ref) => ref
      .watch(databaseProvider)
      .vigilarAjuste(kRecientes)
      .map((String? v) => listaJson(v).whereType<String>().toList()),
);

/// Qué tipo de resultado se ve.
enum _Tipo { todo, libros, estanterias, texto }

/// Buscar: título, autoría, series, colecciones y materias en lo que hay en el
/// teléfono, sin tildes ni mayúsculas; y dentro del texto de toda la
/// biblioteca con el índice del PC, que solo funciona conectado (el teléfono no
/// copia el índice). Sin nada escrito: las búsquedas recientes y la biblioteca
/// para explorar.
class BuscarScreen extends ConsumerStatefulWidget {
  const BuscarScreen({super.key});

  @override
  ConsumerState<BuscarScreen> createState() => _BuscarScreenState();
}

class _BuscarScreenState extends ConsumerState<BuscarScreen> {
  final TextEditingController _q = TextEditingController();
  final FocusNode _foco = FocusNode();
  Timer? _espera;
  List<ResultadoDeBusqueda> _texto = const <ResultadoDeBusqueda>[];
  bool _buscando = false;
  String? _aviso;
  _Tipo _tipo = _Tipo.todo;

  @override
  void dispose() {
    _q.dispose();
    _foco.dispose();
    _espera?.cancel();
    super.dispose();
  }

  void _cambio(String v) {
    setState(() {});
    _espera?.cancel();
    _espera = Timer(
      const Duration(milliseconds: 450),
      () => _enElTexto(v.trim()),
    );
  }

  void _poner(String v) {
    _q.text = v;
    _q.selection = TextSelection.collapsed(offset: v.length);
    _cambio(v);
    _recordar(v);
  }

  Future<void> _recordar(String q) async {
    q = q.trim();
    if (q.length < 2) {
      return;
    }
    final List<String> l = <String>[
      q,
      ...(ref.read(_recientes).value ?? const <String>[]).where(
        (String x) => normalizar(x) != normalizar(q),
      ),
    ].take(8).toList();
    await ref.read(databaseProvider).fijarAjuste(kRecientes, jsonEncode(l));
  }

  Future<void> _enElTexto(String q) async {
    final PairedPc? pc = ref.read(syncProvider).pc;
    if (q.length < 3) {
      setState(() {
        _texto = const <ResultadoDeBusqueda>[];
        _aviso = null;
      });
      return;
    }
    if (pc == null) {
      setState(() {
        _texto = const <ResultadoDeBusqueda>[];
        _aviso = tr('Buscar dentro de los libros necesita el PC.');
      });
      return;
    }
    setState(() => _buscando = true);
    try {
      final List<ResultadoDeBusqueda> r = await ref
          .read(syncProvider.notifier)
          .conPc(
            (PairedPc pc) => ref.read(syncRepositoryProvider).buscar(pc, q),
          );
      if (mounted && _q.text.trim() == q) {
        setState(() {
          _texto = r;
          _aviso = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _texto = const <ResultadoDeBusqueda>[];
          _aviso = tr('El PC no responde: solo se busca en el teléfono.');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _buscando = false);
      }
    }
  }

  Future<void> _abrirResultado(ResultadoDeBusqueda r) async {
    await _recordar(_q.text);
    final Edicion? e = (ref.read(edicionesProvider).value ?? const <Edicion>[])
        .where((Edicion x) => x.id == r.edicion)
        .firstOrNull;
    if (!mounted) {
      return;
    }
    if (e?.ruta != null) {
      await context.push('/leer/${r.edicion}', extra: r.locator);
    } else if (e != null) {
      await context.push('/libro/${r.edicion}');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Ese libro no está elegido para el teléfono.')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final String q = normalizar(_q.text.trim());
    final List<Edicion> libros = ref.watch(librosVisiblesProvider);
    final List<Coleccion> colecciones =
        ref.watch(coleccionesProvider).value ?? const <Coleccion>[];

    final List<Widget> cuerpo = <Widget>[];
    if (q.isEmpty) {
      cuerpo.addAll(_explorar(c, libros, colecciones));
    } else {
      bool coincide(String s) => normalizar(s).contains(q);
      final List<Edicion> enLibros =
          libros
              .where(
                (Edicion e) =>
                    coincide(e.titulo) ||
                    coincide(e.subtitulo ?? '') ||
                    coincide(autoresDe(e)),
              )
              .toList()
            // Primero lo que empieza por lo escrito.
            ..sort(
              (Edicion a, Edicion b) =>
                  (normalizar(a.titulo).startsWith(q) ? 0 : 1).compareTo(
                    normalizar(b.titulo).startsWith(q) ? 0 : 1,
                  ),
            );
      final List<(Estante, Grupo)> estantes = <(Estante, Grupo)>[
        for (final Estante e in Estante.values)
          for (final Grupo g in agrupar(libros, e, colecciones: colecciones))
            if (coincide(g.nombre)) (e, g),
      ];
      bool ver(_Tipo t) => _tipo == _Tipo.todo || _tipo == t;

      cuerpo.add(
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
            children: <Widget>[
              for (final (_Tipo t, String n) in <(_Tipo, String)>[
                (_Tipo.todo, tr('Todo')),
                (_Tipo.libros, tr('Libros')),
                (_Tipo.estanterias, tr('Estanterías')),
                (_Tipo.texto, tr('Dentro de los libros')),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChipPill(
                    label: n,
                    active: t == _tipo,
                    onTap: () => setState(() => _tipo = t),
                  ),
                ),
            ],
          ),
        ),
      );
      if (ver(_Tipo.libros) && enLibros.isNotEmpty) {
        cuerpo.add(_Titulo(tr('Libros')));
        cuerpo.addAll(
          enLibros
              .take(_tipo == _Tipo.todo ? 6 : 200)
              .map((Edicion e) => FilaDeLibro(edicion: e)),
        );
      }
      if (ver(_Tipo.estanterias) && estantes.isNotEmpty) {
        cuerpo.add(_Titulo(tr('Estanterías')));
        for (final (Estante e, Grupo g) in estantes.take(
          _tipo == _Tipo.todo ? 6 : 200,
        )) {
          cuerpo.add(FilaDeGrupo(grupo: g, estante: e));
        }
      }
      if (ver(_Tipo.texto)) {
        if (_aviso != null) {
          cuerpo.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Row(
                children: <Widget>[
                  Icon(AppIcons.laptop, size: 18, color: c.text3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_aviso!, style: TextStyle(color: c.text2)),
                  ),
                ],
              ),
            ),
          );
        }
        if (_texto.isNotEmpty) {
          cuerpo.add(_Titulo(tr('Dentro de los libros')));
          for (final ResultadoDeBusqueda r in _texto) {
            cuerpo.add(
              _Pasaje(
                r: r,
                q: _q.text.trim(),
                alPulsar: () => _abrirResultado(r),
              ),
            );
          }
        }
      }
      if (enLibros.isEmpty &&
          estantes.isEmpty &&
          _texto.isEmpty &&
          !_buscando &&
          _aviso == null) {
        cuerpo.add(
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              children: <Widget>[
                Icon(AppIcons.search, size: 40, color: c.text3),
                const SizedBox(height: 12),
                Text(
                  tr('Sin resultados'),
                  style: TextStyle(
                    fontFamily: NbFonts.display,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('Prueba con otras palabras.'),
                  style: TextStyle(color: c.text2),
                ),
              ],
            ),
          ),
        );
      }
    }

    return Column(
      children: <Widget>[
        BarraRaiz(titulo: tr('Buscar')),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: TextField(
            controller: _q,
            focusNode: _foco,
            onChanged: _cambio,
            onSubmitted: _recordar,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(AppIcons.search),
              hintText: tr('Título, autor, serie o una frase'),
              filled: true,
              fillColor: c.bg2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.line),
              ),
              suffixIcon: _buscando
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _q.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: tr('Borrar'),
                      icon: const Icon(AppIcons.close),
                      onPressed: () {
                        _q.clear();
                        _cambio('');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            primary: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: 24),
            children: cuerpo,
          ),
        ),
      ],
    );
  }

  List<Widget> _explorar(
    NbColors c,
    List<Edicion> libros,
    List<Coleccion> colecciones,
  ) {
    final List<String> recientes =
        ref.watch(_recientes).value ?? const <String>[];
    final List<Grupo> autores = agrupar(libros, Estante.autor)
      ..sort((Grupo a, Grupo b) => b.libros.length.compareTo(a.libros.length));
    final List<Grupo> materias = agrupar(libros, Estante.materia)
      ..sort((Grupo a, Grupo b) => b.libros.length.compareTo(a.libros.length));
    final List<Grupo> series = agrupar(libros, Estante.serie);
    return <Widget>[
      if (recientes.isNotEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
          child: Row(
            children: <Widget>[
              Expanded(child: SectionHead(title: tr('Recientes'))),
              TextButton(
                onPressed: () =>
                    ref.read(databaseProvider).borrarAjuste(kRecientes),
                child: Text(tr('Borrar')),
              ),
            ],
          ),
        ),
        for (final String r in recientes)
          ListTile(
            dense: true,
            leading: Icon(AppIcons.history, color: c.text3),
            title: Text(r),
            onTap: () => _poner(r),
          ),
      ],
      if (autores.isNotEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: SectionHead(title: tr('Autores de tu biblioteca')),
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: autores.length.clamp(0, 20),
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (BuildContext ctx, int i) => _Autor(grupo: autores[i]),
          ),
        ),
      ],
      if (materias.isNotEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: SectionHead(title: tr('Materias')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final Grupo g in materias.take(16))
                ChipPill(
                  label: g.nombre,
                  icon: AppIcons.subject,
                  onTap: () => context.push(
                    '/estante/${Estante.materia.name}/${Uri.encodeComponent(g.clave)}',
                  ),
                ),
            ],
          ),
        ),
      ],
      if (series.isNotEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: SectionHead(title: tr('Series')),
        ),
        for (final Grupo g in series.take(6))
          FilaDeGrupo(grupo: g, estante: Estante.serie),
      ],
      if (libros.isEmpty)
        Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            tr(
              'Busca en tus libros y, con el PC conectado, dentro de todos ellos.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.text2, height: 1.4),
          ),
        ),
    ];
  }
}

class _Autor extends ConsumerWidget {
  const _Autor({required this.grupo});
  final Grupo grupo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final FotoDeAutor? foto = ref.watch(fotoDeAutorProvider(grupo.nombre));
    final String inicial = grupo.nombre.characters.first.toUpperCase();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push(
        '/estante/${Estante.autor.name}/${Uri.encodeComponent(grupo.clave)}',
      ),
      child: SizedBox(
        width: 84,
        child: Column(
          children: <Widget>[
            if (foto != null)
              RetratoDeAutor(foto: foto, lado: 72)
            else
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.soft,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.line2),
                ),
                child: Text(
                  inicial,
                  style: TextStyle(
                    fontFamily: NbFonts.display,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: c.accent,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              grupo.nombre,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.text,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un pasaje encontrado en el PC, con lo buscado en negrita.
class _Pasaje extends StatelessWidget {
  const _Pasaje({required this.r, required this.q, required this.alPulsar});
  final ResultadoDeBusqueda r;
  final String q;
  final VoidCallback alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final String p = r.pasaje.isEmpty ? tr('(pasaje no disponible)') : r.pasaje;
    final TextStyle base = TextStyle(
      fontFamily: 'serif',
      fontSize: 14.5,
      height: 1.45,
      color: c.text2,
    );
    return InkWell(
      onTap: alPulsar,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    r.titulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NbFonts.ui,
                      fontWeight: FontWeight.w800,
                      color: c.text,
                    ),
                  ),
                ),
                if (!r.seleccionada)
                  Tooltip(
                    message: tr('Solo en el PC'),
                    child: Icon(AppIcons.laptop, color: c.text3, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(children: _tramos(p, q, c)),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: base,
            ),
          ],
        ),
      ),
    );
  }
}

/// El pasaje en tramos, con lo encontrado resaltado. El PC lo marca entre
/// `‹` y `›`; si no viene marcado, se busca aquí lo escrito.
List<InlineSpan> _tramos(String p, String q, NbColors c) {
  final TextStyle fuerte = TextStyle(
    fontWeight: FontWeight.w800,
    color: c.text,
    backgroundColor: c.accent.withValues(alpha: 0.18),
  );
  if (p.contains('‹')) {
    final List<InlineSpan> l = <InlineSpan>[];
    final RegExp marca = RegExp('‹([^›]*)›');
    int desde = 0;
    for (final RegExpMatch m in marca.allMatches(p)) {
      l.add(TextSpan(text: p.substring(desde, m.start)));
      l.add(TextSpan(text: m.group(1), style: fuerte));
      desde = m.end;
    }
    l.add(TextSpan(text: p.substring(desde)));
    return l;
  }
  final int i = normalizar(p).indexOf(normalizar(q));
  if (i < 0 || q.isEmpty) {
    return <InlineSpan>[TextSpan(text: p)];
  }
  return <InlineSpan>[
    TextSpan(text: p.substring(0, i)),
    TextSpan(text: p.substring(i, i + q.length), style: fuerte),
    TextSpan(text: p.substring(i + q.length)),
  ];
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
    child: SectionHead(title: texto),
  );
}
