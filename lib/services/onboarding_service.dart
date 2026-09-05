import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'battery_optimization_service.dart';
import 'notificacao_service.dart';

/// Status exibido por cada item do [OnboardingScreen] — mais granular que
/// um simples `bool` para distinguir "localização concedida só durante o
/// uso" (funcional, mas não o ideal) de "concedida sempre" (o pedido real)
/// sem precisar de um enum próprio por item.
enum StatusPermissaoOnboarding {
  concedida,
  parcial,
  pendente,
}

/// Centraliza a checagem/solicitação das permissões do Assistente de
/// Configuração Inicial (`OnboardingScreen`), exibido uma única vez, logo
/// após o primeiro login bem-sucedido nesta instalação (ver
/// `LoginScreen._finalizarLoginComSucesso`) — reespecificação do usuário,
/// 2026-08-16: padronizar essas permissões via um fluxo GUIADO, em vez de
/// depender só dos pontos de solicitação espalhados/reativos já existentes
/// no app (ex: [BatteryOptimizationService]/`SmsPermissionService`, cada um
/// perguntando em separado na primeira vez que é relevante).
///
/// NÃO substitui esses pontos espalhados — cada um já se autoprotege
/// checando se a permissão já foi concedida antes de perguntar de novo, e
/// continuam funcionando como rede de segurança para quem pulou/negou aqui.
/// Câmera/SMS continuam sendo pedidas nos momentos de uso real também
/// (ver `CapturaDissuasaoService`/`SmsPermissionService`), redundância
/// deliberada.
///
/// PROPOSITALMENTE NÃO inclui um item de "Serviço de Acessibilidade": o
/// botão físico de SOS já funciona hoje sem AccessibilityService (ver
/// `VolumeSosService.kt` — ContentObserver + BroadcastReceiver nativos).
/// Criar um AccessibilityService só para esse fim é tratado pela Google
/// Play Store como uso indevido da API de Acessibilidade (destinada a
/// apps de assistência a pessoas com deficiência) — risco real de rejeição/
/// remoção da loja, decisão confirmada com o usuário (2026-08-16).
class OnboardingService {
  OnboardingService._internal();
  static final OnboardingService _instance = OnboardingService._internal();
  factory OnboardingService() => _instance;

  static const String _chaveOnboardingConcluido =
      'onboarding_configuracao_concluido_v1';

