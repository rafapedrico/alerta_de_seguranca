import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

/// Tela exibida quando ESTE aparelho recebe, via Push FCM, o alerta de
/// emergência de OUTRO usuário que o cadastrou como contato de emergência
/// (ver `FcmService`/`NotificacaoService.exibirNotificacaoAlertaRecebido`).
///
/// Distinta da [AlarmeDisparadoScreen] — aquela é para o PRÓPRIO alarme
/// do usuário (com fluxo de PIN para desarmar); esta é somente
/// informativa, mostrando quem disparou o alerta e a mensagem/localização
/// recebida.
class AlertaRecebidoScreen extends StatelessWidget {
  const AlertaRecebidoScreen({
    super.key,
    required this.mensagem,
    this.nomeRemetente,
    this.latitude,
    this.longitude,
  });

  final String mensagem;
  final String? nomeRemetente;
  final double? latitude;
  final double? longitude;

  Future<void> _abrirMapa() async {
    if (latitude == null || longitude == null) return;
    final uri = Uri.parse('https://maps.google.com/?q=$latitude,$longitude');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFF14212E),
      appBar: AppBar(
        backgroundColor: Colors.red.shade700,
        title: Text(l10n.alertaRecebidoTitulo),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 72),
              const SizedBox(height: 16),
              if (nomeRemetente != null && nomeRemetente!.isNotEmpty)
                Text(
                  l10n.alertaRecebidoDe(nomeRemetente!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E313F),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  mensagem,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
              if (latitude != null && longitude != null) ...[
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _abrirMapa,
                  icon: const Icon(Icons.map),
                  label: Text(l10n.alertaRecebidoVerNoMapa),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4C7040),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
              const Spacer(),
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  l10n.fechar,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
