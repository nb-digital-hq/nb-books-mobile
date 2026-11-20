# Reglas de R8 para release.
#
# El escáner QR usa zxing-cpp por FFI (flutter_zxing) y el motor de lectura es
# una biblioteca nativa a la que Dart llama por símbolo: R8 no ve ninguno de
# los dos, así que no necesitan reglas. CameraX y los plugins de Flutter traen
# sus propias reglas de consumidor.
