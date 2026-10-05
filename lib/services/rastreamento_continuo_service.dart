import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'l10n_headless_service.dart';
import 'monitoramento_service.dart';
import 'plano_ciclo_service.dart';

/// Estado do rastreamento contínuo lido do nativo (mesmo conteúdo gravado
/// em `usuarios/{uid}/monitoramento/estado`).
@immutable
class EstadoRastreamento {
  const EstadoRastreamento({
    required this.permissao,
    required this.precisaoExata,
    required this.atualizacaoSegundoPlano,
    required this.otimizacaoBateriaIgnorada,
    required this.modoPoucaEnergia,
    required this.rastreamentoAtivo,
    this.motivoInativo,
  });

  /// `sempre` | `durante_uso` | `negada`.
  final String permissao;
  final bool precisaoExata;
  final bool atualizacaoSegundoPlano;
  final bool otimizacaoBateriaIgnorada;
  final bool modoPoucaEnergia;
  final bool rastreamentoAtivo;
  final String? motivoInativo;

  /// "Permitir o tempo todo" concedida.
  bool get sempre => permissao == 'sempre';

  factory EstadoRastreamento.doMapa(Map<dynamic, dynamic> m) => EstadoRastreamento(
        permissao: m['permissao'] as String? ?? 'negada',
        precisaoExata: m['precisaoExata'] as bool? ?? false,
        atualizacaoSegundoPlano: m['atualizacaoSegundoPlano'] as bool? ?? false,
        otimizacaoBateriaIgnorada: m['otimizacaoBateriaIgnorada'] as bool? ?? false,
        modoPoucaEnergia: m['modoPoucaEnergia'] as bool? ?? false,
        rastreamentoAtivo: m['rastreamentoAtivo'] as bool? ?? false,
        motivoInativo: m['motivoInativo'] as String?,
      );
}

/// Quem pode ver a MINHA localização (permissão "aprovado" em que sou o alvo).
@immutable
class ContatoQueMeMonitora {
  const ContatoQueMeMonitora({required this.uid, required this.nome});
  final String uid;
  final String nome;
}

/// Liga/desliga o rastreamento contínuo NATIVO da aba Monitoramento
/// (`RastreamentoContinuo.kt`: foreground service de localização) — mesma
/// regra do app iOS (`RastreamentoContinuo.swift`), com os mesmos campos e
/// valores de `motivoInativo` no Firestore.
///
/// Fica ativo só com TUDO isto: sessão, ao menos uma permissão "aprovado"
/// em que eu sou o alvo, consentimento explícito em tela
/// (`ConsentimentoRastreamentoScreen`), compartilhamento não pausado e,
/// conferido também pelo nativo, "Permitir o tempo todo" e Plano Free nos
/// dias ativos (ou Premium). O nativo guarda a configuração e segue sozinho
/// depois de reiniciar o aparelho.
///
/// Desliga (gravando o motivo) ao sair da conta (`logout`), excluir a
/// conta (`conta_excluida`), ter a sessão encerrada em outro aparelho
/// (`sessao_encerrada`) ou perder o último monitor (`sem_monitores`).
class RastreamentoContinuoService {
  RastreamentoContinuoService._internal();
  static final RastreamentoContinuoService _instance = RastreamentoContinuoService._internal();
  factory RastreamentoContinuoService() => _instance;

  static const MethodChannel _canal = MethodChannel('guardiaox/rastreamento');

  /// Gravada pelo nativo enquanto o serviço roda — lida pelo pedido sob
  /// demanda (isolate do FCM, sem acesso ao canal) para gravar
  /// `rastreamentoContinuo: true` com o contínuo ligado.
  static const String chaveAtivoNoAparelho = 'rastreamento_continuo_ativo';

  bool get suportado => Platform.isAndroid;

  /// Quem vê minha localização agora (permissões "aprovado").
  final ValueNotifier<List<ContatoQueMeMonitora>> monitorandoMe =
      ValueNotifier<List<ContatoQueMeMonitora>>(const []);
  final ValueNotifier<bool> consentido = ValueNotifier<bool>(false);
  final ValueNotifier<bool> pausado = ValueNotifier<bool>(false);
  final ValueNotifier<EstadoRastreamento?> estado = ValueNotifier<EstadoRastreamento?>(null);

  /// Plano lido (ou `null` antes do primeiro snapshot).
  final ValueNotifier<PlanoCicloStatus?> plano = ValueNotifier<PlanoCicloStatus?>(null);

