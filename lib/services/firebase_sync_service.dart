import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_auth_service.dart';

/// Teto de tempo para QUALQUER chamada de rede ao Firestore neste
/// serviço. CORREÇÃO (bug real observado em teste): sem isto, uma
/// chamada ao Firestore sem conectividade real com a internet (ex:
/// Wi-Fi só com acesso à rede local, sem rota para a internet) pode
/// ficar PENDURADA por um tempo indefinido — diferente de `ApiService`
/// (Dio), que já tinha timeouts explícitos, `cloud_firestore` não tem
/// um teto padrão curto. Como o disparo de emergência (ver
/// `rotina_alarme_service.dart`/`_callbackJanelaFinalExpirada`) `await`
/// este serviço ANTES do SMS nativo (que não depende de internet), uma
/// chamada pendurada aqui bloqueava o SMS inteiro — foi exatamente o que
/// aconteceu num teste real: nenhum log apareceu depois da mensagem de
/// entrada do callback, indicando que a execução ficou travada nesta
/// chamada.
const Duration _timeoutFirestore = Duration(seconds: 8);

/// Serviço centralizado de sincronização com o Firebase/Firestore,
/// atuando como uma camada de resiliência EXTRA e totalmente independente
/// do backend FastAPI local ([ApiService]) e do SMS nativo
/// ([EmergencyAlertService]): enquanto aqueles dependem do celular estar
/// ligado, funcional e (no caso do backend local) na mesma rede Wi-Fi no
/// momento do envio, os dados gravados aqui já estão na nuvem assim que a
/// chamada retorna — sobrevivendo mesmo que o aparelho seja
/// destruído/desligado/perca sinal logo em seguida.
///
/// Modelo de dados no Firestore:
/// - `usuarios/{usuarioId}`: documento ÚNICO por usuário, sempre
///   SOBRESCRITO (nunca acumula histórico nem custo extra de
///   armazenamento) a cada atualização periódica de localização,
///   contendo os campos `latitude`, `longitude`, `atualizadoEm`
///   (timestamp do servidor) e `contatosEmergencia` (lista sincronizada a
///   partir do SQLite local — ver [sincronizarContatosEmergencia]).
/// - `usuarios/{usuarioId}/alertas/{autoId}`: um NOVO documento por
///   evento crítico (ex: 2 PINs incorretos consecutivos no desarme),
///   pensado para disparar uma Cloud Function (`onDocumentCreated`) que
///   resgata a última localização já gravada no documento acima e aciona
///   o envio de SMS/notificação aos contatos — ver `functions/index.js`
///   na raiz do projeto (o gateway de SMS em si ainda é um TODO isolado
///   lá, aguardando a escolha do provedor).
///
/// Todas as chamadas são protegidas por try/catch e NUNCA lançam exceção
/// para quem as invoca: se o Firebase não tiver sido inicializado (ex:
/// falha de rede no cold start) ou a chamada falhar, apenas registra via
/// [debugPrint] — o app continua 100% funcional com SMS nativo e backend
/// local, que não dependem do Firebase.
class FirebaseSyncService {
  FirebaseSyncService._internal();
  static final FirebaseSyncService _instance = FirebaseSyncService._internal();
  factory FirebaseSyncService() => _instance;

  /// Nome da coleção raiz no Firestore.
  static const String _colecaoUsuarios = 'usuarios';

  /// `uid` do Firebase Auth do usuário logado — identifica o documento
  /// `usuarios/{uid}` em todo este serviço. `null` se não houver sessão
  /// ativa (não deve acontecer no fluxo normal, já que a Home só é
  /// alcançada após login/cadastro reais, ver `main.dart`).
  static String? get _usuarioId => FirebaseAuthService().uidAtual;

  /// `true` somente se [Firebase.initializeApp] tiver sido chamado com
  /// sucesso no `main()` E houver um usuário autenticado. Evita qualquer
  /// tentativa de acesso ao Firestore (e a exceção nativa que isso
  /// geraria) caso a inicialização tenha falhado silenciosamente no cold
  /// start, ou caso este serviço seja chamado antes do login (ex: telas
  /// de Login/Cadastro).
  bool get _firebaseDisponivel =>
      Firebase.apps.isNotEmpty && _usuarioId != null;

  DocumentReference<Map<String, dynamic>> get _documentoUsuario =>
      FirebaseFirestore.instance.collection(_colecaoUsuarios).doc(_usuarioId);

