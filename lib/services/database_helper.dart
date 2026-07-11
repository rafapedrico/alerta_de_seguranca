import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';


class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'security_check.db');

    return await openDatabase(
      path,
      version: 12,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );



  }



  Future<void> _onCreate(Database db, int version) async {
    // Table: user_config
    await db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pin_real TEXT,
        tempo_padrao_timer INTEGER,
        forcando_whatsapp INTEGER NOT NULL DEFAULT 0,
        tipo_plano TEXT NOT NULL DEFAULT 'free',
        plano_de_fundo_url TEXT,
        senha_pendente TEXT,
        timestamp_alteracao_senha TEXT,
        timestamp_solicitacao_auditoria TEXT,
        auditoria_liberada_sessao INTEGER NOT NULL DEFAULT 0,
        som_alarme_selecionado INTEGER NOT NULL DEFAULT 1,
        duracao_som_alarme INTEGER NOT NULL DEFAULT 30,
        idioma_selecionado TEXT NOT NULL DEFAULT 'pt'
      )
    ''');


    // Table: contacts (up to 3 contacts) - legado, mantido por compatibilidade
    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone_whatsapp TEXT NOT NULL,
        limite_mensal_alertas INTEGER NOT NULL DEFAULT 10
      )
    ''');

    // Table: contatos_emergencia - tabela isolada e dedicada exclusivamente
    // aos contatos de emergência da aba Família (até 3 contatos), com
    // integração via Agenda do celular (flutter_contacts).
    // Colunas exclusao_pendente/timestamp_solicitacao implementam a trava
    // de segurança de 24h antes da remoção definitiva de um contato.
    await db.execute('''
      CREATE TABLE contatos_emergencia (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone TEXT NOT NULL,
        exclusao_pendente INTEGER NOT NULL DEFAULT 0,
        timestamp_solicitacao TEXT
      )
    ''');

    // Table: historico - registra eventos administrativos do aplicativo
    // nas categorias 'seguranca', 'familia' e 'sistema', exibidos
    // normalmente na aba Histórico.
    await db.execute('''
      CREATE TABLE historico (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        titulo TEXT NOT NULL,
        descricao TEXT NOT NULL,
        categoria TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    // Table: alarmes_rotina - gerenciador de múltiplos alarmes de rotina
    // (estilo despertador do iPhone), usado pela aba Família. Cada
    // alarme possui hora/minuto, dias da semana de repetição (armazenados
    // como string CSV, ex: "1,3,5" para Seg/Qua/Sex, onde 1=Segunda até
    // 7=Domingo), estado ativo/inativo e uma etiqueta/nome livre.
    await db.execute('''
      CREATE TABLE alarmes_rotina (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hora INTEGER NOT NULL,
        minuto INTEGER NOT NULL,
        dias_semana TEXT NOT NULL,
        ativo INTEGER NOT NULL DEFAULT 1,
        etiqueta TEXT
      )
    ''');
  }




  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration from v1 to v2: add plano_de_fundo_url
    if (oldVersion < 2) {
      // Add plano_de_fundo_url to user_config
      await db.execute('ALTER TABLE user_config ADD COLUMN plano_de_fundo_url TEXT');
    }
    // Migration from v2 to v3: add senha_pendente e timestamp_alteracao_senha
    // (regra de segurança de 24h para troca de senha)
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE user_config ADD COLUMN senha_pendente TEXT');
      await db.execute('ALTER TABLE user_config ADD COLUMN timestamp_alteracao_senha TEXT');
    }
    // Migration from v3 to v4: cria a tabela isolada 'contatos_emergencia',
    // usada pela aba Família para até 3 contatos vindos da Agenda do celular.
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contatos_emergencia (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nome TEXT NOT NULL,
          telefone TEXT NOT NULL
        )
      ''');
    }
    // Migration from v4 to v5: adiciona a trava de segurança de 24h para
    // exclusão de contatos de emergência (exclusao_pendente/timestamp_solicitacao).
    if (oldVersion < 5) {
      await db.execute(
        "ALTER TABLE contatos_emergencia ADD COLUMN exclusao_pendente INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        'ALTER TABLE contatos_emergencia ADD COLUMN timestamp_solicitacao TEXT',
      );
    }
    // Migration from v5 to v6: cria a tabela 'historico', usada para
    // registrar os eventos administrativos do aplicativo, exibidos na
    // aba Histórico.
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS historico (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          titulo TEXT NOT NULL,
          descricao TEXT NOT NULL,
          categoria TEXT NOT NULL,
          timestamp TEXT NOT NULL
        )
      ''');
    }
    // Migration from v6 to v7: adiciona os campos de controle da trava de
    // segurança temporal (3h) para liberação da Auditoria de Eventos
    // Sensíveis (registros mais críticos da categoria 'seguranca').
    // - timestamp_solicitacao_auditoria: marca quando o usuário solicitou
    //   a liberação, usado para calcular as 3h de carência.
    // - auditoria_liberada_sessao: flag zerada a cada cold start do app
    //   (ver main.dart), garantindo que a visualização liberada nunca
    //   sobreviva a um fechamento/reabertura completa do aplicativo.
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN timestamp_solicitacao_auditoria TEXT',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN auditoria_liberada_sessao INTEGER NOT NULL DEFAULT 0',
      );
    }
    // Migration from v7 to v8: cria a tabela 'alarmes_rotina', usada pelo
    // novo gerenciador de múltiplos alarmes de rotina da aba Família
    // (estilo despertador do iPhone).
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS alarmes_rotina (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          hora INTEGER NOT NULL,
          minuto INTEGER NOT NULL,
          dias_semana TEXT NOT NULL,
          ativo INTEGER NOT NULL DEFAULT 1,
          etiqueta TEXT
        )
      ''');
    }
    // Migration from v8 to v9: adiciona os campos de controle do disparo
    // de emergência via alarme NATIVO (android_alarm_manager_plus), que
    // roda de forma confiável mesmo com o app fechado/em background:
    // - aguardando_confirmacao_pin: flag persistida indicando que um
    //   disparo de emergência já ocorreu (SMS já enviado pelo callback
    //   headless) e o app deve exibir a tela de bloqueio de PIN assim
    //   que for reaberto (cold start), até que o PIN correto seja
    //   digitado.
    // - contexto_timer_ativo: espelha em disco o texto digitado pelo
    //   usuário no campo "Dica de Contexto" no exato momento em que o
    //   cronômetro de check-in é iniciado, permitindo que o callback
    //   headless (que não tem acesso à UI/memória do app) monte a mesma
    //   mensagem de SMS de emergência.
    // - timestamp_expiracao_alarme: guarda o instante (epoch ms) em que
    //   o alarme nativo está agendado para disparar, usado apenas para
    //   fins de auditoria/depuração.
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN aguardando_confirmacao_pin INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN contexto_timer_ativo TEXT',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN timestamp_expiracao_alarme TEXT',
      );
    }
    // Migration from v9 to v10: adiciona os campos necessários para a
    // Etapa 3 (Alarmes de Rotina Múltiplos e Recorrentes) na tabela
    // 'alarmes_rotina':
    // - contexto_personalizado: dica de contexto PRÓPRIA de cada alarme
    //   de rotina (independente do campo de contexto do check-in manual
    //   em SegurancaTab), usada para montar a mensagem de SMS de
    //   emergência caso o check-in de rotina não seja confirmado a tempo.
    // - minutos_tolerancia: quantos minutos o usuário tem, após a
    //   notificação de check-in de rotina ser exibida, para confirmar
    //   "Cheguei bem" antes do disparo automático de emergência.
    // - ultimo_disparo_epoch: timestamp (epoch ms) do último disparo
    //   NATIVO já processado para este alarme, usado internamente pelo
    //   RotinaAlarmeService para fins de auditoria/depuração.
    if (oldVersion < 10) {
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN contexto_personalizado TEXT',
      );
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN minutos_tolerancia INTEGER NOT NULL DEFAULT 10',
      );
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN ultimo_disparo_epoch INTEGER',
      );
    }
    // Migration from v10 to v11: adiciona os campos de controle do
    // Alerta Sonoro Customizável (Etapa 1 da Expansão Global) e do
    // idioma preferido do usuário (Etapa 2 - Internacionalização):
    // - som_alarme_selecionado: número (1 a 10) do som escolhido pelo
    //   usuário para tocar em loop quando o cronômetro de check-in
    //   chegar a zero.
    // - duracao_som_alarme: duração (em segundos) configurada para o
    //   toque do alerta sonoro.
    // - idioma_selecionado: código do idioma da UI (ver
    //   lib/services/localization_service.dart), suportando os 11
    //   idiomas globais mapeados na Etapa 2.
    if (oldVersion < 11) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN som_alarme_selecionado INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN duracao_som_alarme INTEGER NOT NULL DEFAULT 30',
      );
      await db.execute(
        "ALTER TABLE user_config ADD COLUMN idioma_selecionado TEXT NOT NULL DEFAULT 'pt'",
      );
    }
    // Migration from v11 to v12: adiciona o campo 'alarme_pausado' na
    // tabela 'alarmes_rotina', usado pelo botão "Pausar Alarme" exibido
    // na tela nativa de confirmação de check-in de rotina
    // (RotinaCheckinAlarmActivity/pin_dialog.dart). Quando pausado
    // (1), o alarme de rotina permanece cadastrado (não é excluído),
    // porém o callback headless de disparo (_callbackCheckinRotina)
    // ignora o próximo disparo, e a aba Família exibe "Alarme Pausado"
    // no lugar do horário normal.
    if (oldVersion < 12) {
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN alarme_pausado INTEGER NOT NULL DEFAULT 0',
      );
    }
  }








  // ====================
  // USER CONFIG METHODS
  // ====================

  Future<int> insertUserConfig(Map<String, dynamic> config) async {
    final db = await database;
    return await db.insert('user_config', config);
  }

  Future<Map<String, dynamic>?> getUserConfig() async {
    final db = await database;
    final result = await db.query('user_config', limit: 1);
    return result.isNotEmpty ? result.first : null;
  }

  Future<int> updateUserConfig(Map<String, dynamic> config) async {
    final db = await database;
    return await db.update(
      'user_config',
      config,
      where: 'id = ?',
      whereArgs: [config['id']],
    );
  }

  // ==========================================
  // PIN REAL: PRIMEIRO CADASTRO x ALTERAÇÃO
  // ==========================================
  // Regra de negócio:
  // 1) Primeiro acesso (nenhum PIN cadastrado ainda): o PIN informado é
  //    efetivado INSTANTANEAMENTE em 'pin_real', sem qualquer carência.
  // 2) Alteração de um PIN já existente: a nova senha fica pendente por
  //    24 horas ('senha_pendente' + 'timestamp_alteracao_senha'),
  //    mantendo o PIN atual válido até que o prazo de segurança se
  //    cumpra.
  //
  // Retorna `true` se o PIN foi efetivado instantaneamente (primeiro
  // cadastro), ou `false` se ficou pendente por 24h (alteração).
  Future<bool> salvarOuAgendarPinReal(int userConfigId, String novoPin) async {
    final config = await getUserConfig();
    final String? pinAtual = config?['pin_real'] as String?;
    final bool possuiPinAtivo = pinAtual != null && pinAtual.trim().isNotEmpty;

    if (!possuiPinAtivo) {
      // Regra 1: primeiro cadastro — efetivação instantânea, sem carência.
      await updateUserConfig({
        'id': userConfigId,
        'pin_real': novoPin,
        // Garante que não fique nenhuma alteração pendente residual.
        'senha_pendente': null,
        'timestamp_alteracao_senha': null,
      });
      return true;
    }

    // Regra 2: já existe um PIN ativo — aplica a carência de 24h.
    final agora = DateTime.now().millisecondsSinceEpoch.toString();
    await updateUserConfig({
      'id': userConfigId,
      'senha_pendente': novoPin,
      'timestamp_alteracao_senha': agora,
    });
    return false;
  }

  // ==========================================
  // EFETIVAÇÃO CENTRALIZADA DA SENHA PENDENTE
  // ==========================================
  // Regra de segurança de 24h para ALTERAÇÃO de PIN (regra 2 acima): a
  // verificação "já passaram 24h desde a solicitação? então promove a
  // senha_pendente para pin_real" precisa ser executada de forma
  // consistente independente de qual tela o usuário abrir primeiro
  // (Segurança, Configurações, ou logo no cold start do app). Por isso
  // essa lógica fica centralizada aqui no DatabaseHelper, e é chamada por
  // todos os pontos de entrada relevantes, evitando que o app fique
  // "preso" mostrando o PIN antigo como pendente apenas porque a tela de
  // Segurança específica não foi visitada.
  //
  // Retorna `true` se uma senha pendente foi efetivada nesta chamada
  // (promovida a pin_real), ou `false` caso não houvesse nada pendente ou
  // o prazo de 24h ainda não tenha se cumprido.
  Future<bool> processarSenhaPendenteSeExpirada() async {
    final config = await getUserConfig();
    if (config == null) return false;

    final String? senhaPendente = config['senha_pendente'] as String?;
    final String? timestampStr = config['timestamp_alteracao_senha'] as String?;
    if (senhaPendente == null || timestampStr == null) return false;

    final timestampSolicitacao = int.tryParse(timestampStr);
    if (timestampSolicitacao == null) return false;

    final agora = DateTime.now().millisecondsSinceEpoch;
    final decorrido = agora - timestampSolicitacao;
    const prazoSegurancaMs = 86400000; // 24 horas em milissegundos

    if (decorrido < prazoSegurancaMs) {
      // Ainda dentro da carência: o PIN atual continua sendo o único válido.
      return false;
    }

    // Prazo de segurança cumprido: promove a senha pendente a PIN ativo.
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'pin_real': senhaPendente,
      'senha_pendente': null,
      'timestamp_alteracao_senha': null,
    });
    return true;
  }

  // =================
  // CONTACTS METHODS
  // =================

  Future<int> insertContact(Map<String, dynamic> contact) async {
    final db = await database;
    return await db.insert('contacts', contact);
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await database;
    return await db.query('contacts', orderBy: 'id ASC');
  }

  Future<int> updateContact(Map<String, dynamic> contact) async {
    final db = await database;
    return await db.update(
      'contacts',
      contact,
      where: 'id = ?',
      whereArgs: [contact['id']],
    );
  }

  Future<int> deleteContact(int id) async {
    final db = await database;
    return await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  // ==============================
  // CONTATOS DE EMERGÊNCIA METHODS
  // ==============================
  // Tabela isolada e dedicada exclusivamente aos contatos de emergência
  // cadastrados na aba Família (até 3 contatos), integrados via Agenda
  // do celular (flutter_contacts). Totalmente independente de user_config.

  /// Retorna todos os contatos de emergência cadastrados, ordenados por id.
  Future<List<Map<String, dynamic>>> getContatosEmergencia() async {
    final db = await database;
    return await db.query('contatos_emergencia', orderBy: 'id ASC');
  }

  /// Insere um novo contato de emergência. Retorna o id gerado.
  Future<int> inserirContatoEmergencia(Map<String, dynamic> contato) async {
    final db = await database;
    return await db.insert('contatos_emergencia', contato);
  }

  /// Remove um contato de emergência pelo id (exclusão IMEDIATA/definitiva).
  /// Usado apenas internamente após o prazo de segurança de 24h ter expirado.
  Future<int> deletarContatoEmergencia(int id) async {
    final db = await database;
    return await db.delete('contatos_emergencia', where: 'id = ?', whereArgs: [id]);
  }

  /// Marca um contato de emergência como "exclusão pendente", iniciando a
  /// trava de segurança de 24h. O contato NÃO é removido imediatamente,
  /// apenas sinalizado com o timestamp da solicitação. Continua sendo
  /// retornado normalmente por getContatosEmergencia() (e portanto ainda
  /// recebe alertas de emergência) até que o prazo expire.
  Future<int> solicitarExclusaoContatoEmergencia(int id) async {
    final db = await database;
    final agora = DateTime.now().millisecondsSinceEpoch.toString();
    return await db.update(
      'contatos_emergencia',
      {
        'exclusao_pendente': 1,
        'timestamp_solicitacao': agora,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Verifica todos os contatos com exclusão pendente e remove
  /// definitivamente aqueles cujo prazo de segurança de 24 horas já
  /// tenha expirado desde a solicitação.
  Future<void> processarExclusoesPendentesExpiradas() async {
    final db = await database;
    const prazoSegurancaMs = 86400000; // 24 horas em milissegundos
    final agora = DateTime.now().millisecondsSinceEpoch;

    final pendentes = await db.query(
      'contatos_emergencia',
      where: 'exclusao_pendente = 1',
    );

    for (final contato in pendentes) {
      final timestampStr = contato['timestamp_solicitacao'] as String?;
      final timestampSolicitacao = timestampStr != null ? int.tryParse(timestampStr) : null;
      if (timestampSolicitacao == null) continue;

      if (agora - timestampSolicitacao >= prazoSegurancaMs) {
        final id = contato['id'] as int;
        await db.delete('contatos_emergencia', where: 'id = ?', whereArgs: [id]);
      }
    }
  }

  // ====================
  // HISTORICO METHODS
  // ====================
  // Tabela 'historico' usada para registrar eventos administrativos do
  // aplicativo nas categorias 'seguranca', 'familia' e 'sistema', todos
  // exibidos de forma transparente na aba Histórico.

  /// Insere um novo evento no histórico. [categoria] deve ser uma das
  /// strings: 'seguranca', 'familia', 'sistema' ou 'critico'.
  ///
  /// IMPORTANTE — separação de privacidade: a categoria 'critico' é
  /// EXCLUSIVA para os alarmes de emergência e disparos de SMS de socorro
  /// (o registro mais sensível do aplicativo). Ela NUNCA deve aparecer na
  /// tela de Histórico Geral (ver [getHistorico]), sendo retornada apenas
  /// por [getEventosSensiveis], usada pela tela de Auditoria de Eventos
  /// Sensíveis, protegida pela trava de segurança de 3 horas.
  Future<int> inserirEventoHistorico({
    required String titulo,
    required String descricao,
    required String categoria,
  }) async {
    final db = await database;
    return await db.insert('historico', {
      'titulo': titulo,
      'descricao': descricao,
      'categoria': categoria,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Retorna os eventos do histórico exibidos na tela de Histórico Geral
  /// (abas Todos/Segurança/Família/Sistema), ordenados do mais recente
  /// para o mais antigo.
  ///
  /// Regra de negócio de privacidade/blindagem: os registros da categoria
  /// 'critico' (alarmes de emergência e disparos de SMS de socorro) são
  /// EXCLUÍDOS explicitamente desta consulta, independentemente de
  /// qualquer status de liberação da Auditoria. Esses eventos só podem
  /// ser vistos dentro do cofre de Auditoria de Eventos Sensíveis (ver
  /// [getEventosSensiveis]), nunca aqui.
  Future<List<Map<String, dynamic>>> getHistorico() async {
    final db = await database;
    return await db.query(
      'historico',
      where: 'categoria != ?',
      whereArgs: ['critico'],
      orderBy: 'id DESC',
    );
  }

  /// Retorna somente os eventos do histórico da categoria 'critico', que
  /// são os registros mais críticos/sensíveis do aplicativo (alarmes de
  /// emergência e disparos de SMS de socorro para os contatos
  /// cadastrados). Usados exclusivamente pela tela de Auditoria de
  /// Eventos Sensíveis, que só libera essa visualização após a trava de
  /// segurança de 3 horas.
  Future<List<Map<String, dynamic>>> getEventosSensiveis() async {
    final db = await database;
    return await db.query(
      'historico',
      where: 'categoria = ?',
      whereArgs: ['critico'],
      orderBy: 'id DESC',
    );
  }


  /// Remove um único evento do histórico pelo id. Usado pelo gesto de
  /// "arrastar para excluir" (Dismissible) na aba Histórico.
  Future<int> deletarEventoHistorico(int id) async {
    final db = await database;
    return await db.delete('historico', where: 'id = ?', whereArgs: [id]);
  }

  // ==========================================
  // AUDITORIA DE EVENTOS SENSÍVEIS (trava 3h)
  // ==========================================
  // Recurso de proteção de dados que exige uma solicitação explícita do
  // usuário e um período de carência de 3 horas antes de liberar a
  // visualização dos eventos mais sensíveis (categoria 'seguranca'),
  // evitando acessos rápidos e não autorizados a esses registros caso o
  // dispositivo seja acessado por terceiros.

  static const int prazoAuditoriaMs = 2 * 60 * 60 * 1000; // 2 horas

  /// Registra o timestamp atual como o momento da solicitação de
  /// liberação da auditoria sensível, e já marca a sessão atual como
  /// tendo uma solicitação pendente (a liberação efetiva do CONTEÚDO só
  /// ocorre quando as 3h se cumprirem, verificado em [getStatusAuditoria]).
  Future<void> solicitarLiberacaoAuditoria() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    final agora = DateTime.now().millisecondsSinceEpoch.toString();
    await updateUserConfig({
      'id': id,
      'timestamp_solicitacao_auditoria': agora,
      'auditoria_liberada_sessao': 0,
    });
  }

  /// Verifica o estado atual da trava de auditoria, retornando um mapa
  /// com:
  /// - 'liberado': true se os registros sensíveis podem ser exibidos.
  /// - 'msRestantes': quanto falta (em ms) para a liberação, se ainda
  ///   houver uma solicitação pendente dentro do prazo de carência.
  /// - 'temSolicitacaoPendente': true se existe uma solicitação em
  ///   andamento (independente de já ter sido liberada ou não).
  ///
  /// Caso as 3h já tenham decorrido desde a solicitação, marca
  /// automaticamente 'auditoria_liberada_sessao' = 1 no banco, liberando
  /// a visualização para a sessão atual do app.
  Future<Map<String, dynamic>> getStatusAuditoria() async {
    final config = await getUserConfig();
    if (config == null) {
      return {
        'liberado': false,
        'msRestantes': prazoAuditoriaMs,
        'temSolicitacaoPendente': false,
      };
    }

    final timestampStr = config['timestamp_solicitacao_auditoria'] as String?;
    final jaLiberadaNaSessao = (config['auditoria_liberada_sessao'] as int?) == 1;

    if (timestampStr == null) {
      return {
        'liberado': false,
        'msRestantes': prazoAuditoriaMs,
        'temSolicitacaoPendente': false,
      };
    }

    final timestampSolicitacao = int.tryParse(timestampStr);
    if (timestampSolicitacao == null) {
      return {
        'liberado': false,
        'msRestantes': prazoAuditoriaMs,
        'temSolicitacaoPendente': false,
      };
    }

    final agora = DateTime.now().millisecondsSinceEpoch;
    final decorrido = agora - timestampSolicitacao;

    if (decorrido >= prazoAuditoriaMs) {
      // Prazo de segurança cumprido: libera a visualização para a
      // sessão atual (persistido, mas será resetado no próximo cold
      // start do app, em main.dart).
      if (!jaLiberadaNaSessao) {
        final id = config['id'] as int;
        await updateUserConfig({'id': id, 'auditoria_liberada_sessao': 1});
      }
      return {
        'liberado': true,
        'msRestantes': 0,
        'temSolicitacaoPendente': true,
      };
    }

    return {
      'liberado': false,
      'msRestantes': prazoAuditoriaMs - decorrido,
      'temSolicitacaoPendente': true,
    };
  }

  /// Deve ser chamado uma única vez, logo na inicialização do app (cold
  /// start), para resetar a flag 'auditoria_liberada_sessao'. Isso
  /// garante que, assim que o aplicativo for totalmente fechado e
  /// reaberto, o estado de liberação seja sempre resetado — exigindo que
  /// a trava de 2h seja reavaliada (embora, se o prazo já tiver sido
  /// cumprido anteriormente, a tela libere novamente de forma automática
  /// ao ser reaberta, sem exigir nova solicitação).
  Future<void> resetarSessaoAuditoria() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'auditoria_liberada_sessao': 0});
  }

  /// Bloqueia novamente o acesso aos registros sensíveis, acionado pelo
  /// botão "Bloquear Novamente" na tela de Auditoria de Eventos
  /// Sensíveis já liberada. Reseta tanto a flag de liberação da sessão
  /// quanto o timestamp da solicitação original, exigindo uma NOVA
  /// solicitação e uma NOVA espera de 2h para o próximo acesso.
  Future<void> bloquearAuditoriaNovamente() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'auditoria_liberada_sessao': 0,
      'timestamp_solicitacao_auditoria': null,
    });
  }


  // ==========================================
  // ALARMES DE ROTINA (Gerenciador estilo despertador)
  // ==========================================
  // Tabela 'alarmes_rotina', usada pela aba Família para gerenciar
  // múltiplos alarmes de rotina/check-in, no estilo do despertador do
  // iPhone. Cada alarme possui hora, minuto, dias da semana de repetição
  // (string CSV, ex: "1,3,5", onde 1=Segunda ... 7=Domingo), um estado
  // ativo/inativo (alternável rapidamente via switch) e uma etiqueta
  // livre descrevendo o propósito do alarme (ex: "Chegada no trabalho").

  /// Insere um novo alarme de rotina. Retorna o id gerado.
  Future<int> inserirAlarme(Map<String, dynamic> alarme) async {
    final db = await database;
    return await db.insert('alarmes_rotina', alarme);
  }

  /// Retorna todos os alarmes de rotina cadastrados, ordenados por
  /// horário (hora e minuto) para facilitar a visualização cronológica.
  Future<List<Map<String, dynamic>>> listarAlarmes() async {
    final db = await database;
    return await db.query('alarmes_rotina', orderBy: 'hora ASC, minuto ASC');
  }

  /// Atualiza os dados de um alarme de rotina já existente (hora, minuto,
  /// dias da semana, etiqueta e/ou estado ativo). O mapa [alarme] deve
  /// conter obrigatoriamente a chave 'id'.
  Future<int> atualizarAlarme(Map<String, dynamic> alarme) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      alarme,
      where: 'id = ?',
      whereArgs: [alarme['id']],
    );
  }

  /// Alterna rapidamente o estado ativo/inativo de um alarme (usado pelo
  /// SwitchListTile na listagem da aba Família), sem precisar reenviar os
  /// demais campos do alarme.
  Future<int> alternarAtivoAlarme(int id, bool ativo) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      {'ativo': ativo ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Remove definitivamente um alarme de rotina pelo id.
  Future<int> deletarAlarme(int id) async {
    final db = await database;
    return await db.delete('alarmes_rotina', where: 'id = ?', whereArgs: [id]);
  }

  /// Busca um único alarme de rotina pelo id. Usado pelo callback headless
  /// do [RotinaAlarmeService] (Etapa 3), que roda em um isolate/engine
  /// separado e recebe apenas o id do alarme como parâmetro, precisando
  /// consultar o restante dos dados (contexto, tolerância etc.) no SQLite.
  Future<Map<String, dynamic>?> buscarAlarmePorId(int id) async {
    final db = await database;
    final result = await db.query('alarmes_rotina', where: 'id = ?', whereArgs: [id], limit: 1);
    return result.isNotEmpty ? result.first : null;
  }

  /// Atualiza apenas o timestamp (epoch ms) do último disparo NATIVO já
  /// processado para este alarme de rotina, usado para fins de
  /// auditoria/depuração pelo [RotinaAlarmeService].
  Future<int> marcarUltimoDisparo(int id, int epoch) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      {'ultimo_disparo_epoch': epoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marca/desmarca o alarme de rotina [id] como "pausado"
  /// (`alarme_pausado`), acionado pelo botão "Pausar Alarme"/"Alarme
  /// Pausado" (ver [RotinaAlarmeService.pausarAlarme] e a aba Família).
  /// Quando pausado, o alarme permanece cadastrado (não é excluído),
  /// mas o próximo disparo é ignorado pelo callback headless.
  Future<int> definirAlarmePausado(int id, bool pausado) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      {'alarme_pausado': pausado ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }



  // ==========================================================
  // [TEMPORÁRIO/DEBUG] RESET MANUAL DE SENHA PARA TESTES FÍSICOS
  // ==========================================================
  // ATENÇÃO: Função exclusiva para uso durante testes de desenvolvimento.
  // Executa um UPDATE direto na tabela 'user_config', limpando os campos
  // 'pin_real', 'senha_pendente' e 'timestamp_alteracao_senha', forçando
  // o aplicativo a voltar ao estado de "Primeiro Acesso" (sem PIN
  // cadastrado), permitindo cadastrar uma nova senha instantaneamente,
  // sem a carência de 24h. REMOVER antes de qualquer build de produção.
  Future<void> debugResetarSenhaParaPrimeiroAcesso() async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE user_config
      SET pin_real = NULL,
          senha_pendente = NULL,
          timestamp_alteracao_senha = NULL
    ''');
  }

  // ==========================================================
  // DISPARO DE EMERGÊNCIA VIA ALARME NATIVO (background/headless)
  // ==========================================================
  // Conjunto de métodos usados tanto pela UI (SegurancaTab) quanto pelo
  // callback headless do AlarmeService (que roda em um isolate/engine
  // separado, sem acesso a nenhum estado em memória do app principal).
  // Por isso TODO o contexto necessário para o disparo (contatos, dica de
  // contexto, PIN esperado etc.) precisa estar persistido em disco.

  /// Marca no banco que o cronômetro de check-in foi iniciado, salvando a
  /// dica de contexto digitada pelo usuário (usada para montar a mensagem
  /// de SMS) e o timestamp (epoch ms) em que o alarme nativo está
  /// agendado para disparar. Chamado pela SegurancaTab ao iniciar o
  /// cronômetro, IMEDIATAMENTE ANTES de agendar o alarme nativo via
  /// AlarmeService.
  Future<void> salvarContextoTimerAtivo({
    required String contexto,
    required DateTime timestampExpiracao,
  }) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'contexto_timer_ativo': contexto,
      'timestamp_expiracao_alarme':
          timestampExpiracao.millisecondsSinceEpoch.toString(),
    });
  }

  /// Marca no banco que um disparo de emergência JÁ OCORREU (o SMS já foi
  /// enviado pelo callback headless) e que o app deve exibir a tela de
  /// bloqueio de PIN assim que for reaberto, até que o PIN correto seja
  /// digitado. Chamado exclusivamente pelo callback estático headless do
  /// AlarmeService, portanto usa sua PRÓPRIA instância de banco (o
  /// singleton `database` é resolvido normalmente, pois cada isolate/
  /// engine abre sua própria conexão sqflite apontando para o mesmo
  /// arquivo físico do banco).
  Future<void> marcarAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'aguardando_confirmacao_pin': 1,
    });
  }

  /// Limpa a flag de bloqueio, chamada quando o usuário digita o PIN
  /// correto na TelaBloqueioPin (tanto no cenário de tolerância com o app
  /// aberto quanto no cenário de cold start pós-disparo em background).
  Future<void> limparAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'aguardando_confirmacao_pin': 0,
      'contexto_timer_ativo': null,
      'timestamp_expiracao_alarme': null,
    });
  }

  /// Verifica se o app deve exibir a tela de bloqueio de PIN assim que for
  /// aberto (cold start), usado por main.dart/HomeScreen.
  Future<bool> isAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return false;
    return (config['aguardando_confirmacao_pin'] as int?) == 1;
  }

  // ==========================================================
  // ALERTA SONORO CUSTOMIZÁVEL (Etapa 1 - Expansão Global)
  // ==========================================================
  // Persistência das escolhas de som (1 a 10) e duração (segundos) do
  // alerta sonoro disparado ao término do cronômetro de check-in. Estes
  // métodos espelham/complementam a persistência feita via
  // SharedPreferences pelo AlarmeSonoroService, mantendo também um
  // registro no SQLite (user_config) para consistência com o restante
  // das preferências do usuário.

  Future<void> salvarSomAlarmeSelecionado(int numeroSom) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'som_alarme_selecionado': numeroSom});
  }

  Future<void> salvarDuracaoSomAlarme(int segundos) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'duracao_som_alarme': segundos});
  }

  // ==========================================================
  // IDIOMA SELECIONADO (Etapa 2 - Internacionalização)
  // ==========================================================
  // Persiste o código do idioma escolhido pelo usuário (ver
  // lib/services/localization_service.dart para a lista completa dos 11
  // idiomas globais suportados).

  Future<void> salvarIdiomaSelecionado(String codigoIdioma) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'idioma_selecionado': codigoIdioma});
  }
}