  /// `true` assim que o usuário concluiu (ou pulou) o Assistente de
  /// Configuração Inicial nesta instalação — `OnboardingScreen` só é
  /// exibida de novo, num próximo login, se isto continuar `false` (ver
  /// [marcarConcluido], só chamado quando as permissões ESSENCIAIS —
  /// notificações + localização — estiverem concedidas).
  Future<bool> jaConcluido() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_chaveOnboardingConcluido) ?? false;
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao ler flag de conclusão: $e');
      // Na dúvida, prefere mostrar o Assistente de novo (pior caso: uma
      // tela a mais) a arriscar nunca mostrar pra quem realmente precisa.
      return false;
    }
  }

  Future<void> marcarConcluido() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chaveOnboardingConcluido, true);
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao gravar flag de conclusão: $e');
    }
  }

  // ================================================================
  // BATERIA (recomendada) — reaproveita [BatteryOptimizationService]
  // ================================================================

  Future<StatusPermissaoOnboarding> statusBateria() async {
    final isento = await BatteryOptimizationService().estaIsento();
    return isento ? StatusPermissaoOnboarding.concedida : StatusPermissaoOnboarding.pendente;
  }

  /// Solicita DIRETO (sem o diálogo de explicação extra de
  /// [BatteryOptimizationService.solicitarComExplicacao] — o próprio card
  /// do Assistente já cumpre esse papel de dar contexto antes do prompt
  /// nativo).
  Future<void> solicitarBateria() async {
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao solicitar isenção de bateria: $e');
    }
  }

  // ================================================================
  // NOTIFICAÇÕES + ALARMES (essencial)
  // ================================================================

  /// `true` só quando POST_NOTIFICATIONS E a permissão de alarmes exatos
  /// estiverem concedidas — um único item na UI (reespecificação do
  /// usuário: "notificações... e alarmes" é um item só), mas duas
  /// permissões distintas por trás.
  Future<StatusPermissaoOnboarding> statusNotificacoes() async {
    final notificacoesOk = (await Permission.notification.status).isGranted;
    final alarmesOk = await NotificacaoService.podeAgendarAlarmesExatos();
    if (notificacoesOk && alarmesOk) return StatusPermissaoOnboarding.concedida;
    if (notificacoesOk || alarmesOk) return StatusPermissaoOnboarding.parcial;
    return StatusPermissaoOnboarding.pendente;
  }

  Future<void> solicitarNotificacoes() async {
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao solicitar permissão de notificação: $e');
    }
    // Sequencial de propósito (nunca em paralelo): a permissão de alarmes
    // exatos abre uma tela NATIVA separada (Configurações) — pedir as duas
    // ao mesmo tempo arriscaria uma sobrepor a outra.
    await NotificacaoService.solicitarAlarmesExatos();
  }

  // ================================================================
  // LOCALIZAÇÃO SEMPRE ATIVA (essencial)
  // ================================================================

  /// CORREÇÃO DE BUG REAL (2026-09-05, pedido explícito do usuário —
  /// "aparece como pendente mesmo já concedida no sistema"): antes, este
  /// método consultava `Geolocator.checkPermission()` — a ÚNICA checagem
  /// de permissão desta classe que não passa pelo `permission_handler`
  /// (todos os outros itens — bateria, notificação, câmera — usam
  /// `Permission.xxx.status`, ver acima/abaixo). Em alguns fabricantes/
  /// versões de Android (confirmado: Motorola, Android 16), o plugin
  /// `geolocator` pode devolver `LocationPermission.unableToDetermine`
  /// mesmo com a permissão JÁ concedida de verdade no sistema — um "não
  /// sei dizer" que o código anterior tratava, por omissão (nenhum branch
  /// cobria esse valor), como [StatusPermissaoOnboarding.pendente] — o
  /// PIOR estado possível, escondendo uma permissão real já concedida.
  /// Agora usa `permission_handler`, que lê o status direto do SO Android
  /// sem essa ambiguidade — mesmo pacote/padrão já usado sem problema por
  /// todo o resto desta classe.
  Future<StatusPermissaoOnboarding> statusLocalizacao() async {
    final sempre = await Permission.locationAlways.status;
    if (sempre.isGranted) return StatusPermissaoOnboarding.concedida;
    final duranteUso = await Permission.location.status;
    if (duranteUso.isGranted) return StatusPermissaoOnboarding.parcial;
    return StatusPermissaoOnboarding.pendente;
  }

  /// `true` se a localização estiver concedida em QUALQUER grau (ao menos
  /// "durante o uso") — usada para decidir se [_essenciaisConcedidas]
  /// (ver [OnboardingScreen]) bloqueia a conclusão: "sempre" é o ideal
  /// (pedido explícito do usuário), mas "durante o uso" já permite o botão
  /// de pânico manual funcionar — só o heartbeat de segundo plano depende
  /// de verdade de "sempre". Mesma correção de [statusLocalizacao] acima
  /// (via `permission_handler`, não `geolocator`) e pelo mesmo motivo.
  Future<bool> localizacaoAoMenosConcedida() async {
    final duranteUso = await Permission.location.status;
    return duranteUso.isGranted;
  }

  /// O Android, desde a versão 11, NÃO permite pedir "Permitir o tempo
  /// todo" diretamente num único diálogo — a PRIMEIRA solicitação só pode
  /// oferecer "Durante o uso do app"/"Só desta vez"/"Não permitir";
  /// "sempre" só pode ser concedida depois, manualmente, em Configurações
  /// (ou, em alguns casos/versões, numa segunda chamada de
  /// `requestPermission()` já com a primeira concedida — tentada aqui,
  /// mas sem garantia). Por isso [OnboardingScreen] mostra um botão
  /// "Abrir Configurações" como PRÓXIMO passo sempre que o status ainda
  /// não for [StatusPermissaoOnboarding.concedida] depois desta chamada.
  Future<void> solicitarLocalizacao() async {
    try {
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.denied) {
        status = await Geolocator.requestPermission();
      }
      if (status == LocationPermission.whileInUse) {
        // Tentativa best-effort de "upgrade" direto para "sempre" — o
        // Android permite isso numa segunda chamada em ALGUMAS versões/
        // fabricantes; se não permitir, simplesmente devolve o mesmo
        // status "durante o uso" de novo, sem erro.
        await Geolocator.requestPermission();
      }
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao solicitar permissão de localização: $e');
    }
  }

  // ================================================================
  // CÂMERA (recomendada)
  // ================================================================

  Future<StatusPermissaoOnboarding> statusCamera() async {
    final concedida = (await Permission.camera.status).isGranted;
    return concedida ? StatusPermissaoOnboarding.concedida : StatusPermissaoOnboarding.pendente;
  }

  Future<void> solicitarCamera() async {
    try {
      await Permission.camera.request();
    } catch (e) {
      debugPrint('⚠️ [OnboardingService] Falha ao solicitar permissão de câmera: $e');
    }
  }

  // ================================================================
  // ALERTAS EM TELA CHEIA (recomendada)
  // ================================================================

  /// CORREÇÃO DE BUG REAL (2026-08-16): antes, este item nunca era
  /// checado ao abrir a tela (só reagia ao toque em "Conceder", sem
  /// persistir nada) — agora reaproveita
  /// [NotificacaoService.podeUsarTelaCheia], que consulta a API nativa do
  /// Android diretamente e de forma 100% silenciosa, mantendo o status
  /// real ao reabrir a tela ou reiniciar o app (mesmo padrão dos demais
  /// itens desta classe).
  Future<StatusPermissaoOnboarding> statusTelaCheia() async {
    final concedida = await NotificacaoService.podeUsarTelaCheia();
    return concedida ? StatusPermissaoOnboarding.concedida : StatusPermissaoOnboarding.pendente;
  }

  Future<bool> solicitarTelaCheia() => NotificacaoService.solicitarPermissaoTelaCheia();
}
