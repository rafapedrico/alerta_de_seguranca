import 'package:flutter/foundation.dart';

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
  }
}
