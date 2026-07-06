import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'database_helper.dart';
import 'api_service.dart';

/// Serviço isolado responsável por TODO o fluxo de disparo do alerta de
/// emergência: obtenção da localização GPS mais recente, montagem da
/// mensagem de SMS e chamada ao MethodChannel nativo que efetivamente
/// envia as mensagens via SmsManager do Android.
///
/// Extraído de SegurancaTab para ser 100% reutilizável tanto pela UI
/// (quando o app está aberto) quanto pelo callback estático headless do
/// [AlarmeService] (quando o alarme nativo dispara com o app fechado ou
/// em segundo plano) — por isso NÃO depende de nenhum estado de widget
/// (BuildContext, controllers, etc.), apenas de dados persistidos no
/// SQLite e do próprio GPS do aparelho.
class EmergencyAlertService {
  EmergencyAlertService._internal();
  static final EmergencyAlertService _instance =
      EmergencyAlertService._internal();
  factory EmergencyAlertService() => _instance;

  static const MethodChannel _canalSms =
      MethodChannel('com.example.security_check_app/sms');

  final DatabaseHelper _db = DatabaseHelper();

  /// Formata uma [Position] em texto legível (latitude/longitude + link
  /// do Google Maps) para ser inserida no corpo do SMS.
  String _formatarPosicao(Position posicao) {
    return 'Latitude: ${posicao.latitude}, Longitude: ${posicao.longitude} '
        '(https://maps.google.com/?q=${posicao.latitude},${posicao.longitude})';
  }

