import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../firebase_options.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';

/// Uma ocorrência de alarme em andamento — Cronômetro Regressivo (id fixo)
/// ou despertador (id do SQLite), identificada pelo horário programado
/// ([ciclo], epoch ms). [prazo] = fim da tolerância.
@immutable
class OcorrenciaAlarme {
  const OcorrenciaAlarme({
    required this.tipo,
    required this.id,
    required this.ciclo,
    required this.prazo,
    this.abrirTeclado = false,
  });

  static const String tipoRotina = 'rotina';
  static const String tipoCronometro = 'cronometro';

  final String tipo;
  final int id;
  final int ciclo;
  final int prazo;

  /// Veio do botão "Desativar despertador" da notificação: abre direto no
  /// teclado de PIN.
  final bool abrirTeclado;

  String get chave => '$tipo:$id:$ciclo';
  bool get ehCronometro => tipo == tipoCronometro;

  static OcorrenciaAlarme? deMapa(Object? dados) {
    if (dados is! Map) return null;
    final id = (dados['id'] as num?)?.toInt();
    final ciclo = (dados['ciclo'] as num?)?.toInt();
    if (id == null || ciclo == null) return null;
    return OcorrenciaAlarme(
      tipo: (dados['tipo'] as String?) ?? tipoRotina,
      id: id,
      ciclo: ciclo,
      prazo: (dados['prazo'] as num?)?.toInt() ?? ciclo,
      abrirTeclado: dados['abrirTeclado'] == true,
    );
  }
}

/// Ponte com a agenda NATIVA do cronômetro e dos despertadores
/// (`DespertadorAgenda`/`RotinaAlarmWakeService`/`VigiaLocalizacao`,
/// canal `rotina_alarme`) — o que precisa funcionar sem engine Flutter:
/// som único, tela sobre o bloqueio, localização a cada 1 min, reinício do
/// aparelho. Nunca lança: falhas só são registradas.
class AlarmeNativoService {
  AlarmeNativoService._();

  static const MethodChannel _canal =
      MethodChannel('com.example.security_check_app/rotina_alarme');

  static Future<T?> _chamar<T>(String metodo, [Object? argumentos]) async {
    try {
      return await _canal.invokeMethod<T>(metodo, argumentos);
    } catch (e) {
      debugPrint('⚠️ [AlarmeNativo] Falha em "$metodo": $e');
      return null;
    }
  }

  /// `true` se o app pode agendar alarmes exatos (Android 12+).
  static Future<bool> podeAgendarExato() async =>
      await _chamar<bool>('podeAgendarExato') ?? true;

  /// Sincroniza a regra do despertador com a agenda nativa e devolve a
  /// próxima ocorrência armada (`null` se nenhuma — inativo, pausado sem
  /// próxima, único já passado — ou se uma ocorrência está na tolerância).
  static Future<OcorrenciaAlarme?> sincronizarDespertador(Map<String, dynamic> alarme) async {
    final id = alarme['id'] as int?;
    if (id == null) return null;
    final dias = ((alarme['dias_semana'] as String?) ?? '')
        .split(',')
        .map((d) => int.tryParse(d.trim()))
        .whereType<int>()
        .toList();
    final pausa = alarme['alarme_pausado']?.toString();
    final resultado = await _chamar<Map<dynamic, dynamic>>('sincronizarDespertador', {
      'id': id,
      'hora': alarme['hora'] as int? ?? 0,
      'minuto': alarme['minuto'] as int? ?? 0,
      'dias': dias,
      'toleranciaMin': alarme['minutos_tolerancia'] as int? ?? 10,
      'ativo': (alarme['ativo'] as int?) == 1,
      'pausadoEm': pausa != null && pausa.length == 10 ? pausa : null,
      'etiqueta': etiquetaParaNuvem(alarme['etiqueta'] as String?),
      'contexto': (alarme['contexto_personalizado'] as String?) ?? '',
    });
    return OcorrenciaAlarme.deMapa(resultado);
  }

  /// Etiqueta enviada aos contatos/nuvem: NUNCA a chave interna
  /// `KEY_ALARME_ROTINA` — etiqueta vazia vai vazia.
  static String etiquetaParaNuvem(String? etiqueta) {
    final valor = (etiqueta ?? '').trim();
    return valor == 'KEY_ALARME_ROTINA' ? '' : valor;
  }

  static Future<void> removerDespertador(int id) => _chamar('removerDespertador', {'id': id});

  static Future<OcorrenciaAlarme?> proximaOcorrencia(int id) async =>
      OcorrenciaAlarme.deMapa(await _chamar<Map<dynamic, dynamic>>('proximaOcorrencia', {'id': id}));

  /// Arma o fim do cronômetro (alarme exato) e a localização a cada 1 min
  /// até o fim da tolerância. `false` = alarme exato não permitido.
  static Future<bool> armarCronometro({required DateTime fim, required DateTime prazo}) async =>
      await _chamar<bool>('armarCronometro', {
        'ciclo': fim.millisecondsSinceEpoch,
        'prazo': prazo.millisecondsSinceEpoch,
      }) ??
      false;

