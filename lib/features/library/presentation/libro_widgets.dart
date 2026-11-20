import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/i18n.dart';
import '../../../data/db/database.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/portada.dart';
import '../../offline/descargas.dart';
import '../../profile/perfil.dart';
import '../application/biblioteca.dart';
import '../application/estantes.dart';
import '../application/fotos_de_autores.dart';

/// Una portada con su título y autoría debajo, y lo leído sobre la portada.
/// Lleva a la ficha.
class TarjetaDeLibro extends ConsumerWidget {
  const TarjetaDeLibro({
    super.key,
    required this.edicion,
    this.ancho,
    this.conAutor = true,
  });
  final Edicion edicion;
  final double? ancho;
  final bool conAutor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final double? descarga = ref.watch(descargaDe(edicion.id));
    final double? avance = ref.watch(
      avanceProvider.select(
        (Map<String, (double, String)> m) => m[edicion.id]?.$1,
      ),
    );
    final String autor = autoresDe(edicion);
    return SizedBox(
      width: ancho,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.push('/libro/${edicion.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Stack(
              children: <Widget>[
                Portada(
                  titulo: edicion.titulo,
                  autor: autor,
                  ruta: edicion.rutaPortada,
                ),
                if (avance != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(6),
                      ),
                      child: LinearProgressIndicator(
                        // Una franja mínima: empezado se ve aunque sea poco.
                        value: avance.clamp(0.03, 1.0),
                        minHeight: 4,
                        color: avance >= kTerminado ? c.text2 : c.accent,
                        backgroundColor: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                Positioned(
                  right: 6,
                  top: 6,
                  child: Distintivo(edicion: edicion, descarga: descarga),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              edicion.titulo,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: NbFonts.ui,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: c.text,
                height: 1.2,
              ),
            ),
            if (conAutor && autor.isNotEmpty)
              Text(
                autor,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: NbFonts.ui,
                  fontSize: 12,
                  color: c.text3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Un libro en fila: portada pequeña, título, autoría, lo leído y su estado.
class FilaDeLibro extends ConsumerWidget {
  const FilaDeLibro({super.key, required this.edicion, this.detalle});
  final Edicion edicion;

  /// Lo que va bajo la autoría en lugar del avance (p. ej. el número de serie).
  final String? detalle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final double? descarga = ref.watch(descargaDe(edicion.id));
    final double? avance = ref.watch(
      avanceProvider.select(
        (Map<String, (double, String)> m) => m[edicion.id]?.$1,
      ),
    );
    return InkWell(
      onTap: () => context.push('/libro/${edicion.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 48,
              child: Portada(
                titulo: edicion.titulo,
                ruta: edicion.rutaPortada,
                radio: 4,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    edicion.titulo,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NbFonts.ui,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    autoresDe(edicion),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: c.text3),
                  ),
                  const SizedBox(height: 6),
                  if (detalle != null)
                    Text(
                      detalle!,
                      style: TextStyle(fontSize: 12, color: c.text2),
                    )
                  else if (avance != null)
                    Row(
                      children: <Widget>[
                        SizedBox(
                          width: 90,
                          child: LinearProgressIndicator(
                            value: avance.clamp(0.03, 1.0),
                            minHeight: 3,
                            color: c.accent,
                            backgroundColor: c.line,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          avance >= kTerminado
                              ? tr('Terminado')
                              : porcentajeLegible(avance),
                          style: TextStyle(fontSize: 12, color: c.text3),
                        ),
                      ],
                    )
                  else
                    Text(
                      tr('Sin empezar'),
                      style: TextStyle(fontSize: 12, color: c.text3),
                    ),
                ],
              ),
            ),
            Distintivo(edicion: edicion, descarga: descarga),
          ],
        ),
      ),
    );
  }
}