  /// Obtém a localização a ser usada no alerta de emergência, com
  /// estratégia de fallback em camadas para nunca deixar o SMS sem
  /// coordenadas:
  /// 1. Última localização conhecida do sistema (cache instantâneo).
  /// 2. Nova consulta ao GPS em tempo real, com timeout curto.
  ///
  /// Diferente do fluxo com o app aberto (que usa o warm-up em memória
  /// do [LocationService]), o callback headless não tem acesso a esse
  /// estado em memória — por isso consulta o GPS diretamente aqui.
  Future<String> _obterLocalizacaoFormatada({Position? posicaoEmMemoria}) async {
    if (posicaoEmMemoria != null) {
      return _formatarPosicao(posicaoEmMemoria);
    }

    Position? ultimaConhecida;
    try {
      ultimaConhecida = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    try {
      final bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida);
        return 'Localização indisponível (serviço de GPS desativado no aparelho).';
      }

      LocationPermission permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida);
        return 'Localização indisponível (permissão de localização negada).';
      }

      try {
        final posicaoAtual = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 7),
        );
        return _formatarPosicao(posicaoAtual);
      } catch (_) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida);
        return 'Não foi possível obter a localização atual do aparelho.';
      }
    } catch (_) {
      if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida);
      return 'Não foi possível obter a localização atual do aparelho.';
    }
  }

  /// Tenta obter uma [Position] "crua" (não formatada) equivalente à
  /// usada no SMS, para ser enviada também ao backend FastAPI em
  /// `/api/alerta`. Reaproveita a mesma estratégia de fallback (posição
  /// em memória -> última conhecida -> nova leitura do GPS), mas nunca
  /// lança exceção: retorna `null` se nenhuma coordenada estiver
  /// disponível por qualquer motivo.
  Future<Position?> _obterPosicaoBruta({Position? posicaoEmMemoria}) async {
    if (posicaoEmMemoria != null) return posicaoEmMemoria;
    try {
      final ultimaConhecida = await Geolocator.getLastKnownPosition();
      if (ultimaConhecida != null) return ultimaConhecida;
    } catch (_) {}
    try {
      final servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) return null;
      LocationPermission permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 7),
      );
    } catch (_) {
      return null;
    }
  }

  /// Executa o fluxo COMPLETO de disparo de emergência:
  /// 1. Busca a dica de contexto informada (ou lê do SQLite se null).
  /// 2. Busca os contatos de emergência cadastrados.
  /// 3. Obtém a localização GPS mais recente disponível.
  /// 4. Monta a mensagem e envia via MethodChannel nativo (SmsManager).
  /// 5. Registra o disparo no histórico (categoria 'critico').
  /// 6. Dispara (fire-and-forget) o mesmo alerta para o backend FastAPI
  ///    (security_backend), via POST /api/alerta, em paralelo ao SMS
  ///    nativo — NUNCA bloqueia nem depende do sucesso dessa chamada.
  ///
  /// [contexto] pode ser informado diretamente (fluxo com app aberto,
  /// vindo do TextEditingController da UI) ou omitido (fluxo headless),
  /// caso em que é lido de 'contexto_timer_ativo' no SQLite.
  /// [posicaoEmMemoria] permite que a UI (com o warm-up do
  /// LocationService já em memória) evite uma nova consulta ao GPS.
  ///
  /// Qualquer falha no envio é apenas registrada via [debugPrint] e
  /// NUNCA propagada, garantindo que o fluxo permaneça 100% silencioso
  /// mesmo em caso de erro (essencial para o disfarce de segurança).
  Future<void> dispararAlertaDeEmergencia({
    String? contexto,
    Position? posicaoEmMemoria,
  }) async {
    String anotacoesUsuario = (contexto ?? '').trim();
    if (anotacoesUsuario.isEmpty) {
      try {
        final config = await _db.getUserConfig();
        anotacoesUsuario =
            (config?['contexto_timer_ativo'] as String?)?.trim() ?? '';
      } catch (_) {}
    }
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = 'Nenhuma anotação de contexto informada pelo usuário.';
    }

    List<Map<String, dynamic>> contatosEmergencia = [];
    try {
      contatosEmergencia = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ Falha ao buscar contatos de emergência: $e');
    }

    final localizacaoFormatada =
        await _obterLocalizacaoFormatada(posicaoEmMemoria: posicaoEmMemoria);

    final mensagemAlerta =
        'ALERTA DE EMERGÊNCIA! Não realizei meu check-in de segurança.\n'
        'Localização: $localizacaoFormatada\n'
        'Contexto: $anotacoesUsuario';

    debugPrint('🚨 DISPARANDO ALERTA MÁXIMO DE EMERGÊNCIA!');
    debugPrint('📋 Mensagem enviada via SMS: $mensagemAlerta');

    try {
      await _db.inserirEventoHistorico(
        titulo: 'Alerta de emergência disparado',
        descricao: 'SMS de emergência enviado para os contatos cadastrados. '
            'Localização: $localizacaoFormatada',
        categoria: 'critico',
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao registrar evento no histórico: $e');
    }

    // Dispara (fire-and-forget) o alerta também para o backend FastAPI,
    // em paralelo ao SMS nativo abaixo. Protegido internamente pelo
    // próprio ApiService (nunca lança exceção nem bloqueia este fluxo).
    _obterPosicaoBruta(posicaoEmMemoria: posicaoEmMemoria).then((posicao) {
      if (posicao != null) {
        ApiService().dispararAlertaWeb(
          latitude: posicao.latitude,
          longitude: posicao.longitude,
          contexto: anotacoesUsuario,
        );
      } else {
        debugPrint(
            '⚠️ [EmergencyAlertService] Localização indisponível: alerta web não enviado (SMS nativo prossegue normalmente).');
      }
    });

    final List<String> numerosDestinatarios = contatosEmergencia
        .map((contato) => (contato['telefone'] as String?) ?? '')
        .where((telefone) => telefone.isNotEmpty)
        .toList();

    if (numerosDestinatarios.isEmpty) {
      debugPrint('⚠️ Nenhum contato de emergência cadastrado para receber o alerta.');
      return;
    }

    try {
      await _canalSms.invokeMethod('enviarSms', {
        'telefones': numerosDestinatarios,
        'mensagem': mensagemAlerta,
      });
    } on MissingPluginException catch (e) {
      // O engine headless criado pelo android_alarm_manager_plus para
      // executar este callback em segundo plano NÃO possui nenhum
      // plugin/MethodChannel customizado registrado nele (apenas o
      // próprio plugin de alarme). Isso é uma limitação conhecida e
      // definitiva do pacote — não há hook para registrar plugins
      // locais nesse engine específico.
      //
      // Por isso, capturamos especificamente essa exceção aqui e NUNCA
      // tentamos novamente em loop: apenas registramos o ocorrido e
      // interrompemos o fluxo com segurança, evitando qualquer
      // travamento/loop infinito no aparelho do usuário.
      debugPrint(
          '⚠️ MissingPluginException: canal de SMS indisponível neste engine '
          '(provavelmente o isolate headless do AlarmManager). Abortando '
          'envio sem repetir. Detalhe: $e');
      return;
    } catch (e) {
      // Qualquer outro erro inesperado durante a chamada nativa também é
      // tratado da mesma forma: registrado e o fluxo é interrompido,
      // nunca repetido automaticamente.
      debugPrint('⚠️ Falha ao enviar SMS de emergência: $e');
      return;
    }
  }
}
