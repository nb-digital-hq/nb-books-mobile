import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/i18n.dart';
import '../../../shared/theme/nb_colors.dart';
import '../../../shared/theme/nb_theme.dart';
import '../../../shared/widgets/app_icons.dart';
import '../../../shared/widgets/sub_header.dart';
import '../application/sync_controller.dart';
import '../data/pairing_repository.dart';
import '../data/qr_payload.dart';

/// El mensaje de un fallo al emparejar, en palabras de quien lee.
String mensajeDeEmparejamiento(String codigo) => switch (codigo) {
  'token_invalido_o_expirado' => tr(
    'El código ya se usó o caducó. Pide uno nuevo en NB Books, Ajustes, Teléfonos.',
  ),
  'limite_alcanzado' => tr(
    'El PC ya tiene 16 teléfonos. Revoca alguno en Ajustes, Teléfonos.',
  ),
  'pc_no_encontrado' => tr(
    'No se encuentra NB Books en esa dirección. Comprueba que el teléfono y el PC están en la misma red.',
  ),
  'red_timeout' || 'red_inalcanzable' => tr(
    'El PC no responde. Puede que su cortafuegos o la red de invitados lo impidan.',
  ),
  'red_tls' => tr('El certificado del PC no coincide con el del código.'),
  'direccion_invalida' => tr('Esa dirección no es válida.'),
  _ => tr('No se pudo emparejar. Inténtalo de nuevo.'),
};

/// Emparejar con NB Books en el PC: escaneando el QR o tecleando el código.
class EmparejarScreen extends ConsumerStatefulWidget {
  const EmparejarScreen({super.key});

  @override
  ConsumerState<EmparejarScreen> createState() => _EmparejarScreenState();
}

class _EmparejarScreenState extends ConsumerState<EmparejarScreen> {
  bool _manual = false;
  bool _ocupado = false;
  bool _leido = false;
  String? _fallo;
  final TextEditingController _direccion = TextEditingController();
  final TextEditingController _codigo = TextEditingController();

  @override
  void dispose() {
    _direccion.dispose();
    _codigo.dispose();
    super.dispose();
  }

  Future<void> _hecho(Future<void> Function() f) async {
    setState(() {
      _ocupado = true;
      _fallo = null;
    });
    try {
      await f();
      if (mounted) {
        context.go('/inicio');
        await context.push('/seleccion');
      }
    } on PairingException catch (e) {
      setState(() {
        _fallo = mensajeDeEmparejamiento(e.code);
        _leido = false;
      });
    } finally {
      if (mounted) {
        setState(() => _ocupado = false);
      }
    }
  }

  void _alLeer(Code code) {
    final String? raw = code.text;
    if (_leido || _ocupado || !code.isValid || raw == null) {
      return;
    }
    final QrPairingPayload? qr = QrPairingPayload.tryParse(raw);
    if (qr == null) {
      setState(() => _fallo = tr('Ese código no es de NB Books.'));
      return;
    }
    _leido = true;
    _hecho(() => ref.read(syncProvider.notifier).emparejarConQr(qr));
  }

  @override
  Widget build(BuildContext context) {
    final NbColors c = context.nb;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SubHeader(title: tr('Emparejar con el PC')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                tr(
                  'En NB Books, abre Ajustes, Teléfonos y pulsa Emparejar un Teléfono. Todo viaja solo por tu red local.',
                ),
                style: TextStyle(color: c.text2, height: 1.4),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: _manual ? _formulario(c) : _escaner(c)),
            if (_fallo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(_fallo!, style: TextStyle(color: c.accent)),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextButton(
                onPressed: _ocupado
                    ? null
                    : () => setState(() {
                        _manual = !_manual;
                        _fallo = null;
                      }),
                child: Text(
                  _manual
                      ? tr('Escanear el código QR')
                      : tr('Escribir el código'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ZXing (zxing-cpp) y no ML Kit: el lector es código abierto y no mete en
  // el APK un binario propietario, requisito de la licencia (ADR-005).
  Widget _escaner(NbColors c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ReaderWidget(
            codeFormat: Format.qrCode,
            onScan: _alLeer,
            showGallery: false,
            showToggleCamera: false,
            showScannerOverlay: false,
            cropPercent: 0.7,
            scanDelay: const Duration(milliseconds: 250),
            loading: const ColoredBox(color: Colors.black),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  border: Border.all(color: c.accent, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          if (_ocupado)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    ),
  );

  Widget _formulario(NbColors c) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    children: <Widget>[
      TextField(
        controller: _direccion,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: tr('Dirección del PC'),
          hintText: '192.168.1.20:8831',
          prefixIcon: const Icon(AppIcons.laptop),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _codigo,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(
          fontFamily: NbFonts.display,
          letterSpacing: 4,
          fontSize: 20,
        ),
        decoration: InputDecoration(
          labelText: tr('Código de 8 caracteres'),
          prefixIcon: const Icon(AppIcons.qr),
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _ocupado
            ? null
            : () => _hecho(
                () => ref
                    .read(syncProvider.notifier)
                    .emparejarConCodigo(_direccion.text, _codigo.text),
              ),
        child: _ocupado
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(tr('Emparejar')),
      ),
    ],
  );
}
