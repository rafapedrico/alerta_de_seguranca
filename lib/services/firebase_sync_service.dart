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
          'criadoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao criar perfil inicial do usuário: $e');
    }
  }

  /// Equivalente de [criarPerfilInicial] para os 3 fluxos de LOGIN SOCIAL
  /// (Google/Facebook/Apple, ver `SocialAuthService`) — chamado por
  /// `LoginScreen._finalizarLoginComSucesso` logo após qualquer login bem
  /// sucedido (social OU e-mail/senha, idempotente nos dois casos).
  ///
  /// CORREÇÃO DE LACUNA REAL (2026-08-16): diferente do cadastro por
  /// e-mail/senha ([CadastroScreen], que sempre chama [criarPerfilInicial]
  /// com nome/e-mail/telefone digitados no formulário), os 3 logins
  /// sociais NUNCA gravavam absolutamente NADA em `usuarios/{uid}` além do
  /// que outros serviços não relacionados (heartbeat de localização, sync
  /// de contatos, token FCM) acabavam gravando incidentalmente via merge —
  /// `nome`/`email` do provedor social (Facebook `public_profile`+`email`,
  /// perfil do Google, nome/e-mail opcionais da Apple) se perdiam por
  /// completo, mesmo já vindo prontos em [User.displayName]/[User.email]
  /// assim que o Firebase Auth aceita a credencial do provedor. Mesma
  /// família do bug de `telefone` nunca gravado para logins sociais (ver
  /// [obterTelefoneAtual]) — só que para nome e e-mail, capturáveis
  /// automaticamente aqui. Diferente de `telefone` (que, por segurança,
  /// desde 2026-08-16 só é gravado no cadastro por e-mail/senha, nunca
  /// editável depois — ver [obterTelefoneAtual]), nome/e-mail não têm
  /// esse mesmo risco de sequestro de alertas, então continuam
  /// sincronizados aqui a cada login.
  ///
  /// [nome]/[email] nulos ou vazios são omitidos do merge (nunca
  /// sobrescreve um valor real já gravado por um `null`/string vazia vindo
  /// do provedor, ex: Apple ocultando o e-mail real atrás de um relay, ou
  /// devolvendo nome só na PRIMEIRA autorização) — `SetOptions(merge:
  /// true)` preserva o resto do documento intacto, inclusive um
  /// `telefone` já preenchido manualmente em "Meu Perfil".
  Future<void> sincronizarPerfilSocial({
    String? nome,
    String? email,
  }) async {
    if (!_firebaseDisponivel) return;
    final dados = <String, dynamic>{
      if (nome != null && nome.isNotEmpty) 'nome': nome,
      if (email != null && email.isNotEmpty) 'email': email,
    };
    if (dados.isEmpty) return;
    try {
      // Propositalmente NÃO grava `criadoEm` aqui (diferente de
      // [criarPerfilInicial]): com `merge: true`, um campo PRESENTE no
      // payload sempre SOBRESCREVE o valor já existente — gravar
      // `FieldValue.serverTimestamp()` aqui reiniciaria `criadoEm` a cada
      // login social subsequente, não só no primeiro. Sem uma leitura
      // prévia para checar se o documento já existe (custo extra
      // desnecessário neste caminho, chamado a cada login), o mais seguro
      // é simplesmente não mexer no campo — o pior caso é um usuário
      // 100% social nunca ter `criadoEm` gravado, cosmético, não afeta
      // nenhuma regra de negócio.
      await _documentoUsuario.set(dados, SetOptions(merge: true)).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao sincronizar perfil do login social: $e');
    }
  }

  /// Lê o `telefone` atual gravado em `usuarios/{uid}` — usado por
  /// [ConfiguracoesTab] (seção "Meu Perfil") para EXIBIR (somente
  /// leitura) o número já cadastrado. `null` se não houver sessão, o
  /// documento não existir ainda, ou o campo nunca ter sido gravado.
  ///
  /// REESPECIFICAÇÃO DE SEGURANÇA (2026-08-16): existia um método
  /// `atualizarTelefone` que permitia editar este campo livremente a
  /// qualquer momento pela tela de Configurações — removido por permitir
  /// que qualquer usuário digitasse um número ARBITRÁRIO/de terceiros e
  /// passasse a "sequestrar" os alertas de emergência endereçados ao
  /// dono real daquele número (a Cloud Function resolve o destinatário
  /// do Push pelo `telefone` gravado aqui). Os únicos fluxos que gravam
  /// `telefone` agora são [CadastroScreen] (cadastro por e-mail/senha) e
  /// [gravarTelefoneVerificado] (login social, ver
  /// `VerificacaoTelefoneScreen` — SMS OTP obrigatório no primeiro
  /// login, fechando o trade-off que existia antes desta correção).
  Future<String?> obterTelefoneAtual() async {
    if (!_firebaseDisponivel) return null;
    try {
      final snap = await _documentoUsuario.get().timeout(_timeoutFirestore);
      return snap.data()?['telefone'] as String?;
    } catch (e) {
      debugPrint('⚠️ [FirebaseSyncService] Falha ao ler telefone atual: $e');
      return null;
    }
  }

  /// Grava o `telefone` em `usuarios/{uid}` — chamado EXCLUSIVAMENTE por
  /// [VerificacaoTelefoneScreen], depois que o número já foi comprovado
  /// via SMS OTP e vinculado à sessão atual com
  /// `User.linkWithCredential(PhoneAuthCredential)` (ver
  /// `FirebaseAuthService`). Nunca deve ser chamado a partir de um campo
  /// de texto livre — é exatamente essa brecha (edição livre sem
  /// verificação) que esta reespecificação de segurança fecha (ver
  /// [obterTelefoneAtual]).
  ///
  /// [telefone] já deve vir normalizado em E.164 (ver [TelefoneUtils]).
  Future<bool> gravarTelefoneVerificado(String telefone) async {
    if (!_firebaseDisponivel) return false;
    try {
      await _documentoUsuario.set(
        {'telefone': telefone},
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
      return true;
    } catch (e) {
      debugPrint('⚠️ [FirebaseSyncService] Falha ao gravar telefone verificado: $e');
      return false;
    }
  }

  /// Grava/atualiza o token FCM atual do aparelho em
  /// `usuarios/{uid}.fcmToken` — é por ele que a Cloud Function resolve,
  /// na hora de um alerta, para onde enviar o Push App-para-App gratuito
  /// (ver [FcmService], que chama este método na inicialização e sempre
  /// que o token for renovado pelo `onTokenRefresh`).
  Future<void> atualizarFcmToken(String token) async {
    if (!_firebaseDisponivel) return;
    final String? uid = _usuarioId;
    // CORREÇÃO (bug real confirmado em teste físico, 2026-08-14 —
    // "messaging/registration-token-not-registered" mesmo com o token
    // atual sincronizado): quando o MESMO telefone está cadastrado em
    // mais de uma conta (ex: contas de teste antigas nunca apagadas), a
    // Cloud Function (`resolverContasPorTelefone`, ver
    // functions/alertaHibridoService.js) resolvia sempre a PRIMEIRA conta
    // que o Firestore devolvesse pra aquele telefone — que podia ser uma
    // conta antiga abandonada, com um token morto, em vez da sessão
    // ativa de verdade. `fcmTokenAtualizadoEm` (timestamp do servidor,
    // sempre que o token é gravado) deixa a Cloud Function ordenar por
    // "conta mais recentemente ativa" em vez de confiar na ordem
    // arbitrária do Firestore.
    final Map<String, dynamic> dados = {
      'fcmToken': token,
      'fcmTokenAtualizadoEm': FieldValue.serverTimestamp(),
    };
    try {
      await _documentoUsuario.set(dados, SetOptions(merge: true)).timeout(_timeoutFirestore);
    } catch (e) {
      // CORREÇÃO (bug real confirmado em teste físico, 2026-08-14 — Razr
      // com sessão restaurada e `uid` válido, `permission-denied` em
      // TODO cold start mesmo já com [FirebaseAuthService.garantirTokenPronto]
      // (`getIdToken(true)`) `await`ado ANTES desta chamada, ver
      // `main.dart`): esse `await` só garante que o SDK Dart/FirebaseAuth
      // TERMINOU de buscar o token renovado — não que o SDK NATIVO do
      // Firestore (que escuta as mudanças de token por um canal próprio,
      // separado) já terminou de propagar esse MESMO token para o
      // provedor de autenticação que efetivamente assina esta chamada.
      // São dois hops assíncronos distintos, sem nenhuma garantia de
      // ordem entre si. Em vez de uma lógica de espera mais complexa
      // (ex: nova ponte nativa só para isso), uma única retentativa com
      // um atraso curto é suficiente: a propagação interna do Firestore é
      // sempre muito mais rápida que 1.5s na prática.
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao atualizar fcmToken (uid=$uid): $e — tentando novamente em 1.5s.');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        await _documentoUsuario.set(dados, SetOptions(merge: true)).timeout(_timeoutFirestore);
        debugPrint('📲 [FirebaseSyncService] fcmToken sincronizado na 2ª tentativa (uid=$uid).');
      } catch (e2) {
        debugPrint(
            '⚠️ [FirebaseSyncService] Falha ao atualizar fcmToken mesmo na 2ª tentativa (uid=$uid): $e2');
      }
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
  /// diretamente nessa coleção (ver `firestore.rules`).
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
    // (fcmToken). Best-effort e independente da escrita acima —
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
  /// pendente dentro da janela de 2h, filtra apenas telefones vazios).
  Future<void> sincronizarContatosEmergencia(
    List<Map<String, dynamic>> contatos,
  ) async {
    if (!_firebaseDisponivel) return;
    try {
      final listaSincronizada = contatos
          .map((contato) => {
                'nome': (contato['nome'] as String?) ?? '',
                'telefone': (contato['telefone'] as String?) ?? '',
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
  /// repassa aos contatos de emergência via Push. Requer sessão
  /// autenticada, mesma regra de [dispararAlertaSosFisico].
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
    // Diagnóstico direto do bug real corrigido em 2026-08-14 (ver
    // `main.dart::_iniciarFirebaseEAuth`): sem sessão ativa
    // (`_usuarioId == null`), este método sempre retorna `false` logo
    // abaixo, SEM escrever nada no Firestore — nem o Push chega ao app
    // receptor. Log explícito para nunca mais precisar adivinhar isso de
    // novo via teste físico.
    debugPrint('☁️ [TENTATIVA DE DESARME INCORRETA] Firebase.apps=${Firebase.apps.length} '
        'uid=${_usuarioId ?? "NULO (sem sessão!)"} _firebaseDisponivel=$_firebaseDisponivel');
    if (!_firebaseDisponivel) {
      debugPrint('🚫 [TENTATIVA DE DESARME INCORRETA] Abortando: Firebase '
          'indisponível ou sem sessão ativa — Push/Firestore NÃO enviado.');
      return false;
    }
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
