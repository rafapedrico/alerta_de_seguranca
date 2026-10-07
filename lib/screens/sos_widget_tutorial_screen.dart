import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/sos_widget_status_service.dart';

/// Passo a passo para adicionar o Widget SOS ("Botão de Pânico") na tela
/// de início — a tela do iOS adaptada ao Android: o botão "Adicionar à
/// tela inicial" pede ao launcher para adicionar o widget
/// (`requestPinAppWidget`) e, se o launcher não suportar, ficam os passos
/// manuais. Aberta pelo card "Botão SOS na tela de início" em Status de
/// Permissões e, uma única vez, depois do primeiro login (ver
/// [SosWidgetStatusService]).
class SosWidgetTutorialScreen extends StatelessWidget {
  const SosWidgetTutorialScreen({super.key});

  Future<void> _adicionar(BuildContext context) async {
    final pediu = await SosWidgetStatusService.fixarWidget();
    if (pediu || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.sosWidgetFixarSemSuporte)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(title: Text(l10n.sosWidgetTutorialTitulo)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset(
                        'assets/images/sos_widget.png',
                        width: 150,
                        height: 150,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.sosWidgetTutorialIntro,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade800, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _adicionar(context),
                      icon: const Icon(Icons.add_to_home_screen_rounded),
                      label: Text(l10n.sosWidgetBotaoAdicionarTelaInicial),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade400,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _SecaoPassos(
                    icone: Icons.phone_android_rounded,
                    titulo: l10n.sosWidgetTutorialTelaInicioTitulo,
                    passos: [
                      l10n.sosWidgetTutorialTelaInicioPasso1,
                      l10n.sosWidgetTutorialTelaInicioPasso2,
                      l10n.sosWidgetTutorialTelaInicioPasso3,
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(l10n.sosWidgetTutorialEntendi),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecaoPassos extends StatelessWidget {
  const _SecaoPassos({
    required this.icone,
    required this.titulo,
    required this.passos,
  });

  final IconData icone;
  final String titulo;
  final List<String> passos;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone, color: Colors.red.shade400),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < passos.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: Colors.red.shade400,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      passos[i],
                      style: TextStyle(fontSize: 13.5, color: Colors.grey.shade800, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
