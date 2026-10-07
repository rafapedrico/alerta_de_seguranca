import 'dart:async';

import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/bloqueio_app_service.dart';
import '../services/sos_disparo_service.dart';
import 'camera_captura_screen.dart';

/// Primeira tela do SOS (botão do app e botão físico): fundo preto, letras
/// vermelhas — igual ao app iOS. A localização já está sendo enviada
/// quando esta tela abre (ver [SosDisparoService.iniciar]); aqui só são
/// mostrados avisos VERDADEIROS, nesta ordem:
///
/// 1. "Alerta acionado. Enviando sua localização…" (no toque);
/// 2. confirmado (push ou SMS): "Localização enviada com sucesso" por 2 s;
///    sem confirmação em 8 s: "Sem conexão. Seu alerta será enviado
///    automaticamente assim que houver sinal" por 2 s; sem contatos: o
///    aviso de que nada foi enviado;
/// 3. "Abrindo a câmera" — e só então a câmera ([CameraCapturaScreen]).
class SosEmAndamentoScreen extends StatefulWidget {
  const SosEmAndamentoScreen({super.key, required this.sessao});

  final SessaoSos sessao;

  @override
  State<SosEmAndamentoScreen> createState() => _SosEmAndamentoScreenState();
}

enum _FaseSos { enviando, enviada, semConexao, semContatos, abrindoCamera }

// Emergência: funciona sem desbloquear o app (ver BloqueioAppService).
class _SosEmAndamentoScreenState extends State<SosEmAndamentoScreen>
    with LiberaBloqueioEnquantoAberta<SosEmAndamentoScreen> {
  /// Sem confirmação do push nem do SMS neste prazo: aviso de sem conexão.
  static const Duration _limiteConfirmacao = Duration(seconds: 8);

  /// Tempo do aviso de resultado (nunca mais de 3 s).
  static const Duration _tempoAviso = Duration(seconds: 2);

  _FaseSos _fase = _FaseSos.enviando;

  @override
  void initState() {
    super.initState();
    unawaited(_conduzir());
  }

  Future<void> _conduzir() async {
    final sessao = widget.sessao;
    bool confirmado = false;
    try {
      confirmado = await sessao.confirmacao.future.timeout(_limiteConfirmacao);
    } on TimeoutException {
      confirmado = false;
    }
    if (!mounted) return;
    setState(() {
      _fase = sessao.semContatos
          ? _FaseSos.semContatos
          : (confirmado ? _FaseSos.enviada : _FaseSos.semConexao);
    });
    await Future.delayed(sessao.semContatos ? const Duration(seconds: 3) : _tempoAviso);
    if (!mounted) return;
    setState(() => _fase = _FaseSos.abrindoCamera);
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraCapturaScreen(sessao: sessao),
        fullscreenDialog: true,
      ),
    );
  }

  String _texto(AppLocalizations l10n) {
    switch (_fase) {
      case _FaseSos.enviando:
        return l10n.sosEnviandoLocalizacao;
      case _FaseSos.enviada:
        return l10n.sosLocalizacaoEnviada;
      case _FaseSos.semConexao:
        return l10n.sosSemConexao;
      case _FaseSos.semContatos:
        return l10n.sosSemContatos;
      case _FaseSos.abrindoCamera:
        return l10n.sosAbrindoCamera;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_fase == _FaseSos.enviando || _fase == _FaseSos.abrindoCamera)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 28),
                      child: CircularProgressIndicator(color: Colors.redAccent),
                    ),
                  Text(
                    _texto(l10n),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
