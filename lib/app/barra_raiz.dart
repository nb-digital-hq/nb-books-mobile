import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/profile/perfil.dart';
import '../shared/widgets/top_bar.dart';

/// La barra de las cuatro pestañas: el avatar de la persona abre Ajustes.
class BarraRaiz extends ConsumerWidget {
  const BarraRaiz({
    super.key,
    required this.titulo,
    this.tituloWidget,
    this.trailing,
  });

  final String titulo;

  /// Sustituye al título, para un selector como el de Estudio.
  final Widget? tituloWidget;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TopBar(
    title: titulo,
    titleWidget: tituloWidget,
    avatarInicial: ref.watch(inicialPerfilProvider),
    avatarFoto: ref.watch(fotoPerfilProvider).value,
    onProfile: () => context.push('/ajustes'),
    trailing: trailing,
  );
}
