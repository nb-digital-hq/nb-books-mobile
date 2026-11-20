import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/providers.dart';
import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/chip_pill.dart';
import '../../../shared/widgets/portada.dart';
import '../../../shared/widgets/section_head.dart';
import '../../local_books/libros_del_telefono.dart';
import '../../offline/descargas.dart';
import '../../profile/perfil.dart';
import '../../settings/pc_screen.dart';
import '../../sync/application/sync_controller.dart';
import '../application/biblioteca.dart';
import '../application/estantes.dart';
import '../application/fotos_de_autores.dart';
import 'libro_widgets.dart';

final StreamProviderFamily<Edicion?, String> _edicion =
    StreamProvider.family<Edicion?, String>(
      (Ref ref, String id) => ref.watch(databaseProvider).vigilarEdicion(id),
    );

final StreamProviderFamily<List<Anotacion>, String> _anotaciones =
    StreamProvider.family<List<Anotacion>, String>(
      (Ref ref, String id) =>
          ref.watch(databaseProvider).vigilarAnotaciones(id),
    );

/// La ficha de un libro: qué es, por dónde va en cada dispositivo, qué se
/// puede hacer con él, lo anotado y por dónde seguir (su serie y su autor).
class FichaScreen extends ConsumerWidget {
  const FichaScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final Edicion? e = ref.watch(_edicion(id)).value;
    final List<Posicion> posiciones =
        ref.watch(posicionesProvider).value ?? const <Posicion>[];
    final double? descarga = ref.watch(descargaDe(id));
    if (e == null) {
      return Scaffold(
        backgroundColor: c.bg,
        body: const SafeArea(child: BackButton()),
      );
    }
    Posicion? de(String d) {
      for (final Posicion p in posiciones) {
        if (p.edicion == id && p.dispositivo == d) {
          return p;
        }
      }
      return null;
    }

    final Posicion? aqui = de('telefono');
    final Posicion? pc = de('pc');
    final List<String> materias = <String>[
      for (final dynamic m in listaJson(e.materias))
        if (m is Map<String, dynamic>) m['nombre'] as String? ?? '',
    ];
    final String autores = autoresDe(e);
    final String? autor = listaJson(e.autores).whereType<String>().firstOrNull;
    final List<Edicion> libros = ref.watch(librosVisiblesProvider);
    final List<Edicion> deLaSerie = e.serie == null
        ? const <Edicion>[]
        : agrupar(libros, Estante.serie)
                  .where((Grupo g) => g.clave == e.serie)
                  .firstOrNull
                  ?.libros
                  .where((Edicion x) => x.id != e.id)
                  .toList() ??
              const <Edicion>[];
    final Set<String> enSerie = deLaSerie.map((Edicion x) => x.id).toSet();
    final List<Edicion> delAutor = autor == null
        ? const <Edicion>[]
        : agrupar(libros, Estante.autor)
                  .where((Grupo g) => g.clave == autor)
                  .firstOrNull
                  ?.libros
                  .where((Edicion x) => x.id != e.id && !enSerie.contains(x.id))
                  .toList() ??
              const <Edicion>[];
    final List<Anotacion> anotadas =
        (ref.watch(_anotaciones(id)).value ?? const <Anotacion>[])
            .where((Anotacion a) => a.tipo != 'ink')
            .toList();

