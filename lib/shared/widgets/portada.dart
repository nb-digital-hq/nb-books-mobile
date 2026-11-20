import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/nb_colors.dart';
import '../theme/nb_theme.dart';

/// La portada de un libro: la descargada, o una sustituta con el título y la
/// autoría en los colores del tema. Nunca un cuadro gris: un libro sin portada
/// se reconoce por su título, como en una estantería.
class Portada extends StatelessWidget {
  const Portada({
    super.key,
    required this.titulo,
    this.autor,
    this.ruta,
    this.imagen,
    this.radio = 6,
  });

  final String titulo;
  final String? autor;

  /// Ruta de la portada en el teléfono.
  final String? ruta;

  /// O una imagen ya resuelta (la del PC en directo).
  final ImageProvider? imagen;
  final double radio;

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    // Decodificada al tamaño de una portada de rejilla y no al del archivo:
    // una biblioteca de cientos de libros no se come la memoria al desplazar.
    final ImageProvider? img =
        imagen ??
        (ruta != null
            ? ResizeImage(
                FileImage(File(ruta!)),
                width: 360,
                policy: ResizeImagePolicy.fit,
              )
            : null);
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radio),
        child: img != null
            ? Image(
                image: img,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _Sustituta(titulo, autor, c),
              )
            : _Sustituta(titulo, autor, c),
      ),
    );
  }
}

class _Sustituta extends StatelessWidget {
  const _Sustituta(this.titulo, this.autor, this.c);

  final String titulo;
  final String? autor;
  final NbColors c;

  @override
  Widget build(BuildContext context) {
    final int h = titulo.hashCode & 0x7fffffff;
    final double t = 0.14 + (h % 5) * 0.05;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.lerp(c.bg3, c.accent, t)!,
            Color.lerp(c.bg2, c.ambient, t * 0.7)!,
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double base = box.maxWidth;
          // En miniatura no caben título y autoría: se queda el título, y lo
          // que no cabe se corta en lugar de desbordarse.
          final bool conAutor =
              base >= 90 && autor != null && autor!.isNotEmpty;
          return ClipRect(
            child: Padding(
              padding: EdgeInsets.all(base * 0.09),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      titulo,
                      maxLines: 5,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontFamily: NbFonts.display,
                        fontWeight: FontWeight.w800,
                        fontSize: (base * 0.13).clamp(6.0, 22.0),
                        height: 1.1,
                        color: c.text,
                      ),
                    ),
                  ),
                  if (conAutor) ...<Widget>[
                    const Spacer(),
                    Text(
                      autor!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: NbFonts.ui,
                        fontWeight: FontWeight.w600,
                        fontSize: (base * 0.085).clamp(8.0, 14.0),
                        color: c.text2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
