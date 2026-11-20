# ADR-001: Flutter, Drift y Riverpod, con el motor de lectura de NB Books en Rust

> **Estado:** Aceptado.

**Fecha:** 2026-11-19

## Contexto

NB Books Mobile es el lector de NB Books en el teléfono: abre EPUB, PDF y cómics, sincroniza con el PC lo que la
persona hace al leer y controla el lector del PC. La suite reserva dos pilas: Rust con Tauri para escritorio y
Flutter para móvil. Las posiciones de lectura de NB Books dependen del texto que extrae su propio motor
([motor de lectura](008-shared-reading-engine.md)).

## Alternativas consideradas

1. **Nativo por plataforma (Kotlin y Swift).** Dos bases de código para un equipo pequeño y ninguna relación con el
   motor de NB Books.
2. **Tauri móvil.** Comparte la pila del escritorio, pero la sesión multimedia, la notificación, los widgets y las
   teclas de volumen exigen igualmente código nativo, y la interfaz se apartaría del resto de apps móviles de la
   suite.
3. **Flutter puro con un lector reescrito en Dart.** La interfaz de la suite, pero un segundo motor que tendría que
   coincidir carácter a carácter con el de NB Books.
4. **Flutter para la interfaz y el motor de NB Books en Rust por `flutter_rust_bridge`.**

## Decisión

Alternativa 4:

| Pieza | Elección | Motivo |
|---|---|---|
| Interfaz | Flutter (Dart 3), Material 3 con la estética de las apps móviles de la suite | Una base para Android e iOS y la misma identidad que NB Sound Mobile |
| Persistencia | Drift sobre SQLite | Consultas tipadas y reactivas; la biblioteca se ordena y filtra en SQL |
| Estado | Riverpod | Dependencias explícitas y sustituibles en pruebas |
| Navegación | go_router | Rutas declarativas, con el mismo patrón que NB Sound Mobile |
| Motor de lectura | Crate de NB Books, llamado con `flutter_rust_bridge` | Un solo motor: mismas posiciones, mismo saneador |
| Superficie de lectura | `webview_flutter` sobre el marcado ya saneado | La misma forma de pintar que el escritorio |
| Red | dio y web_socket_channel | Fijación TLS por huella y WebSocket de Leer en el PC |
| Voz | `flutter_tts` | Las voces del sistema, sin descargar modelos |

## Consecuencias

* El repositorio contiene un crate Rust (`native/`) que se compila para cada ABI de Android y para iOS; `just setup`
  lo hace y la CI lo comprueba.
* Lo que depende de servicios propios de Android (teclas de volumen e instalador de paquetes) se implementa en
  Kotlin detrás de canales y no existe en iOS
  ([plataformas](007-platforms-and-distribution.md)).
* El código generado de Drift (`*.g.dart`) no se versiona: se produce con `just setup`. El puente con Rust sí se
  versiona, para que la CI no dependa del generador, y se rehace con `just puente`.
