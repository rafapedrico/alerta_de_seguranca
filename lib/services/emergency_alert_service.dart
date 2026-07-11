import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'database_helper.dart';
import 'api_service.dart';
import 'plano_limite_service.dart';


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

  /// Retorna SOMENTE a última posição conhecida em cache pelo sistema
  /// (sem nunca consultar o GPS em tempo real), usada exclusivamente
  /// pela ETAPA 1 (disparo imediato) do fluxo de SOS via botão físico de
  /// Volume+ (ver [dispararSosComDuplaLocalizacao]), onde ganhar tempo é
  /// mais importante do que precisão. Nunca lança exceção: retorna
  /// `null` se não houver nenhuma posição em cache.
  Future<Position?> _obterPosicaoDeCacheImediata() async {
    try {
      return await Geolocator.getLastKnownPosition();
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
    // Regra de negócio (Plano Gratuito): no máximo 5 alertas de
    // emergência por mês. Verificado ANTES de qualquer outra etapa do
    // disparo — se o limite já tiver sido atingido, o fluxo é
    // interrompido silenciosamente aqui (sem lançar exceção nem afetar a
    // UI que chamou este método).
    final bool podeDisparar = await PlanoLimiteService().podeDispararAlerta();
    if (!podeDisparar) {
      debugPrint(
          '🚫 [EmergencyAlertService] Limite mensal de alertas do Plano Gratuito atingido — disparo cancelado.');
      return;
    }
    await PlanoLimiteService().incrementarAlertaUsado();

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
          timestampLocal: DateTime.now(),
        );
      } else {

        debugPrint(
            '⚠️ [EmergencyAlertService] Localização indisponível: alerta web não enviado (SMS nativo prossegue normalmente).');
      }
    });

    await _enviarSms(contatosEmergencia, mensagemAlerta);
  }

  /// Envia o SMS de emergência para os [contatosEmergencia] informados,
  /// com a [mensagem] já pronta. Extraído para ser reaproveitado tanto
  /// pelo fluxo tradicional ([dispararAlertaDeEmergencia]) quanto pela
  /// dupla etapa do fluxo de SOS via botão físico
  /// ([dispararSosComDuplaLocalizacao]).
  Future<void> _enviarSms(
    List<Map<String, dynamic>> contatosEmergencia,
    String mensagem,
  ) async {
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
        'mensagem': mensagem,
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
    } catch (e) {
      // Qualquer outro erro inesperado durante a chamada nativa também é
      // tratado da mesma forma: registrado e o fluxo é interrompido,
      // nunca repetido automaticamente.
      debugPrint('⚠️ Falha ao enviar SMS de emergência: $e');
    }
  }

  /// Fluxo de disparo de SOS ESPECÍFICO do gatilho físico (segurar
  /// Volume+ por 3 segundos), otimizado para GANHAR TEMPO em uma
  /// emergência real, com uma estratégia de DUPLA localização:
  ///
  /// ETAPA 1 (imediata, sem qualquer espera pelo GPS): monta e envia o
  /// SMS + alerta web IMEDIATAMENTE usando apenas a última localização
  /// em CACHE do aparelho ([Geolocator.getLastKnownPosition]), que
  /// retorna instantaneamente (sem acionar o hardware do GPS).
  ///
  /// ETAPA 2 (em paralelo/logo em seguida, fire-and-forget): inicia uma
  /// nova busca de localização em tempo real (GPS ligado, alta
  /// precisão) e, assim que finalizar, reenvia um SEGUNDO SMS +
  /// segundo POST para `/api/alerta` com as coordenadas atualizadas —
  /// sem bloquear ou atrasar a Etapa 1.
  ///
  /// Como o gatilho físico não tem acesso a nenhum
  /// TextEditingController/contexto de UI, [contexto] é sempre lido do
  /// SQLite ('contexto_timer_ativo'), com fallback para uma mensagem
  /// padrão caso não exista nada salvo.
  Future<void> dispararSosComDuplaLocalizacao() async {
    debugPrint('🚨 [SOS FÍSICO] Gatilho de Volume+ detectado! Disparando com dupla localização.');

    // Regra de negócio (Plano Gratuito): mesmo limite mensal de 5
    // alertas se aplica ao gatilho físico de SOS. Verificado antes de
    // qualquer etapa do disparo.
    final bool podeDisparar = await PlanoLimiteService().podeDispararAlerta();
    if (!podeDisparar) {
      debugPrint(
          '🚫 [SOS FÍSICO] Limite mensal de alertas do Plano Gratuito atingido — disparo cancelado.');
      return;
    }
    await PlanoLimiteService().incrementarAlertaUsado();

    String anotacoesUsuario = '';

    try {
      final config = await _db.getUserConfig();
      anotacoesUsuario =
          (config?['contexto_timer_ativo'] as String?)?.trim() ?? '';
    } catch (_) {}
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = 'SOS disparado via botão físico de emergência (Volume+).';
    }

    List<Map<String, dynamic>> contatosEmergencia = [];
    try {
      contatosEmergencia = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [SOS FÍSICO] Falha ao buscar contatos de emergência: $e');
    }

    // ===================== ETAPA 1: DISPARO IMEDIATO =====================
    final Position? posicaoCache = await _obterPosicaoDeCacheImediata();
    final String localizacaoCacheFormatada = posicaoCache != null
        ? _formatarPosicao(posicaoCache)
        : 'Localização em cache indisponível — aguardando atualização em tempo real.';

    final mensagemImediata =
        '🚨 SOS DE EMERGÊNCIA (botão físico)!\n'
        'Localização (última conhecida): $localizacaoCacheFormatada\n'
        'Contexto: $anotacoesUsuario\n'
        '(Uma atualização com a localização em tempo real será enviada em seguida.)';

    debugPrint('📋 [SOS FÍSICO] Etapa 1 (cache imediato): $mensagemImediata');

    try {
      await _db.inserirEventoHistorico(
        titulo: 'SOS via botão físico disparado (localização em cache)',
        descricao: 'SMS de emergência imediato enviado com a última localização '
            'conhecida em cache. Localização: $localizacaoCacheFormatada',
        categoria: 'critico',
      );
    } catch (e) {
      debugPrint('⚠️ [SOS FÍSICO] Falha ao registrar evento no histórico (etapa 1): $e');
    }

    if (posicaoCache != null) {
      // Fire-and-forget: não bloqueia a etapa 1 nem a etapa 2 seguinte.
      ApiService().dispararAlertaWeb(
        latitude: posicaoCache.latitude,
        longitude: posicaoCache.longitude,
        contexto: '$anotacoesUsuario (localização em cache)',
        timestampLocal: DateTime.now(),
      );
    }


    await _enviarSms(contatosEmergencia, mensagemImediata);

    // ================ ETAPA 2: ATUALIZAÇÃO EM TEMPO REAL ================
    // Executada em seguida (não aguardada pelo chamador original, mas
    // aguardada aqui dentro do próprio método para garantir que o
    // fluxo completo — incluindo a atualização — sempre seja concluído
    // mesmo que o método seja chamado de forma fire-and-forget).
    try {
      final posicaoAtualizada = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      final localizacaoAtualizadaFormatada = _formatarPosicao(posicaoAtualizada);
      final mensagemAtualizada =
          '🚨 SOS DE EMERGÊNCIA (atualização em tempo real)!\n'
          'Localização atualizada: $localizacaoAtualizadaFormatada\n'
          'Contexto: $anotacoesUsuario';

      debugPrint('📋 [SOS FÍSICO] Etapa 2 (tempo real): $mensagemAtualizada');

      try {
        await _db.inserirEventoHistorico(
          titulo: 'SOS via botão físico — localização atualizada',
          descricao: 'Segundo SMS de emergência enviado com a localização em '
              'tempo real. Localização: $localizacaoAtualizadaFormatada',
          categoria: 'critico',
        );
      } catch (e) {
        debugPrint('⚠️ [SOS FÍSICO] Falha ao registrar evento no histórico (etapa 2): $e');
      }

      ApiService().dispararAlertaWeb(
        latitude: posicaoAtualizada.latitude,
        longitude: posicaoAtualizada.longitude,
        contexto: '$anotacoesUsuario (localização atualizada)',
        timestampLocal: DateTime.now(),
      );


      await _enviarSms(contatosEmergencia, mensagemAtualizada);
    } catch (e) {
      debugPrint(
          '⚠️ [SOS FÍSICO] Falha ao obter localização em tempo real para a etapa 2 '
          '(o SMS/alerta imediato da etapa 1 já foi enviado normalmente): $e');
    }
  }
}
