import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_navigator.dart';
import '../services/database_helper.dart';
import '../services/exclusao_conta_service.dart';
import '../widgets/pin_dialog.dart';
import 'login_screen.dart';

/// Painel de assinaturas de cada loja — aberto pelo atalho "Gerenciar /
/// Cancelar Assinatura na Loja" (ver [_ExcluirContaScreenState._abrirAssinaturaNaLoja]).
/// Cada loja só reconhece assinaturas compradas nela mesma: o link do
/// Google Play não mostra nada de uma assinatura feita via App Store, e
/// vice-versa — por isso a escolha depende da plataforma em que o app
/// está rodando, nunca de qual loja o usuário pode ter usado no passado.
const String _urlAssinaturasGooglePlay =
    'https://play.google.com/store/account/subscriptions';
const String _urlAssinaturasAppleStore = 'https://apps.apple.com/account/subscriptions';

/// Tela "Excluir Conta e Dados" (Configurações > Minha Conta), em
/// conformidade com as regras de exclusão de conta da Google Play Store e
/// da Apple App Store: explica de forma clara e definitiva o que será
/// apagado, exige confirmação dupla (diálogo "tem certeza?" + PIN de
/// segurança, mesmo padrão usado em toda ação sensível do Guardião X — ver
/// `pin_dialog.dart`) e só então aciona a exclusão real via
/// [ExclusaoContaService].
class ExcluirContaScreen extends StatefulWidget {
  const ExcluirContaScreen({super.key});

  @override
  State<ExcluirContaScreen> createState() => _ExcluirContaScreenState();
}

class _ExcluirContaScreenState extends State<ExcluirContaScreen> {
  bool _excluindo = false;

  /// Abre o painel nativo de assinaturas da loja correta para a
  /// plataforma atual — atalho direto para o usuário cancelar a
  /// renovação automática do Plano Premium ANTES (ou independentemente)
  /// de excluir a conta em si, já que a RMF Global não tem nenhum meio
  /// de cancelar isso por conta própria (ver `excluirContaAvisoAssinatura`
  /// e a documentação completa em `functions/exclusaoContaService.js`).
  /// Falha (app da loja não instalado, sem navegador, etc.) é só
  /// registrada em log — nunca interrompe o restante da tela.
  Future<void> _abrirAssinaturaNaLoja() async {
    final url = Platform.isIOS ? _urlAssinaturasAppleStore : _urlAssinaturasGooglePlay;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('⚠️ [ExcluirContaScreen] Falha ao abrir assinaturas da loja: $e');
    }
  }

  Future<void> _iniciarExclusao() async {
    final l10n = AppLocalizations.of(context)!;

    final config = await DatabaseHelper().getUserConfig();
    final pinReal = config?['pin_real'] as String?;
    final possuiPinAtivo = pinReal != null && pinReal.trim().isNotEmpty;

    if (!mounted) return;

    if (!possuiPinAtivo) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.excluirContaSemPinTitulo),
          content: Text(l10n.excluirContaSemPinConteudo),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.fechar),
            ),
          ],
        ),
      );
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.excluirContaDialogTitulo),
        content: Text(l10n.excluirContaDialogConteudo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.excluir),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;

    await exibirDialogoPin(
      context: context,
      pinEsperado: pinReal,
      aoConfirmarPinCorreto: _executarExclusao,
      mostrarBotaoCancelar: true,
    );
  }

  Future<void> _executarExclusao() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _excluindo = true);

    final resultado = await ExclusaoContaService().excluirContaCompleta();

    if (resultado == ResultadoExclusaoConta.sucesso) {
      appNavigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = appNavigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(
              content: Text(l10n.excluirContaSucessoMensagem),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.green,
            ),
          );
        }
      });
      return;
    }

    if (!mounted) return;
    setState(() => _excluindo = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.excluirContaErroMensagem),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.excluirContaTitulo)),
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.delete_forever_rounded,
                        color: Colors.red.shade700, size: 42),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.excluirContaAvisoPrincipal,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.gavel_outlined, color: Colors.grey.shade700, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.excluirContaAvisoRescisaoContrato,
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade800, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange.shade800, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.excluirContaAvisoAssinatura,
                          style: TextStyle(
                              fontSize: 13, color: Colors.orange.shade900, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange.shade900,
                      side: BorderSide(color: Colors.orange.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(l10n.excluirContaBotaoGerenciarAssinatura),
                    onPressed: _abrirAssinaturaNaLoja,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.excluirContaListaTitulo,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 10),
                _itemLista(l10n.excluirContaItemConta),
                _itemLista(l10n.excluirContaItemContatos),
                _itemLista(l10n.excluirContaItemHistorico),
                _itemLista(l10n.excluirContaItemMonitoramento),
              ],
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: _excluindo
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.delete_forever_rounded),
                  label: Text(
                    _excluindo ? l10n.excluirContaProcessando : l10n.excluirContaBotaoExcluir,
                  ),
                  onPressed: _excluindo ? null : _iniciarExclusao,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemLista(String texto) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.close_rounded, color: Colors.red.shade400, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(texto, style: const TextStyle(fontSize: 14, height: 1.3)),
          ),
        ],
      ),
    );
  }
}
