class UserConfig {
  final int? id;
  final String? pinReal;
  final String? pinCoacao;
  final int? tempoPadraoTimer;
  final bool forcandoWhatsapp;
  final String tipoPlano;
  final String? planoDeFundoUrl;
  final String? senhaPendente;
  final String? timestampAlteracaoSenha;

  UserConfig({
    this.id,
    this.pinReal,
    this.pinCoacao,
    this.tempoPadraoTimer,
    this.forcandoWhatsapp = false,
    this.tipoPlano = 'free',
    this.planoDeFundoUrl,
    this.senhaPendente,
    this.timestampAlteracaoSenha,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'pin_real': pinReal,
        'pin_coacao': pinCoacao,
        'tempo_padrao_timer': tempoPadraoTimer,
        'forcando_whatsapp': forcandoWhatsapp ? 1 : 0,
        'tipo_plano': tipoPlano,
        'plano_de_fundo_url': planoDeFundoUrl,
        'senha_pendente': senhaPendente,
        'timestamp_alteracao_senha': timestampAlteracaoSenha,
      };

  factory UserConfig.fromMap(Map<String, dynamic> map) => UserConfig(
        id: map['id'] as int?,
        pinReal: map['pin_real'] as String?,
        pinCoacao: map['pin_coacao'] as String?,
        tempoPadraoTimer: map['tempo_padrao_timer'] as int?,
        forcandoWhatsapp: (map['forcando_whatsapp'] as int?) == 1,
        tipoPlano: map['tipo_plano'] as String? ?? 'free',
        planoDeFundoUrl: map['plano_de_fundo_url'] as String?,
        senhaPendente: map['senha_pendente'] as String?,
        timestampAlteracaoSenha: map['timestamp_alteracao_senha'] as String?,
      );
}
