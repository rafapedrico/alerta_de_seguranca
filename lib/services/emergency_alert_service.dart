import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Executa o fluxo de ALERTA DE TENTATIVA DE DESARME COM SENHA INCORRETA,
  /// disparado quando o usuário (ou um possível invasor) falha ao
  /// desarmar antecipadamente o cronômetro de segurança ou um alarme de
  /// rotina (ver [PinDialogContent.aoAtingirLimiteDeErros] em
  /// `widgets/pin_dialog.dart`) — seja por errar o PIN um determinado
  /// número de vezes, seja por deixar uma janela de tempo esgotar sem
  /// confirmação.
  ///
  /// [motivo] descreve exatamente o que aconteceu e é inserido na
  /// mensagem enviada; por padrão descreve o cenário histórico ("PIN
  /// incorreto 2 vezes seguidas"), mas chamadores com um cenário
  /// diferente (ex: apenas 1 PIN incorreto na janela final do alarme de
  /// rotina, ou o prazo de 2 minutos esgotado sem nenhuma tentativa)
  /// DEVEM informar um texto preciso — nunca reutilize o padrão para um
  /// cenário que ele não descreve corretamente, já que os contatos de
  /// emergência usam essa mensagem para decidir como reagir.
  ///
  /// Diferente de [dispararAlertaDeEmergencia] (mensagem genérica de
  /// check-in perdido), esta mensagem é explícita sobre o que ocorreu,
  /// avisando os contatos de emergência cadastrados de que houve uma
  /// tentativa de desarme com senha incorreta, incluindo a localização
  /// atual (mesma estratégia de fallback em camadas: posição em memória ->
  /// última conhecida -> nova leitura do GPS -> aviso de GPS
  /// desativado/indisponível).
  ///
  /// Reaproveita o mesmo limite mensal de alertas do Plano Gratuito e o
  /// mesmo canal nativo de SMS usado pelos demais fluxos de emergência, e é
  /// protegido por try/catch em cada etapa para nunca travar o diálogo de
  /// PIN que disparou este alerta, mesmo em caso de falha (GPS, SMS, banco).
  ///
  /// [eventoId], quando informado, é a MESMA trava contra mensagens
  /// duplicadas usada em
  /// [FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto], só
  /// que no nível LOCAL/dispositivo: como o mesmo evento (ex: janela
  /// final do alarme de rotina #N) pode ser detectado por dois caminhos
  /// concorrentes (diálogo de PIN em primeiro plano vs. callback
  /// headless), uma flag em disco garante que o SMS nativo só seja
  /// enviado UMA vez por [eventoId], mesmo que ambos os caminhos cheguem
  /// a chamar este método.
  Future<void> dispararAlertaTentativaDesarmeIncorreto({
    Position? posicaoEmMemoria,
    String? motivo,
    String? eventoId,
  }) async {
    final String motivoTexto = motivo ??
        'O PIN foi digitado incorretamente 2 vezes seguidas ao tentar '
            'desarmar antecipadamente o sistema de segurança.';

    debugPrint('🚨 [TENTATIVA DE DESARME INCORRETA] $motivoTexto');

    // TRAVA CONTRA MENSAGENS DUPLICADAS (nível local): ver documentação
    // do parâmetro [eventoId] acima. Sem [eventoId] (demais fluxos de
    // emergência sem risco de disparo duplo), este bloco é ignorado —
    // comportamento 100% inalterado.
    if (eventoId != null && eventoId.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final chaveTrava = 'sms_enviado_$eventoId';
        if (prefs.getBool(chaveTrava) == true) {
          debugPrint(
              '🚫 [TENTATIVA DE DESARME INCORRETA] Evento #$eventoId já '
              'processado por outro caminho — SMS não reenviado.');
          return;
        }
        await prefs.setBool(chaveTrava, true);
      } catch (e) {
        debugPrint(
            '⚠️ [TENTATIVA DE DESARME INCORRETA] Falha ao checar trava local '
            'de duplicidade (evento #$eventoId): $e');
      }
    }

    // Regra de negócio (Plano Gratuito): mesmo limite mensal de 5 alertas
    // se aplica aqui, evitando que tentativas repetidas de PIN incorreto
    // esgotem a cota de SMS do usuário.
    final bool podeDisparar = await PlanoLimiteService().podeDispararAlerta();
    if (!podeDisparar) {
      debugPrint(
          '🚫 [TENTATIVA DE DESARME INCORRETA] Limite mensal de alertas do '
          'Plano Gratuito atingido — disparo cancelado.');
      return;
    }
    await PlanoLimiteService().incrementarAlertaUsado();

    List<Map<String, dynamic>> contatosEmergencia = [];
    try {
      contatosEmergencia = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [TENTATIVA DE DESARME INCORRETA] Falha ao buscar '
          'contatos de emergência: $e');
    }

    final localizacaoFormatada =
        await _obterLocalizacaoFormatada(posicaoEmMemoria: posicaoEmMemoria);

    final mensagemAlerta =
        '⚠️ ALERTA DE SEGURANÇA: TENTATIVA DE DESARME COM SENHA INCORRETA!\n'
        '$motivoTexto\n'
        'Localização: $localizacaoFormatada';

    debugPrint('📋 [TENTATIVA DE DESARME INCORRETA] Mensagem enviada via '
        'SMS: $mensagemAlerta');

    try {
      await _db.inserirEventoHistorico(
        titulo: 'Tentativa de desarme com PIN incorreto',
        descricao: '$motivoTexto Alerta enviado aos contatos de emergência. '
            'Localização: $localizacaoFormatada',
        categoria: 'critico',
      );
    } catch (e) {
      debugPrint('⚠️ [TENTATIVA DE DESARME INCORRETA] Falha ao registrar '
          'evento no histórico: $e');
    }

    // Dispara (fire-and-forget) o alerta também para o backend FastAPI, em
    // paralelo ao SMS nativo abaixo.
    _obterPosicaoBruta(posicaoEmMemoria: posicaoEmMemoria).then((posicao) {
      if (posicao != null) {
        ApiService().dispararAlertaWeb(
          latitude: posicao.latitude,
          longitude: posicao.longitude,
          contexto: motivoTexto,
          timestampLocal: DateTime.now(),
        );
      } else {
        debugPrint('⚠️ [TENTATIVA DE DESARME INCORRETA] Localização '
            'indisponível: alerta web não enviado (SMS nativo prossegue '
            'normalmente).');
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

  /// Canal SMS OFICIAL do P1 da sequência unificada de SOS (ver
  /// [SosDisparoService.executarP1LocalizacaoImediata]) — enviado SEMPRE,
  /// em paralelo aos canais de nuvem (Push/WhatsApp) quando há sessão
  /// autenticada, e como ÚNICO canal quando não há (cold-start via
  /// lockscreen, ver política "Opção A" de `FirebaseAuthService`). Este
  /// método NUNCA é chamado diretamente por `main.dart`/
  /// `seguranca_tab.dart`, só por [SosDisparoService].
  ///
  /// IMPORTANTE: a checagem/incremento do limite mensal de alertas do
  /// Plano Gratuito é feita UMA ÚNICA VEZ pelo chamador
  /// ([SosDisparoService]), nunca aqui — evita contar o mesmo SOS duas
  /// vezes (uma para o canal SMS, outra para o canal de nuvem).
  ///
  /// Otimizado para GANHAR TEMPO em uma emergência real, com uma
  /// estratégia de DUPLA localização:
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
    debugPrint('🚨 [SOS] Canal SMS oficial acionado — disparando com dupla localização.');

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
/// FALLBACK de contingência (SMS de texto, SEM a foto em si) usado por
  /// [SosDisparoService.dispararFotoCapturada] exclusivamente quando não
  /// há sessão do Firebase Auth disponível — mesma regra de
  /// [dispararSosComDuplaLocalizacao]. Com sessão, a foto é enviada de
  /// verdade via Firebase Storage + Push/WhatsApp.
  Future<void> enviarSmsResgateFoto({
    required String login,
    required String senha,
    String? urlNovem,
  }) async {
    List<Map<String, dynamic>> contatos = [];
    try {
      contatos = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [SMS RESGATE] Falha ao carregar contatos: $e');
    }

    if (contatos.isEmpty) {
      debugPrint('⚠️ [SMS RESGATE] Nenhum contato cadastrado para receber as credenciais.');
      return;
    }

    final String link = urlNovem ?? 'https://seu-painel-nuvem.com/login';

    final String mensagemResgate =
        '🚨 EVIDÊNCIA FOTOGRÁFICA REGISTRADA!\n'
        'Fotos e localização enviadas para a nuvem.\n'
        'Acesso: $link\n'
        'Login: $login\n'
        'Senha: $senha\n'
        'Operação irreversível.';

    debugPrint('📋 [SMS RESGATE] Enviando credenciais de resgate para contatos...');
    await _enviarSms(contatos, mensagemResgate);

    try {
      await _db.inserirEventoHistorico(
        titulo: 'Evidência fotográfica registrada',
        descricao: 'SMS com dados de resgate enviado para os contatos de emergência.',
        categoria: 'critico',
      );
    } catch (_) {}
  }

  /// Canal SMS OFICIAL do P2 da sequência unificada de SOS (ver
  /// [SosDisparoService.dispararFotoCapturada]) — enviado SEMPRE, em
  /// paralelo aos canais de nuvem (Push/WhatsApp), com o link real da
  /// foto ([fotoUrl], já enviada ao Firebase Storage) e a localização
  /// atual, exatamente como pedido pelo produto: "texto com a
  /// localização + link da foto do Storage". Diferente de
  /// [enviarSmsResgateFoto] (mensagem antiga com credenciais fictícias,
  /// mantida só como fallback para quando NENHUM link real está
  /// disponível — sem sessão ou falha no upload).
  Future<void> enviarSmsComLinkDaFoto(String fotoUrl) async {
    List<Map<String, dynamic>> contatos = [];
    try {
      contatos = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [SMS Foto] Falha ao carregar contatos: $e');
    }

    final Position? posicao = await _obterPosicaoDeCacheImediata();
    final String localizacaoFormatada = posicao != null
        ? _formatarPosicao(posicao)
        : 'Localização indisponível no momento do envio.';

    final String mensagem =
        '📷 EVIDÊNCIA FOTOGRÁFICA registrada durante o SOS!\n'
        'Foto: $fotoUrl\n'
        'Localização: $localizacaoFormatada';

    debugPrint('📋 [SMS Foto] Enviando localização + link da foto para contatos...');
    await _enviarSms(contatos, mensagem);

    try {
      await _db.inserirEventoHistorico(
        titulo: 'Foto do SOS enviada por SMS',
        descricao: 'SMS com o link da foto e a localização enviado para os '
            'contatos de emergência. Foto: $fotoUrl',
        categoria: 'critico',
      );
    } catch (_) {}
  }
}