  /// Cria (via merge) o documento `usuarios/{uid}` logo após o cadastro
  /// bem-sucedido no Firebase Auth ([FirebaseAuthService.criarConta]).
  /// [telefone] deve já vir normalizado em E.164 (ver
  /// `normalizarTelefoneE164` usado em [CadastroScreen]) — é por ele que
  /// a Cloud Function resolve, na hora de um alerta, quais contatos de
  /// emergência têm conta no app (ver `alertaHibridoService.js`).
  ///
  /// `creditosDisponiveis: 0` só é gravado AQUI (cadastro) — nenhum
  /// outro ponto do app cliente deve voltar a escrever este campo
  /// depois disso; toda alteração de saldo (unidades de disparo, NUNCA
  /// moeda financeira) passa exclusivamente por Cloud Functions (ver
  /// `functions/walletService.js`).
  Future<void> criarPerfilInicial({
    required String nome,
    required String email,
    required String telefone,
  }) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documentoUsuario.set(
        {
          'nome': nome,
          'email': email,
          'telefone': telefone,
          'creditosDisponiveis': 0,
          'criadoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao criar perfil inicial do usuário: $e');
    }
  }

  /// Grava/atualiza o token FCM atual do aparelho em
  /// `usuarios/{uid}.fcmToken` — é por ele que a Cloud Function resolve,
  /// na hora de um alerta, para onde enviar o Push App-para-App gratuito
  /// (ver [FcmService], que chama este método na inicialização e sempre
  /// que o token for renovado pelo `onTokenRefresh`).
  Future<void> atualizarFcmToken(String token) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documentoUsuario.set(
        {'fcmToken': token},
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint('⚠️ [FirebaseSyncService] Falha ao atualizar fcmToken: $e');
    }
  }

  /// Confirma, para o pipeline híbrido de alerta, que o Push FCM deste
  /// alerta foi ENTREGUE A ESTE DISPOSITIVO — ver [FcmService], que
  /// chama este método assim que o handler `onMessage`/`onBackgroundMessage`
  /// é executado pelo SO, o que só acontece quando o Firebase efetivamente
  /// entrega a mensagem ao aparelho (inclusive com a tela bloqueada e o
  /// app fechado). NÃO depende do usuário abrir a notificação, tocar
  /// nela ou sequer olhar para o aparelho — é um sinal de ENTREGA, não de
  /// leitura/abertura do app.
  ///
  /// Grava em `entregas_alerta/{idEntrega}/confirmacoes/{uid}`
  /// (`entregueApp: true` + `status: 'entregue_dispositivo'`, redundantes
  /// de propósito para deixar o critério inequívoco para quem ler o
  /// documento), o único ponto do pipeline em que o cliente escreve
  /// diretamente nessa coleção (ver `firestore.rules`) — é essa
  /// confirmação que o job de transbordo
  /// (`functions/transbordoWhatsappMonitor.js`) verifica antes de decidir
  /// se cobra o WhatsApp de contingência para este contato.
  Future<void> confirmarEntregaAlerta(String idEntrega) async {
    if (!_firebaseDisponivel) return;
    try {
      await FirebaseFirestore.instance
          .collection('entregas_alerta')
          .doc(idEntrega)
          .collection('confirmacoes')
          .doc(_usuarioId)
          .set({
        'entregueApp': true,
        'status': 'entregue_dispositivo',
        'entregueAppEm': FieldValue.serverTimestamp(),
      }).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [FirebaseSyncService] Confirmação de ENTREGA NO DISPOSITIVO enviada para entregas_alerta/$idEntrega.');
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao confirmar entrega do alerta $idEntrega: $e');
    }
  }

  /// Sobrescreve (via merge, nunca acumula) a última localização
  /// conhecida do usuário no documento `usuarios/{usuarioId}`. Deve ser
  /// chamada periodicamente (a cada 1 minuto, ver
  /// [LocationService.iniciarCicloDeAtualizacao]) enquanto o
  /// monitoramento ativo estiver em andamento (cronômetro de Segurança ou
  /// alarme de rotina disparado da Família aguardando confirmação).
  Future<void> atualizarLocalizacaoAtual({
    required double latitude,
    required double longitude,
  }) async {
    if (!_firebaseDisponivel) return;
    final agora = FieldValue.serverTimestamp();
    try {
      await _documentoUsuario.set(
        {
          'latitude': latitude,
          'longitude': longitude,
          'atualizadoEm': agora,
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao atualizar localização no Firestore: $e');
    }

    // Espelha a MESMA leitura de GPS em `usuarios/{uid}/monitoramento/atual`
    // — documento SEPARADO do principal acima, com regra de leitura
    // própria (ver firestore.rules) que permite acesso a qualquer usuário
    // com permissão "aprovado" na aba Monitoramento (MonitoramentoService),
    // sem expor os demais campos privados do documento principal
    // (creditosDisponiveis, fcmToken). Best-effort e independente da escrita acima —
    // uma falha aqui nunca deve impedir o heartbeat usado pelo alarme de
    // pânico.
    try {
      await _documentoUsuario.collection('monitoramento').doc('atual').set({
        'latitude': latitude,
        'longitude': longitude,
        'atualizadoEm': agora,
      }).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao espelhar localização para a aba Monitoramento: $e');
    }
  }

  /// Sincroniza a lista atual de contatos de emergência (nome + telefone)
  /// do SQLite local para o Firestore, SOBRESCREVENDO por completo o
  /// campo `contatosEmergencia` do documento do usuário. Necessário
  /// porque a Cloud Function não tem acesso ao SQLite do aparelho — é
  /// assim que ela sabe para quem disparar o SMS/notificação.
  ///
  /// [contatos] deve vir diretamente de
  /// `DatabaseHelper.getContatosEmergencia()`, preservando o mesmo
  /// critério já usado pelo SMS nativo (inclui contatos com exclusão
  /// pendente dentro da janela de 24h, filtra apenas telefones vazios).
  Future<void> sincronizarContatosEmergencia(
    List<Map<String, dynamic>> contatos,
  ) async {
    if (!_firebaseDisponivel) return;
    try {
      final listaSincronizada = contatos
          .map((contato) => {
                'nome': (contato['nome'] as String?) ?? '',
                'telefone': (contato['telefone'] as String?) ?? '',
                // Ver Switch "Notificar via WhatsApp ($0.10 USD)" em
                // ConfiguracoesTab — só contatos com esta flag ligada
                // podem gerar cobrança de WhatsApp de contingência.
                'whatsappHabilitado': (contato['whatsapp_habilitado'] as int?) == 1,
              })
          .where((contato) => (contato['telefone'] as String).isNotEmpty)
          .toList();

      await _documentoUsuario.set(
        {'contatosEmergencia': listaSincronizada},
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao sincronizar contatos de emergência: $e');
    }
  }

  /// Grava a chave GLOBAL "Enviar também via WhatsApp" (ver
  /// ConfiguracoesTab) em `usuarios/{uid}.enviarWhatsappSimultaneo` —
  /// lida pela Cloud Function no momento do disparo
  /// ([dispararAlertaHibrido] em `functions/alertaHibridoService.js`)
  /// para decidir se o WhatsApp de contingência deve ser enviado
  /// IMEDIATAMENTE, em paralelo ao Push FCM, em vez de aguardar os 60s
  /// normais de transbordo (`functions/transbordoWhatsappMonitor.js`).
  Future<void> atualizarEnviarWhatsappSimultaneo(bool ativo) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documentoUsuario.set(
        {'enviarWhatsappSimultaneo': ativo},
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [FirebaseSyncService] enviarWhatsappSimultaneo atualizado para $ativo.');
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao atualizar enviarWhatsappSimultaneo: $e');
    }
  }

  /// Dispara o P1 da sequência unificada de SOS (botão físico de Volume+
  /// ou botão de SOS manual da aba Segurança — ver [SosDisparoService])
  /// para a nuvem: diferente de [dispararAlertaTentativaDesarmeIncorreto]
  /// (que não carrega coordenadas, a Cloud Function usa a última
  /// localização já sincronizada), [latitude]/[longitude] são a posição
  /// capturada NA HORA do disparo, garantindo que a mensagem de
  /// localização seja a mais precisa possível mesmo que a sincronização
  /// periódica esteja desatualizada. Requer sessão autenticada — retorna
  /// `false` sem lançar exceção se não houver `uid` disponível (ver
  /// [SosDisparoService], que usa o SMS nativo como fallback nesse caso).
  ///
  /// [origem] é só para log/telemetria (ex: distingue "sos_fisico_volume"
  /// de "sos_manual" mesmo os dois usando o mesmo `tipo` de alerta) — não
  /// afeta a lógica de disparo no backend.
  Future<bool> dispararAlertaSosFisico({
    double? latitude,
    double? longitude,
    required String origem,
  }) async {
    if (!_firebaseDisponivel) return false;
    try {
      await _documentoUsuario.collection('alertas').add({
        'tipo': 'sos_fisico',
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'origem': origem,
        'criadoEm': FieldValue.serverTimestamp(),
        'processado': false,
      }).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [FirebaseSyncService] Alerta de SOS ($origem) enviado à nuvem.');
      return true;
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao enviar alerta de SOS à nuvem: $e');
      return false;
    }
  }

  /// Dispara o P2 da sequência unificada de SOS — a foto já foi enviada
  /// ao Firebase Storage por [SosDisparoService] antes desta chamada,
  /// [fotoUrl] é o link (com token de acesso) que a Cloud Function
  /// repassa aos contatos de emergência via Push e WhatsApp. Requer
  /// sessão autenticada, mesma regra de [dispararAlertaSosFisico].
  Future<bool> dispararAlertaSosFoto({
    required String fotoUrl,
    required String origem,
  }) async {
    if (!_firebaseDisponivel) return false;
    try {
      await _documentoUsuario.collection('alertas').add({
        'tipo': 'sos_fisico_foto',
        'fotoUrl': fotoUrl,
        'origem': origem,
        'criadoEm': FieldValue.serverTimestamp(),
        'processado': false,
      }).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [FirebaseSyncService] Alerta de foto do SOS ($origem) enviado à nuvem.');
      return true;
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao enviar alerta de foto do SOS à nuvem: $e');
      return false;
    }
  }

  /// Disparo IMEDIATO e prioritário para a nuvem ao detectar uma falha de
  /// desarme antecipado (PIN incorreto e/ou tempo esgotado, conforme
  /// [motivo]). DEVE ser a PRIMEIRA ação executada (e aguardada) nos
  /// callbacks de erro/expiração de PIN, ANTES de qualquer outro
  /// processamento local/UI — garantindo que o alerta já esteja salvo na
  /// nuvem mesmo que o aparelho seja destruído/desligado/perca sinal nos
  /// segundos seguintes.
  ///
  /// Escreve um novo documento DELIBERADAMENTE MINIMALISTA em
  /// `usuarios/{usuarioId}/alertas` (tipo + timestamp do servidor +
  /// [motivo] opcional) — sem esperar por uma nova leitura de GPS aqui. A
  /// Cloud Function (`functions/index.js`) resgata separadamente a ÚLTIMA
  /// localização já gravada por [atualizarLocalizacaoAtual]. Isso mantém
  /// esta chamada o mais rápida possível, reduzindo ao máximo a janela de
  /// risco entre a falha de desarme e o alerta chegar à nuvem.
  ///
  /// [motivo], quando informado, é repassado para a Cloud Function montar
  /// uma mensagem de SMS precisa sobre o que de fato aconteceu (ver
  /// mesmo parâmetro em
  /// [EmergencyAlertService.dispararAlertaTentativaDesarmeIncorreto]).
  ///
  /// [eventoId], quando informado, é usado como ID DETERMINÍSTICO do
  /// documento (em vez do autoId padrão) — TRAVA CONTRA MENSAGENS
  /// DUPLICADAS: como o mesmo evento de emergência (ex: janela final do
  /// alarme de rotina #N) pode ser detectado por DOIS caminhos
  /// concorrentes (o diálogo de PIN em primeiro plano E o callback
  /// headless nativo, ver `rotina_alarme_service.dart`), uma
  /// `runTransaction` garante que só o PRIMEIRO a chegar aqui realmente
  /// cria o documento — o Cloud Function `onDocumentCreated` só dispara
  /// UMA vez, mesmo que ambos os caminhos cheguem a chamar este método
  /// para o MESMO [eventoId]. Retorna `false` (sem tentar de novo) se já
  /// existir um documento para este evento.
  ///
  /// Sem [eventoId] (comportamento histórico, usado pelos demais fluxos
  /// de emergência que não têm risco de disparo duplo — SOS físico, PIN
  /// de coação, SOS manual), continua criando um novo documento com
  /// autoId a cada chamada.
  Future<bool> dispararAlertaTentativaDesarmeIncorreto({
    String? motivo,
    String? eventoId,
  }) async {
    if (!_firebaseDisponivel) return false;
    try {
      if (eventoId != null && eventoId.isNotEmpty) {
        final documentoEvento = _documentoUsuario.collection('alertas').doc(eventoId);
        final foiCriadoAgora = await FirebaseFirestore.instance
            .runTransaction<bool>((tx) async {
          final snapshotAtual = await tx.get(documentoEvento);
          if (snapshotAtual.exists) return false;
          tx.set(documentoEvento, {
            'tipo': 'tentativa_desarme_incorreto',
            if (motivo != null) 'motivo': motivo,
            'criadoEm': FieldValue.serverTimestamp(),
            'processado': false,
          });
          return true;
        }).timeout(_timeoutFirestore);

        if (!foiCriadoAgora) {
          debugPrint(
              '☁️ [FirebaseSyncService] Alerta #$eventoId já registrado por '
              'outro caminho — evitando disparo duplicado na nuvem.');
          return false;
        }
      } else {
        await _documentoUsuario.collection('alertas').add({
          'tipo': 'tentativa_desarme_incorreto',
          if (motivo != null) 'motivo': motivo,
          'criadoEm': FieldValue.serverTimestamp(),
          'processado': false,
        }).timeout(_timeoutFirestore);
      }
      debugPrint(
          '☁️ [FirebaseSyncService] Alerta de tentativa de desarme incorreta enviado à nuvem.');
      return true;
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao enviar alerta prioritário à nuvem: $e');
      return false;
    }
  }
}
