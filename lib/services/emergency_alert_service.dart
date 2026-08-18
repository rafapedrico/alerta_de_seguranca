import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'api_service.dart';
import 'l10n_headless_service.dart';
import 'plano_ciclo_service.dart';
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
  /// do Google Maps) para ser inserida no corpo do SMS e no histórico.
  /// [l10n] resolve "Latitude"/"Longitude" no idioma atualmente
  /// selecionado (ver [L10nHeadlessService]) — nunca mais fixo em
  /// português, já que este texto é persistido no histórico local e
  /// pode ser lido bem depois, mesmo que o idioma do app mude entre o
  /// disparo e a leitura.
  String _formatarPosicao(Position posicao, AppLocalizations l10n) {
    return '${l10n.historicoLatitudeLabel}: ${posicao.latitude}, '
        '${l10n.historicoLongitudeLabel}: ${posicao.longitude} '
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
    final l10n = await L10nHeadlessService.obter();

    if (posicaoEmMemoria != null) {
      return _formatarPosicao(posicaoEmMemoria, l10n);
    }

    Position? ultimaConhecida;
    try {
      ultimaConhecida = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    try {
      final bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida, l10n);
        return l10n.smsLocalizacaoIndisponivelGps;
      }

      LocationPermission permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida, l10n);
        return l10n.smsLocalizacaoIndisponivelPermissao;
      }

      try {
        final posicaoAtual = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 7),
        );
        return _formatarPosicao(posicaoAtual, l10n);
      } catch (_) {
        if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida, l10n);
        return l10n.smsLocalizacaoIndisponivelFalha;
      }
    } catch (_) {
      if (ultimaConhecida != null) return _formatarPosicao(ultimaConhecida, l10n);
      return l10n.smsLocalizacaoIndisponivelFalha;
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

    final l10n = await L10nHeadlessService.obter();

    String anotacoesUsuario = (contexto ?? '').trim();

    if (anotacoesUsuario.isEmpty) {
      try {
        final config = await _db.getUserConfig();
        anotacoesUsuario =
            (config?['contexto_timer_ativo'] as String?)?.trim() ?? '';
      } catch (_) {}
    }
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = l10n.smsContextoNaoInformado;
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
        l10n.smsAlertaEmergenciaCorpo(localizacaoFormatada, anotacoesUsuario);

    debugPrint('🚨 DISPARANDO ALERTA MÁXIMO DE EMERGÊNCIA!');
    debugPrint('📋 Mensagem enviada via SMS: $mensagemAlerta');

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoAlertaEmergenciaTitulo,
        descricao: l10n.historicoAlertaEmergenciaDescricao(localizacaoFormatada),
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
    final l10n = await L10nHeadlessService.obter();
    final String motivoTexto = motivo ?? l10n.smsTentativaDesarmeMotivoPadrao;

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
      debugPrint('👥 [TENTATIVA DE DESARME INCORRETA] ${contatosEmergencia.length} '
          'contato(s) de emergência carregado(s) do SQLite local.');
    } catch (e) {
      debugPrint('⚠️ [TENTATIVA DE DESARME INCORRETA] Falha ao buscar '
          'contatos de emergência: $e');
    }

    debugPrint('📍 [TENTATIVA DE DESARME INCORRETA] Coletando GPS...');
    final localizacaoFormatada =
        await _obterLocalizacaoFormatada(posicaoEmMemoria: posicaoEmMemoria);
    debugPrint('📍 [TENTATIVA DE DESARME INCORRETA] Localização resolvida: '
        '$localizacaoFormatada');

    final mensagemAlerta =
        l10n.smsTentativaDesarmeCorpo(motivoTexto, localizacaoFormatada);

    debugPrint('📋 [TENTATIVA DE DESARME INCORRETA] Mensagem enviada via '
        'SMS: $mensagemAlerta');

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoTentativaDesarmeTitulo,
        descricao: l10n.historicoTentativaDesarmeDescricao(motivoTexto, localizacaoFormatada),
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
    // TRAVA DO CICLO DO PLANO FREE (ver PlanoCicloService): ponto ÚNICO
    // de bloqueio do canal SMS — TODOS os fluxos de emergência deste
    // serviço (SOS físico/manual, tentativa de desarme incorreta, alerta
    // padrão do cronômetro, resgate de foto) passam por aqui. Fora dos 10
    // dias ativos do mês (e sem Premium), o app NÃO dispara SMS
    // automaticamente — regra de negócio explícita do produto. Falha ao
    // determinar o status (sem sessão, sem rede) é tratada como liberado
    // por padrão dentro do próprio PlanoCicloService, nunca aqui.
    if (!await PlanoCicloService().podeUsarRecursosAvancados()) {
      debugPrint('🔒 [SMS] Plano Free fora da janela de 10 dias ativos do mês — '
          'SMS de emergência bloqueado (ver PlanoCicloService).');
      return;
    }

    final List<String> numerosDestinatarios = contatosEmergencia
        .map((contato) => (contato['telefone'] as String?) ?? '')
        .where((telefone) => telefone.isNotEmpty)
        .toList();

    if (numerosDestinatarios.isEmpty) {
      debugPrint('⚠️ [SMS] Nenhum contato de emergência com telefone válido '
          'cadastrado (${contatosEmergencia.length} contato(s) lido(s) do '
          'SQLite, nenhum com telefone preenchido) — SMS NÃO enviado.');
      return;
    }

    // Diagnóstico detalhado pedido pelo usuário (2026-08-15): um log por
    // NÚMERO individual antes do envio — além da contagem agregada, que
    // já existia. `numeroFormatado` é exatamente o que sai do SQLite
    // (já normalizado para E.164 na hora do cadastro, ver
    // `TelefoneUtils.normalizarE164` em `configuracoes_tab.dart`), então
    // este log também serve para confirmar visualmente que a formatação
    // (DDI +55, sem espaços/parênteses/traços) está correta.
    for (final numeroFormatado in numerosDestinatarios) {
      debugPrint('📨 [SMS] Enviando para: $numeroFormatado');
    }
    debugPrint('📨 [SMS] Enviando SMS para ${numerosDestinatarios.length} '
        'contato(s) via MethodChannel nativo...');
    try {
      await _canalSms.invokeMethod('enviarSms', {
        'telefones': numerosDestinatarios,
        'mensagem': mensagem,
      });
      // IMPORTANTE: isto só confirma que `sendMultipartTextMessage` NÃO
      // lançou exceção — ou seja, que o PEDIDO estava bem formado
      // (número/mensagem válidos, SmsManager resolvido). NÃO é
      // confirmação de que o rádio de fato transmitiu o SMS. Essa
      // confirmação REAL chega de forma assíncrona, alguns instantes
      // depois, nos logs nativos `[SMS] Status do envio para ...`
      // (ver `SmsSender.kt`, `adb logcat -s SmsSender`) — só ela prova
      // entrega ao rádio (`RESULT_OK`) ou expõe o motivo exato da falha
      // (`RESULT_ERROR_NO_SERVICE`, `RESULT_ERROR_RADIO_OFF`, etc.).
      debugPrint('📨 [SMS] MethodChannel nativo retornou sem exceção — '
          'pedido enfileirado (ver logs nativos "SmsSender" para a '
          'confirmação REAL de entrega ao rádio).');
    } on MissingPluginException catch (e, s) {
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
          '⚠️ [SMS] MissingPluginException: canal de SMS indisponível neste engine '
          '(provavelmente o isolate headless do AlarmManager). Abortando '
          'envio sem repetir. Detalhe: $e');
      debugPrint('⚠️ [SMS] Stack trace: $s');
    } catch (e, s) {
      // Qualquer outro erro inesperado durante a chamada nativa também é
      // tratado da mesma forma: registrado e o fluxo é interrompido,
      // nunca repetido automaticamente. Cobre também o `result.error(...)`
      // que o lado nativo (SmsSender.kt) devolve quando NENHUM contato foi
      // efetivamente enviado (ex: SmsManager indisponível/sem serviço) —
      // chega aqui como PlatformException.
      debugPrint('⚠️ [SMS] Falha ao enviar SMS de emergência: $e');
      debugPrint('⚠️ [SMS] Stack trace: $s');
    }
  }

  /// Canal SMS OFICIAL do P1 da sequência unificada de SOS (ver
  /// [SosDisparoService.executarP1LocalizacaoImediata]) — enviado SEMPRE,
  /// em paralelo ao canal de nuvem (Push) quando há sessão
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
  /// P1 da sequência unificada de SOS (ver [SosDisparoService]): dispara
  /// UM ÚNICO SMS, IMEDIATAMENTE, com a localização atual — nunca mais de
  /// uma mensagem nesta etapa (requisito de produto: o disparo tem que
  /// ser instantâneo, sem uma segunda mensagem de "atualização" chegando
  /// depois e sem atrasar a abertura da câmera do P2, que roda em
  /// paralelo a este método, não depois dele).
  ///
  /// "Localização atual" é resolvida com o mínimo de espera possível: 1)
  /// última posição em cache do sistema (instantânea); 2) só na ausência
  /// de cache, UMA única leitura de GPS em tempo real com timeout curto.
  /// Nunca faz uma segunda leitura/reenvio depois disso.
  ///
  /// Como o gatilho físico não tem acesso a nenhum
  /// TextEditingController/contexto de UI, [contexto] é sempre lido do
  /// SQLite ('contexto_timer_ativo'), com fallback para uma mensagem
  /// padrão caso não exista nada salvo.
  Future<void> dispararSosComDuplaLocalizacao() async {
    debugPrint('🚨 [SOS] Canal SMS oficial acionado — disparando localização imediata (1 SMS).');

    final l10n = await L10nHeadlessService.obter();

    String anotacoesUsuario = '';

    try {
      final config = await _db.getUserConfig();
      anotacoesUsuario =
          (config?['contexto_timer_ativo'] as String?)?.trim() ?? '';
    } catch (_) {}
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = l10n.smsSosContextoPadrao;
    }

    List<Map<String, dynamic>> contatosEmergencia = [];
    try {
      contatosEmergencia = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [SOS FÍSICO] Falha ao buscar contatos de emergência: $e');
    }

    // Cache instantâneo primeiro; só consulta o GPS em tempo real (timeout
    // curto) se não houver NENHUMA posição em cache — nunca as duas.
    Position? posicaoAtual = await _obterPosicaoDeCacheImediata();
    if (posicaoAtual == null) {
      try {
        posicaoAtual = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 6),
        );
      } catch (e) {
        debugPrint('⚠️ [SOS FÍSICO] Falha ao obter localização em tempo real: $e');
      }
    }

    final String localizacaoFormatada = posicaoAtual != null
        ? _formatarPosicao(posicaoAtual, l10n)
        : l10n.smsLocalizacaoCacheIndisponivel;

    final mensagemImediata =
        l10n.smsSosImediatoCorpo(localizacaoFormatada, anotacoesUsuario);

    debugPrint('📋 [SOS FÍSICO] SMS imediato (localização atual): $mensagemImediata');

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoSosCacheTitulo,
        descricao: l10n.historicoSosCacheDescricao(localizacaoFormatada),
        categoria: 'critico',
      );
    } catch (e) {
      debugPrint('⚠️ [SOS FÍSICO] Falha ao registrar evento no histórico: $e');
    }

    if (posicaoAtual != null) {
      // Fire-and-forget: não bloqueia o envio do SMS abaixo.
      ApiService().dispararAlertaWeb(
        latitude: posicaoAtual.latitude,
        longitude: posicaoAtual.longitude,
        contexto: anotacoesUsuario,
        timestampLocal: DateTime.now(),
      );
    }

    await _enviarSms(contatosEmergencia, mensagemImediata);
  }
