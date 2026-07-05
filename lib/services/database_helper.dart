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
      version: 6,
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
        pin_coacao TEXT,
        tempo_padrao_timer INTEGER,
        forcando_whatsapp INTEGER NOT NULL DEFAULT 0,
        tipo_plano TEXT NOT NULL DEFAULT 'free',
        plano_de_fundo_url TEXT,
        senha_pendente TEXT,
        timestamp_alteracao_senha TEXT
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
  /// strings: 'seguranca', 'familia' ou 'sistema'.
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

  /// Retorna todos os eventos do histórico, ordenados do mais recente
  /// para o mais antigo. Usado pela aba Histórico.
  Future<List<Map<String, dynamic>>> getHistorico() async {
    final db = await database;
    return await db.query('historico', orderBy: 'id DESC');
  }

  /// Remove um único evento do histórico pelo id. Usado pelo gesto de
  /// "arrastar para excluir" (Dismissible) na aba Histórico.
  Future<int> deletarEventoHistorico(int id) async {
    final db = await database;
    return await db.delete('historico', where: 'id = ?', whereArgs: [id]);
  }
}



