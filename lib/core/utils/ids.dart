import 'dart:math';

final Random _azar = Random.secure();

/// Un identificador nuevo: 32 cifras hexadecimales al azar, la misma forma que
/// usa NB Books. Lo crea quien hace la cosa, así que llegar dos veces al PC no
/// la duplica.
String nuevoId() {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 16; i++) {
    b.write(_azar.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}