/// FALLBACK de contingência (SMS de texto, SEM a foto em si) usado por
  /// [SosDisparoService.dispararFotoCapturada] exclusivamente quando não
  /// há sessão do Firebase Auth disponível — mesma regra de
  /// [dispararSosComDuplaLocalizacao]. Com sessão, a foto é enviada de
  /// verdade via Firebase Storage + Push.
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

    final l10n = await L10nHeadlessService.obter();
    final String link = urlNovem ?? 'https://seu-painel-nuvem.com/login';

    final String mensagemResgate = l10n.smsResgateCorpo(link, login, senha);

    debugPrint('📋 [SMS RESGATE] Enviando credenciais de resgate para contatos...');
    await _enviarSms(contatos, mensagemResgate);

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoEvidenciaFotograficaTitulo,
        descricao: l10n.historicoEvidenciaFotograficaDescricao,
        categoria: 'critico',
      );
    } catch (_) {}
  }

  /// Canal SMS OFICIAL do P2 da sequência unificada de SOS (ver
  /// [SosDisparoService.dispararFotoCapturada]) — enviado SEMPRE, em
  /// paralelo ao canal de nuvem (Push), com o link real da
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

    final l10n = await L10nHeadlessService.obter();
    final Position? posicao = await _obterPosicaoDeCacheImediata();
    final String localizacaoFormatada = posicao != null
        ? _formatarPosicao(posicao, l10n)
        : l10n.smsLocalizacaoIndisponivelMomentoEnvio;

    final String mensagem = l10n.smsFotoCorpo(fotoUrl, localizacaoFormatada);

    debugPrint('📋 [SMS Foto] Enviando localização + link da foto para contatos...');
    await _enviarSms(contatos, mensagem);

    try {
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoFotoSosSmsTitulo,
        descricao: l10n.historicoFotoSosSmsDescricao(fotoUrl),
        categoria: 'critico',
      );
    } catch (_) {}
  }
}