  /// Fim do bloqueio do Plano Free em vigor (`null` fora dele/Premium).
  DateTime? get fimBloqueioPlano {
    final p = plano.value;
    if (p == null || p.ativo) return null;
    return p.dataRenovacao;
  }

  bool _iniciado = false;
  String? _uid;

  /// "Sair"/exclusão já pararam o nativo com o motivo certo: o
  /// `authStateChanges` (null) que vem logo depois não para de novo.
  bool _saidaJaTratada = false;
  StreamSubscription<PlanoCicloStatus?>? _assinaturaPlano;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assinaturaPermissoes;

  String _chaveConsentimento(String uid) => 'rastreamento_continuo_consentido_$uid';
  String _chavePausa(String uid) => 'rastreamento_continuo_pausado_$uid';

  /// Idempotente; chamado depois do Firebase (ver `main.dart`) e de novo
  /// pela Home — sem Firebase ainda, tenta de novo na próxima chamada.
  void iniciar() {
    if (!suportado || _iniciado) return;
    if (Firebase.apps.isEmpty) return;
    _iniciado = true;
    // Assinatura pela vida inteira do processo (singleton).
    FirebaseAuth.instance.authStateChanges().listen(_aoMudarSessao);
  }

  Future<void> _aoMudarSessao(User? usuario) async {
    if (usuario != null && usuario.uid == _uid) return;
    await _assinaturaPlano?.cancel();
    await _assinaturaPermissoes?.cancel();
    _assinaturaPlano = null;
    _assinaturaPermissoes = null;
    plano.value = null;
    monitorandoMe.value = const [];

    if (usuario == null) {
      // Sessão encerrada fora do "Sair" (login em outro aparelho, conta
      // apagada): desliga. Saída pelo "Sair"/exclusão já parou antes
      // (ver [pararAntesDeSair]).
      if (_uid != null && !_saidaJaTratada) await _parar('sessao_encerrada');
      _saidaJaTratada = false;
      _uid = null;
      return;
    }
    _saidaJaTratada = false;
    _uid = usuario.uid;
    try {
      final prefs = await SharedPreferences.getInstance();
      consentido.value = prefs.getBool(_chaveConsentimento(usuario.uid)) ?? false;
      pausado.value = prefs.getBool(_chavePausa(usuario.uid)) ?? false;
    } catch (_) {}

    _assinaturaPlano = PlanoCicloService().statusStream().listen((status) {
      plano.value = status;
      unawaited(_sincronizar());
    });
    _assinaturaPermissoes = FirebaseFirestore.instance
        .collection(MonitoramentoService.colecaoPermissoes)
        .where('uidAlvo', isEqualTo: usuario.uid)
        .where('status', isEqualTo: MonitoramentoService.statusAprovado)
        .snapshots()
        .listen((snap) async {
      monitorandoMe.value = await _resolverNomes(snap.docs);
      unawaited(_sincronizar());
    }, onError: (Object e) {
      debugPrint('⚠️ [Rastreamento] Falha ao consultar quem me monitora: $e');
    });
    unawaited(_sincronizar());
  }

  Future<List<ContatoQueMeMonitora>> _resolverNomes(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    final lista = <ContatoQueMeMonitora>[];
    for (final doc in docs) {
      final dados = doc.data();
      if (dados['bloqueado'] == true) continue;
      final uid = dados['uidSolicitante'] as String?;
      if (uid == null) continue;
      String? nome;
      try {
        nome = (await DatabaseHelper().buscarContatoMonitoramentoPorUid(uid))?['nome'] as String?;
      } catch (_) {}
      nome ??= (dados['nomeSolicitante'] as String?)?.trim();
      if (nome == null || nome.isEmpty) nome = dados['telefoneSolicitante'] as String? ?? '—';
      lista.add(ContatoQueMeMonitora(uid: uid, nome: nome));
    }
    return lista;
  }

  /// Por que o rastreamento está desligado (`null` = nada a explicar):
  /// primeiro o motivo do app (quem me monitora, consentimento, pausa),
  /// depois o do nativo ("Permitir o tempo todo", Plano Free, sessão).
  String? get motivoInativo => _motivoInativoDart() ?? estado.value?.motivoInativo;

  /// Motivo para o Dart pedir "desligado" (`null` = pedir ligado).
  String? _motivoInativoDart() {
    if (monitorandoMe.value.isEmpty) return 'sem_monitores';
    if (!consentido.value) return 'sem_consentimento';
    if (pausado.value) return 'pausado';
    return null;
  }

