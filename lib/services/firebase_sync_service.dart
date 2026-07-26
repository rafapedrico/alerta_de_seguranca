import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

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

  /// Mesmo identificador de usuário/dispositivo já usado pelo
  /// [ApiService] (backend FastAPI local), mantendo os dois pilares de
  /// nuvem referenciando o mesmo "usuário" enquanto não há autenticação
  /// real (Firebase Auth) implementada no app.
  static String get _usuarioId => ApiService.usuarioIdPadrao;

  /// `true` somente se [Firebase.initializeApp] tiver sido chamado com
  /// sucesso no `main()`. Evita qualquer tentativa de acesso ao Firestore
  /// (e a exceção nativa que isso geraria) caso a inicialização tenha
  /// falhado silenciosamente no cold start.
  bool get _firebaseDisponivel => Firebase.apps.isNotEmpty;

  DocumentReference<Map<String, dynamic>> get _documentoUsuario =>
      FirebaseFirestore.instance.collection(_colecaoUsuarios).doc(_usuarioId);

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
    try {
      await _documentoUsuario.set(
        {
          'latitude': latitude,
          'longitude': longitude,
          'atualizadoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao atualizar localização no Firestore: $e');
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
  Future<void> dispararAlertaTentativaDesarmeIncorreto({String? motivo}) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documentoUsuario.collection('alertas').add({
        'tipo': 'tentativa_desarme_incorreto',
        if (motivo != null) 'motivo': motivo,
        'criadoEm': FieldValue.serverTimestamp(),
        'processado': false,
      }).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [FirebaseSyncService] Alerta de tentativa de desarme incorreta enviado à nuvem.');
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseSyncService] Falha ao enviar alerta prioritário à nuvem: $e');
    }
  }
}
