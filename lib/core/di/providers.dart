import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../security/secure_store.dart';

/// La base abierta. Se sustituye en `main` con la ya abierta, para que nadie la
/// espere.
final Provider<AppDatabase> databaseProvider = Provider<AppDatabase>(
  (Ref ref) => throw UnimplementedError('databaseProvider se fija en main()'),
);

/// El llavero del sistema: aquí viven el `device_token` y la huella del PC.
final Provider<SecureStore> secureStoreProvider = Provider<SecureStore>(
  (Ref ref) => SecureStore(),
);

/// El PC emparejado, leído antes del primer fotograma.
final Provider<PairedPc?> initialPairingProvider = Provider<PairedPc?>(
  (Ref ref) => null,
);

/// La carpeta de documentos de la app. Se fija en `main`.
final Provider<Directory> documentosProvider = Provider<Directory>(
  (Ref ref) => throw UnimplementedError('documentosProvider se fija en main()'),
);