  Future<void> _sincronizar() async {
    final uid = _uid;
    if (!suportado || uid == null) return;
    final motivo = _motivoInativoDart();
    final p = plano.value;
    // Quem nunca consentiu não precisa de configuração nativa nenhuma (e
    // nada é gravado no servidor): só lê o estado para a tela.
    if (!consentido.value) {
      await atualizarEstado();
      return;
    }
    try {
      final l10n = await L10nHeadlessService.obter();
      final opcoes = Firebase.app().options;
      final resposta = await _canal.invokeMethod<Map<dynamic, dynamic>>('configurar', {
        'ativo': motivo == null,
        'motivoInativo': motivo,
        'uid': uid,
        'isPremium': p?.isPremium ?? false,
        'cicloInicioMs': p?.cycleStartDate.millisecondsSinceEpoch,
        'temMonitorAprovado': monitorandoMe.value.isNotEmpty,
        'tituloNotificacao': l10n.marcaGuardiaoX,
        'textoNotificacao': l10n.rcNotificacaoTexto(monitorandoMe.value.length),
        'nomeCanal': l10n.rcNotificacaoCanal,
        'firebaseApiKey': opcoes.apiKey,
        'firebaseAppId': opcoes.appId,
        'firebaseProjectId': opcoes.projectId,
        'firebaseSenderId': opcoes.messagingSenderId,
        'firebaseStorageBucket': opcoes.storageBucket,
      });
      if (resposta != null) estado.value = EstadoRastreamento.doMapa(resposta);
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao configurar o nativo: $e');
    }
  }

  Future<EstadoRastreamento?> atualizarEstado() async {
    if (!suportado) return null;
    try {
      final resposta = await _canal.invokeMethod<Map<dynamic, dynamic>>('estado');
      if (resposta != null) estado.value = EstadoRastreamento.doMapa(resposta);
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao ler o estado: $e');
    }
    return estado.value;
  }

  /// Reaplica a configuração (ex.: voltou das Configurações do Android com
  /// "Permitir o tempo todo" concedida).
  Future<void> reaplicar() => _sincronizar();

  /// Consentimento explícito dado na tela (ver `ConsentimentoRastreamentoScreen`).
  Future<void> registrarConsentimento() async {
    final uid = _uid;
    if (uid == null) return;
    consentido.value = true;
    pausado.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chaveConsentimento(uid), true);
      await prefs.setBool(_chavePausa(uid), false);
    } catch (_) {}
    await _sincronizar();
  }

  Future<void> definirPausa(bool pausar) async {
    final uid = _uid;
    if (uid == null) return;
    pausado.value = pausar;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chavePausa(uid), pausar);
    } catch (_) {}
    await _sincronizar();
  }

  /// Para ANTES de a sessão acabar (para o estado "desligado" ainda chegar
  /// ao servidor). Sair da conta / excluir a conta.
  Future<void> pararAntesDeSair(String motivo) async {
    if (!suportado) return;
    _saidaJaTratada = true;
    await _parar(motivo);
  }

  /// Exclusão da conta falhou: a sessão continua — volta ao que o usuário
  /// tinha escolhido.
  Future<void> retomarAposSaidaCancelada() async {
    _saidaJaTratada = false;
    await _sincronizar();
  }

  Future<void> _parar(String motivo) async {
    try {
      await _canal.invokeMethod<void>('parar', {'motivo': motivo}).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao parar o nativo: $e');
    }
  }

  /// O serviço contínuo está rodando NESTE aparelho? Lido do disco (vale
  /// também no isolate do FCM, sem o canal) — ver [chaveAtivoNoAparelho].
  static Future<bool> ativoNoAparelho() async {
    if (!Platform.isAndroid) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getBool(chaveAtivoNoAparelho) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Texto do `motivoInativo` (mesmos valores do iOS e do servidor) para o
/// quadro da aba Monitoramento e o Status de Permissões.
String? textoMotivoRastreamento(AppLocalizations l10n, String? motivo) => switch (motivo) {
      'sem_monitores' => l10n.rcMotivoSemMonitores,
      'sem_consentimento' || 'nao_configurado' => l10n.rcMotivoSemConsentimento,
      'pausado' => l10n.rcMotivoPausado,
      'sem_permissao_sempre' => l10n.rcMotivoSemSempre,
      'plano_free' => l10n.rcMotivoPlanoFree,
      'sessao_diferente' => l10n.rcMotivoSessaoDiferente,
      'sessao_encerrada' => l10n.rcMotivoSessaoEncerrada,
      'logout' || 'sem_sessao' => l10n.rcMotivoSemSessao,
      'conta_excluida' => l10n.rcMotivoContaExcluida,
      _ => null,
    };