    final List<(String, String)> detalles = <(String, String)>[
      if (e.serie != null)
        (
          tr('Serie'),
          e.indiceSerie != null
              ? '${e.serie} · ${_numero(e.indiceSerie!)}'
              : e.serie!,
        ),
      if (e.editorial != null) (tr('Editorial'), e.editorial!),
      if (e.fecha != null) (tr('Publicado'), e.fecha!),
      if (e.idioma != null)
        (tr('Idioma'), FichaScreen.nombreDeIdioma(e.idioma!)),
      (tr('Formato'), _formato(e.tipo)),
      if (e.bytes > 0) (tr('Tamaño'), bytesLegibles(e.bytes)),
      (
        tr('Dónde está'),
        e.origen == 'telefono'
            ? tr('Solo en este teléfono')
            : e.ruta != null
            ? tr('En el PC y descargado aquí')
            : tr('En el PC'),
      ),
    ];

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: <Widget>[
          CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _Cabecera(e: e, autores: autores),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _Acciones(edicion: e, descarga: descarga),
                ),
              ),
              if (aqui != null || pc != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: c.bg2,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.line),
                      ),
                      child: Column(
                        children: <Widget>[
                          if (aqui != null)
                            _Progreso(
                              etiqueta: tr('En este teléfono'),
                              posicion: aqui,
                              icono: AppIcons.phone,
                            ),
                          if (pc != null)
                            _Progreso(
                              etiqueta: tr('En el PC'),
                              posicion: pc,
                              icono: AppIcons.laptop,
                              alPulsar: e.ruta == null
                                  ? null
                                  : () => context.push(
                                      '/leer/${e.id}',
                                      extra:
                                          jsonDecode(pc.locator)
                                              as Map<String, dynamic>,
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (e.sinopsis != null && e.sinopsis!.trim().isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                    child: _Sinopsis(texto: e.sinopsis!.trim()),
                  ),
                ),
              if (materias.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final String m in materias)
                          ChipPill(
                            label: m,
                            icon: AppIcons.subject,
                            onTap: () => context.push(
                              '/estante/${Estante.materia.name}/${Uri.encodeComponent(m)}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (anotadas.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: _Anotado(edicion: e, anotadas: anotadas),
                  ),
                ),
              if (deLaSerie.isNotEmpty) ...<Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: SectionHead(
                      title: tr('En la serie {s}', <String, Object?>{
                        's': e.serie,
                      }),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _Carril(libros: deLaSerie)),
              ],
              if (delAutor.isNotEmpty) ...<Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: SectionHead(
                      title: tr('Más de {autor}', <String, Object?>{
                        'autor': autor,
                      }),
                      actionLabel: tr('Ver todo'),
                      onAction: () => context.push(
                        '/estante/${Estante.autor.name}/${Uri.encodeComponent(autor!)}',
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _Carril(libros: delAutor)),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: SectionHead(title: tr('Detalles')),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                sliver: SliverList.list(
                  children: <Widget>[
                    for (final (String k, String v) in detalles)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SizedBox(
                              width: 120,
                              child: Text(k, style: TextStyle(color: c.text3)),
                            ),
                            Expanded(
                              child: Text(
                                v,
                                style: TextStyle(
                                  color: c.text,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // La barra de estado tiene fondo propio: lo que se desplaza no pasa
          // por debajo de la hora y los iconos.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.paddingOf(context).top,
            child: ColoredBox(color: c.bg.withValues(alpha: 0.94)),
          ),
        ],
      ),
    );
  }

  static String _numero(double n) =>
      n == n.roundToDouble() ? '${n.round()}' : '$n';

  /// El nombre del idioma en su propia lengua, como lo reconoce quien lee.
  static String nombreDeIdioma(String codigo) =>
      switch (codigo.toLowerCase().split(RegExp('[-_]')).first) {
        'es' => 'Español',
        'en' => 'English',
        'pt' => 'Português',
        'fr' => 'Français',
        'de' => 'Deutsch',
        'it' => 'Italiano',
        'ca' => 'Català',
        'gl' => 'Galego',
        'eu' => 'Euskara',
        'la' => 'Latina',
        _ => codigo,
      };

  static String _formato(String tipo) => switch (tipo) {
    'application/epub+zip' => 'EPUB',
    'application/pdf' => 'PDF',
    'application/vnd.comicbook+zip' || 'application/x-cbz' => tr('Cómic (CBZ)'),
    _ => tipo,
  };
}

/// La cabecera: la portada sobre su propio color, difuminada, como la tapa de
/// un libro en la mesa.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.e, required this.autores});
  final Edicion e;
  final String autores;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final double arriba = MediaQuery.paddingOf(context).top;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: e.rutaPortada == null
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[c.soft, c.bg],
                    ),
                  ),
                )
              : ShaderMask(
                  shaderCallback: (Rect r) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.black, Colors.transparent],
                    stops: <double>[0.35, 1],
                  ).createShader(r),
                  blendMode: BlendMode.dstIn,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: Opacity(
                      opacity: 0.55,
                      child: Image(
                        image: ResizeImage(
                          FileImage(File(e.rutaPortada!)),
                          width: 120,
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(8, arriba + 4, 8, 0),
          child: Column(
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: Icon(AppIcons.back, color: c.text),
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/inicio'),
                ),
              ),
              SizedBox(
                width: 168,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x88000000),
                        blurRadius: 24,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Portada(
                    titulo: e.titulo,
                    autor: autores,
                    ruta: e.rutaPortada,
                    radio: 10,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  e.titulo,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NbFonts.display,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    color: c.text,
                  ),
                ),
              ),
              if (e.subtitulo != null && e.subtitulo!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  e.subtitulo!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.text2),
                ),
              ],
              if (autores.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                _Autoria(e: e, autores: autores),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Quién lo escribió, con la foto del primer autor si se pidieron (ADR-012), y
/// que lleva a su estantería.
class _Autoria extends ConsumerWidget {
  const _Autoria({required this.e, required this.autores});
  final Edicion e;
  final String autores;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final String? primero = listaJson(
      e.autores,
    ).whereType<String>().firstOrNull;
    final FotoDeAutor? foto = primero == null
        ? null
        : ref.watch(fotoDeAutorProvider(primero));
    final Widget nombre = Flexible(
      child: Text(
        autores,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.accent,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: primero == null
          ? null
          : () => context.push(
              '/estante/${Estante.autor.name}/${Uri.encodeComponent(primero)}',
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (foto != null) ...<Widget>[
              RetratoDeAutor(foto: foto, lado: 28),
              const SizedBox(width: 8),
            ],
            nombre,
          ],
        ),
      ),
    );
  }
}