/// El estado del archivo de un libro: descargando, descargado o del teléfono.
class Distintivo extends StatelessWidget {
  const Distintivo({super.key, required this.edicion, required this.descarga});
  final Edicion edicion;
  final double? descarga;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final Widget? icono = descarga != null
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              value: descarga == 0 ? null : descarga,
              strokeWidth: 2,
              color: c.accent,
            ),
          )
        : edicion.origen == 'telefono'
        ? Icon(AppIcons.phone, size: 14, color: c.text)
        : edicion.ruta != null
        ? Icon(AppIcons.downloadDone, size: 14, color: c.accent)
        : null;
    if (icono == null) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.bg.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: icono,
    );
  }
}

/// Unas portadas en abanico para una estantería.
class AbanicoDePortadas extends StatelessWidget {
  const AbanicoDePortadas({super.key, required this.libros, this.alto = 64});
  final List<Edicion> libros;
  final double alto;

  @override
  Widget build(BuildContext context) {
    final List<Edicion> tres = libros.take(3).toList();
    final double ancho = alto * 2 / 3;
    return SizedBox(
      width: ancho + (tres.length - 1) * ancho * 0.38,
      height: alto,
      child: Stack(
        children: <Widget>[
          for (int i = tres.length - 1; i >= 0; i--)
            Positioned(
              left: i * ancho * 0.38,
              top: i * 3.0,
              bottom: i * 3.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x66000000), blurRadius: 6),
                  ],
                ),
                child: Portada(
                  titulo: tres[i].titulo,
                  ruta: tres[i].rutaPortada,
                  radio: 4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Una estantería en fila: portadas, nombre y cuántos libros.
class FilaDeGrupo extends ConsumerWidget {
  const FilaDeGrupo({super.key, required this.grupo, required this.estante});
  final Grupo grupo;
  final Estante estante;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NbColors c = context.nb;
    final FotoDeAutor? foto = estante == Estante.autor
        ? ref.watch(fotoDeAutorProvider(grupo.nombre))
        : null;
    return InkWell(
      onTap: () => context.push(
        '/estante/${estante.name}/${Uri.encodeComponent(grupo.clave)}',
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 80,
              child: Align(
                alignment: Alignment.centerLeft,
                child: foto == null
                    ? AbanicoDePortadas(libros: grupo.libros)
                    : RetratoDeAutor(foto: foto, lado: 64),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    grupo.nombre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: NbFonts.ui,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    grupo.libros.length == 1
                        ? tr('1 libro')
                        : tr('{n} libros', <String, Object?>{
                            'n': grupo.libros.length,
                          }),
                    style: TextStyle(fontSize: 12.5, color: c.text3),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.chevronRight, color: c.text3, size: 20),
          ],
        ),
      ),
    );
  }
}

/// El porcentaje leído para enseñarlo: "<1 %" antes del primer punto entero,
/// que un libro empezado no diga 0 %.
String porcentajeLegible(double v) => v < 0.01
    ? tr('<1 %')
    : tr('{n} %', <String, Object?>{'n': (v * 100).round()});

/// La foto de un autor (ADR-012), redonda. Si el archivo ya no está, deja el
/// hueco del color de superficie en lugar de un error.
class RetratoDeAutor extends StatelessWidget {
  const RetratoDeAutor({super.key, required this.foto, required this.lado});
  final FotoDeAutor foto;
  final double lado;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    final int px = (lado * MediaQuery.devicePixelRatioOf(context)).round();
    return Semantics(
      image: true,
      label: tr('Foto del autor'),
      child: ClipOval(
        child: Container(
          width: lado,
          height: lado,
          color: c.bg3,
          child: Image.file(
            File(foto.archivo!),
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.4),
            cacheWidth: px,
            gaplessPlayback: true,
            // Aparece en lugar de saltar: la foto se decodifica un instante
            // después de pintarse la fila.
            frameBuilder: (_, Widget hijo, int? marco, bool sincrono) =>
                sincrono
                ? hijo
                : AnimatedOpacity(
                    opacity: marco == null ? 0 : 1,
                    duration: const Duration(milliseconds: 220),
                    child: hijo,
                  ),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
