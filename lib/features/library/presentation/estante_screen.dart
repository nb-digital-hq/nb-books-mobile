import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/util/responsive.dart';
import '../../../shared/widgets/sub_header.dart';
import '../application/estantes.dart';
import '../application/fotos_de_autores.dart';
import 'libro_widgets.dart';

/// Una estantería: los libros de un autor, una serie, una colección o una
/// materia. Las series se leen en orden, así que van en lista con su número.
class EstanteScreen extends ConsumerWidget {
  const EstanteScreen({super.key, required this.tipo, required this.valor});
  final String tipo;
  final String valor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final Estante estante = Estante.values.firstWhere(
      (Estante e) => e.name == tipo,
      orElse: () => Estante.autor,
    );
    final String clave = Uri.decodeComponent(valor);
    final List<Grupo> grupos = agrupar(
      ref.watch(librosVisiblesProvider),
      estante,
      colecciones: ref.watch(coleccionesProvider).value ?? const <Coleccion>[],
    );
    final Grupo? g = grupos.where((Grupo x) => x.clave == clave).firstOrNull;
    final List<Edicion> libros = g?.libros ?? const <Edicion>[];
    final Map<String, (double, String)> avance = ref.watch(avanceProvider);
    final int leidos = libros
        .where((Edicion e) => (avance[e.id]?.$1 ?? 0) >= 0.98)
        .length;
    final FotoDeAutor? foto = estante == Estante.autor
        ? ref.watch(fotoDeAutorProvider(g?.nombre ?? clave))
        : null;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(child: SubHeader(title: g?.nombre ?? clave)),
            if (foto != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
                  child: Center(child: RetratoDeAutor(foto: foto, lado: 132)),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Text(
                  <String>[
                    libros.length == 1
                        ? tr('1 libro')
                        : tr('{n} libros', <String, Object?>{
                            'n': libros.length,
                          }),
                    if (leidos > 0)
                      tr('{n} terminados', <String, Object?>{'n': leidos}),
                  ].join(' · '),
                  textAlign: foto == null ? null : TextAlign.center,
                  style: TextStyle(
                    fontFamily: NbFonts.ui,
                    fontSize: 13,
                    color: c.text3,
                  ),
                ),
              ),
            ),
            if (foto != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                  child: Text(
                    tr('Foto: {credito}', <String, Object?>{
                      'credito': foto.credito,
                    }),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: c.text3),
                  ),
                ),
              ),
            if (estante == Estante.serie)
              SliverList.builder(
                itemCount: libros.length,
                itemBuilder: (BuildContext ctx, int i) => FilaDeLibro(
                  edicion: libros[i],
                  detalle: libros[i].indiceSerie == null
                      ? null
                      : tr('Libro {n}', <String, Object?>{
                          'n': _numero(libros[i].indiceSerie!),
                        }),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount:
                        gridColumns(MediaQuery.sizeOf(context).width) + 1,
                    mainAxisSpacing: 18,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.48,
                  ),
                  itemCount: libros.length,
                  itemBuilder: (BuildContext ctx, int i) => TarjetaDeLibro(
                    edicion: libros[i],
                    conAutor: estante != Estante.autor,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _numero(double n) =>
      n == n.roundToDouble() ? '${n.toInt()}' : '$n';
}