/// La sinopsis, plegada si es larga.
class _Sinopsis extends StatefulWidget {
  const _Sinopsis({required this.texto});
  final String texto;

  @override
  State<_Sinopsis> createState() => _SinopsisState();
}

class _SinopsisState extends State<_Sinopsis> {
  bool _abierta = false;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final bool larga = widget.texto.length > 280;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Text(
            widget.texto,
            maxLines: _abierta || !larga ? null : 5,
            overflow: _abierta || !larga ? null : TextOverflow.fade,
            style: TextStyle(color: c.text2, height: 1.55, fontSize: 14.5),
          ),
        ),
        if (larga)
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => setState(() => _abierta = !_abierta),
            child: Text(_abierta ? tr('Ver menos') : tr('Ver más')),
          ),
      ],
    );
  }
}

class _Carril extends StatelessWidget {
  const _Carril({required this.libros});
  final List<Edicion> libros;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 236,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: libros.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (BuildContext ctx, int i) =>
          TarjetaDeLibro(edicion: libros[i], ancho: 116),
    ),
  );
}

/// Lo anotado en este libro: las últimas citas y cuántas hay.
class _Anotado extends StatelessWidget {
  const _Anotado({required this.edicion, required this.anotadas});
  final Edicion edicion;
  final List<Anotacion> anotadas;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final List<Anotacion> ultimas = anotadas.reversed.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionHead(
          title: tr('Tus anotaciones ({n})', <String, Object?>{
            'n': anotadas.length,
          }),
        ),
        for (final Anotacion a in ultimas)
          Builder(
            builder: (BuildContext ctx) {
              final Map<String, dynamic> l =
                  jsonDecode(a.locator) as Map<String, dynamic>;
              final String texto = a.tipo == 'bookmark'
                  ? tr('Marcador')
                  : ((l['text'] as Map<String, dynamic>?)?['highlight']
                            as String? ??
                        a.texto ??
                        '');
              return InkWell(
                onTap: edicion.ruta == null
                    ? null
                    : () => context.push('/leer/${edicion.id}', extra: l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 3,
                        height: 40,
                        margin: const EdgeInsets.only(right: 12, top: 2),
                        decoration: BoxDecoration(
                          color: a.tipo == 'note'
                              ? const Color(0xFFFFA502)
                              : c.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          texto,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'serif',
                            height: 1.4,
                            color: c.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _Acciones extends ConsumerWidget {
  const _Acciones({required this.edicion, required this.descarga});
  final Edicion edicion;
  final double? descarga;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enTelefono = edicion.ruta != null;
    final bool conPc =
        ref.watch(syncProvider.select((EstadoSync s) => s.pc)) != null;
    final bool delPc = edicion.origen == 'pc';
    void avisar(String t) => ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
    const Size alto = Size.fromHeight(50);

    final Widget principal;
    if (enTelefono) {
      principal = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: alto),
        onPressed: () => context.push('/leer/${edicion.id}'),
        icon: const Icon(AppIcons.read),
        label: Text(tr('Leer')),
      );
    } else if (descarga != null) {
      principal = OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: alto),
        onPressed: () =>
            ref.read(descargasProvider.notifier).cancelar(edicion.id),
        icon: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            value: descarga == 0 ? null : descarga,
            strokeWidth: 2,
          ),
        ),
        label: Text(
          tr('Descargando {n} % · cancelar', <String, Object?>{
            'n': ((descarga ?? 0) * 100).round(),
          }),
        ),
      );
    } else {
      principal = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: alto),
        onPressed: conPc
            ? () async {
                final String? fallo = await ref
                    .read(descargasProvider.notifier)
                    .descargar(edicion);
                if (fallo != null && context.mounted) {
                  avisar(
                    tr(
                      'No se pudo descargar. Comprueba la conexión con el PC.',
                    ),
                  );
                }
              }
            : null,
        icon: const Icon(AppIcons.download),
        label: Text(
          conPc ? tr('Descargar') : tr('Conecta con el PC para descargar'),
        ),
      );
    }

    final List<Widget> secundarias = <Widget>[
      // Con el PC cerca, se lee sin ocupar espacio: el libro va a una caché
      // que se recorta sola.
      if (!enTelefono && descarga == null && conPc && delPc)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: alto),
          onPressed: () async {
            final String? fallo = await ref
                .read(descargasProvider.notifier)
                .descargar(edicion, temporal: true);
            if (!context.mounted) {
              return;
            }
            if (fallo != null) {
              avisar(tr('No se pudo abrir. Comprueba la conexión con el PC.'));
            } else {
              unawaited(context.push('/leer/${edicion.id}'));
            }
          },
          icon: const Icon(AppIcons.read, size: 18),
          label: Text(tr('Leer sin descargar')),
        ),
      if (conPc && delPc)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: alto),
          onPressed: () => context.push('/mando', extra: edicion.id),
          icon: const Icon(AppIcons.remote, size: 18),
          label: Text(tr('Leer en el PC')),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        principal,
        // Una debajo de otra: lado a lado, en un teléfono estrecho "Leer sin
        // descargar" no cabe y los dos botones acabarían con letra distinta.
        for (final Widget b in secundarias) ...<Widget>[
          const SizedBox(height: 10),
          b,
        ],
        if (enTelefono && delPc)
          TextButton.icon(
            onPressed: () async {
              await ref.read(syncRepositoryProvider).quitarDescarga(edicion);
              avisar(tr('Se quitó del teléfono. Lo anotado se queda.'));
            },
            icon: const Icon(AppIcons.downloadOff, size: 18),
            label: Text(tr('Quitar del teléfono')),
          ),
        if (edicion.origen == 'telefono')
          TextButton.icon(
            onPressed: () async {
              final bool? si = await showDialog<bool>(
                context: context,
                builder: (BuildContext ctx) => AlertDialog(
                  title: Text(tr('¿Quitar este libro?')),
                  content: Text(
                    tr(
                      'Se borran el archivo y lo anotado en él, porque solo estaban en este teléfono.',
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(tr('Cancelar')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(tr('Quitar')),
                    ),
                  ],
                ),
              );
              if (si == true) {
                await quitarLibroDelTelefono(
                  ref.read(databaseProvider),
                  edicion,
                );
                if (context.mounted) {
                  context.pop();
                }
              }
            },
            icon: const Icon(AppIcons.trash, size: 18),
            label: Text(tr('Quitar')),
          ),
      ],
    );
  }
}

class _Progreso extends StatelessWidget {
  const _Progreso({
    required this.etiqueta,
    required this.posicion,
    required this.icono,
    this.alPulsar,
  });

  final String etiqueta;
  final Posicion posicion;
  final IconData icono;
  final VoidCallback? alPulsar;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final double p =
        (posicion.progresion ?? progresionDe(posicion.locator) ?? 0).clamp(
          0.0,
          1.0,
        );
    return ListTile(
      leading: Icon(icono, color: c.text2),
      title: Text(etiqueta),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: LinearProgressIndicator(
          value: p.clamp(0.02, 1.0),
          minHeight: 4,
          color: c.accent,
          backgroundColor: c.line,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      trailing: Text(
        '${porcentajeLegible(p)}\n${haceCuanto(posicion.actualizadoEn)}',
        textAlign: TextAlign.end,
        style: TextStyle(fontSize: 12, color: c.text2),
      ),
      onTap: alPulsar,
    );
  }
}
