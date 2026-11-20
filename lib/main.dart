// El punto de entrada de NB Books Mobile.
//
// Antes del primer fotograma: abre la base, carga el motor de lectura, lee el
// PC emparejado del llavero y las preferencias de tema e idioma. Con eso la
// primera pantalla ya sale como debe, sin parpadeos.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/nb_books_app.dart';
import 'core/di/providers.dart';
import 'core/i18n/i18n.dart';
import 'core/i18n/idioma_controller.dart';
import 'core/motor/motor.dart';
import 'core/network/pinned_http_overrides.dart';
import 'core/security/secure_store.dart';
import 'data/db/database.dart';
import 'data/demo/demo.dart';
import 'features/study/estudio_screen.dart';
import 'shared/theme/nb_theme.dart';
import 'shared/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // La huella del PC se fija también fuera de `dio`: las portadas de "Todo el
  // catálogo" usan el `HttpClient` global.
  HttpOverrides.global = NbHttpOverrides();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final AppDatabase db = AppDatabase();
  final Directory docs = await getApplicationDocumentsDirectory();
  await Motor.iniciar();
  await sembrarDemoSiHaceFalta(db, docs);

  final (String? tema, String? idioma, String? estudio, PairedPc? pc) = await (
    db.ajuste(kTemaPrefKey),
    db.ajuste(kIdiomaPrefKey),
    db.ajuste(kVistaDeEstudio),
    SecureStore().readPairing().catchError((Object _) => null),
  ).wait;
  final Idioma idiomaInicial = idiomaDeClave(idioma);
  fijarIdioma(idiomaInicial);

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        documentosProvider.overrideWithValue(docs),
        initialPairingProvider.overrideWithValue(pc),
        initialThemeProvider.overrideWithValue(nbThemeKeyFromStored(tema)),
        initialIdiomaProvider.overrideWithValue(idiomaInicial),
        vistaDeEstudioInicialProvider.overrideWithValue(estudio),
      ],
      child: const NbBooksApp(),
    ),
  );
}
