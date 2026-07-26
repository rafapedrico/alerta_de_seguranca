import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'firebase_sync_service.dart';

/// Serviço leve (apenas um [ValueNotifier] global) usado para sincronizar
/// automaticamente a lista de contatos de emergência entre as telas de
/// Configurações (onde os contatos são cadastrados/editados/removidos) e
/// Família (onde são exibidos em modo somente leitura).
///
/// Sempre que um contato de emergência for adicionado, editado ou tiver
/// sua exclusão solicitada/efetivada em [ConfiguracoesTab], o contador
/// [versaoContatos] deve ser incrementado via [notificarAlteracao()]. A
/// [FamiliaTabState] ouve esse notifier (mesmo estando "viva" em segundo
/// plano dentro de um IndexedStack) e recarrega a lista imediatamente,
/// sem precisar que o usuário troque de aba manualmente ou puxe para
/// atualizar (RefreshIndicator).
///
/// [notificarAlteracao] também dispara (fire-and-forget) a sincronização
/// da lista atual com o Firestore (ver [FirebaseSyncService]), já que a
/// Cloud Function que dispara o alerta na nuvem não tem acesso ao SQLite
/// do aparelho — precisa da própria cópia dos contatos para saber a quem
/// notificar.
class ContatosEmergenciaService {
  ContatosEmergenciaService._internal();
  static final ContatosEmergenciaService _instance =
      ContatosEmergenciaService._internal();
  factory ContatosEmergenciaService() => _instance;

  /// Incrementado a cada alteração relevante nos contatos de emergência.
  /// O valor em si é irrelevante — apenas a MUDANÇA de valor é usada para
  /// disparar os listeners via [ValueListenableBuilder]/[addListener].
  static final ValueNotifier<int> versaoContatos = ValueNotifier<int>(0);

  /// Deve ser chamado sempre que um contato de emergência for adicionado,
  /// editado, ou tiver sua exclusão solicitada/efetivada.
  static void notificarAlteracao() {
    versaoContatos.value++;
    _sincronizarComFirebase();
  }

  /// Sincroniza a lista atual com o Firestore sem alterar/notificar
  /// [versaoContatos]. Chamado uma vez no cold start do app (ver
  /// `main.dart`), garantindo que contatos já cadastrados ANTES desta
  /// funcionalidade existir também cheguem à nuvem, sem depender do
  /// usuário editar algo primeiro.
  static Future<void> sincronizarAgora() => _sincronizarComFirebase();

  /// Lê a lista atual de contatos direto do SQLite e a envia ao
  /// Firestore. Protegido por try/catch (nunca lança exceção) — se o
  /// Firebase não estiver disponível ou a sincronização falhar, os
  /// contatos permanecem funcionando normalmente no fluxo 100% local
  /// (SMS nativo lê sempre do SQLite, nunca do Firestore).
  static Future<void> _sincronizarComFirebase() async {
    try {
      final contatos = await DatabaseHelper().getContatosEmergencia();
      await FirebaseSyncService().sincronizarContatosEmergencia(contatos);
    } catch (e) {
      debugPrint(
          '⚠️ [ContatosEmergenciaService] Falha ao sincronizar contatos com o Firebase: $e');
    }
  }
}