  static Future<void> encerrarCronometro() => _chamar('encerrarCronometro');

  static Future<void> rearmarTudo() => _chamar('rearmarTudo');

  /// Ocorrência que abriu a tela do alarme (extras do Intent da Activity).
  static Future<OcorrenciaAlarme?> ocorrenciaDaTela() async =>
      OcorrenciaAlarme.deMapa(await _chamar<Map<dynamic, dynamic>>('ocorrenciaDaTela'));

  /// Ocorrências em andamento, da mais antiga para a mais nova.
  static Future<List<OcorrenciaAlarme>> pendentes() async {
    final lista = await _chamar<List<dynamic>>('pendentes') ?? const [];
    return lista.map(OcorrenciaAlarme.deMapa).whereType<OcorrenciaAlarme>().toList();
  }

  /// Ocorrência resolvida (PIN correto ou alerta enviado): marca no nativo
  /// (o fechamento forçado nunca mais dispara para ela), cancela a
  /// notificação de tela cheia, para o som se nada mais estiver tocando e
  /// arma a próxima ocorrência do despertador.
  static Future<void> resolver(String chave) => _chamar('resolverOcorrencia', {'chave': chave});

  static Future<bool> estaResolvida(String chave) async =>
      await _chamar<bool>('estaResolvida', {'chave': chave}) ?? false;

  /// `true` (uma única vez) se a tela reabriu porque o app foi removido
  /// dos Recentes com esta ocorrência em andamento E ainda não resolvida.
  static Future<bool> consumirFechamentoForcado(String chave) async =>
      await _chamar<bool>('consumirFechamentoForcado', {'chave': chave}) ?? false;

  static Future<void> fecharTela() => _chamar('fecharTela');

  static Future<void> acordarTela() => _chamar('acordarTela');

  static Future<void> registrarJanelaLocalizacao({
    required String docId,
    required DateTime inicio,
    required DateTime fim,
    required String tipo,
  }) =>
      _chamar('registrarJanelaLocalizacao', {
        'docId': docId,
        'inicio': inicio.millisecondsSinceEpoch,
        'fim': fim.millisecondsSinceEpoch,
        'tipo': tipo,
      });

  static Future<void> removerJanelaLocalizacao(String docId) =>
      _chamar('removerJanelaLocalizacao', {'docId': docId});

  static Future<bool> reivindicarDisparoUnico(String chave) async =>
      await _chamar<bool>('reivindicarDisparoUnico', {'chave': chave}) ?? true;

  static Future<void> liberarReivindicacaoDisparo(String chave) =>
      _chamar('liberarReivindicacaoDisparo', {'chave': chave});

  /// Textos das notificações nativas no idioma do app e a identidade
  /// (uid, opções do Firebase, contatos) usada pelos serviços nativos
  /// quando o app está fechado. Chamado ao abrir o app, ao trocar o idioma
  /// e ao mudar os contatos de emergência.
  static Future<void> sincronizarTextosEIdentidade() async {
    try {
      final l10n = await L10nHeadlessService.obter();
      await _chamar('salvarTextos', <String, String>{
        'cronometroNotificacaoTitulo': 'Guardião-X',
        'cronometroNotificacaoCorpo': l10n.cronometroNotificacaoCorpo,
        'despertadorNotificacaoTitulo': l10n.despertadorNotificacaoTitulo,
        'despertadorNotificacaoCorpo': l10n.despertadorNotificacaoCorpo,
        'despertadorAcaoDesativar': l10n.despertadorAcaoDesativar,
        'servicoAlarmeAtivo': l10n.servicoAlarmeAtivo,
        'canalAlarmeTelaCheia': l10n.canalAlarmeTelaCheia,
        'canalLocalizacaoSeguranca': l10n.canalLocalizacaoSeguranca,
        'cronometroServicoAtivo': l10n.cronometroServicoAtivo,
        'despertadorServicoAtivo': l10n.despertadorServicoAtivo,
      });
      final contatos = await DatabaseHelper().getContatosEmergencia();
      final opcoes = DefaultFirebaseOptions.currentPlatform;
      await _chamar('configurarIdentidade', <String, Object?>{
        'uid': FirebaseAuthService().uidAtual,
        'firebaseApiKey': opcoes.apiKey,
        'firebaseAppId': opcoes.appId,
        'firebaseProjectId': opcoes.projectId,
        'firebaseSenderId': opcoes.messagingSenderId,
        'firebaseStorageBucket': opcoes.storageBucket,
        'contatos': _contatosJson(contatos),
      });
    } catch (e) {
      debugPrint('⚠️ [AlarmeNativo] Falha ao sincronizar textos/identidade: $e');
    }
  }

  static String _contatosJson(List<Map<String, dynamic>> contatos) => jsonEncode(contatos
      .where((c) => ((c['telefone'] as String?) ?? '').isNotEmpty)
      .map((c) => {'nome': (c['nome'] as String?) ?? '', 'telefone': c['telefone']})
      .toList());
}
