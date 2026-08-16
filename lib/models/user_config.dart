class UserConfig {
  final int? id;
  final String? pinReal;
  final int? tempoPadraoTimer;
  final String tipoPlano;
  final String? planoDeFundoUrl;
  final String? senhaPendente;
  final String? timestampAlteracaoSenha;
  final bool aguardandoConfirmacaoPin;
  final String? contextoTimerAtivo;
  final String? timestampExpiracaoAlarme;
  final bool confirmacaoTatilAtiva;

  UserConfig({
    this.id,
    this.pinReal,
    this.tempoPadraoTimer,
    this.tipoPlano = 'free',
    this.planoDeFundoUrl,
    this.senhaPendente,
    this.timestampAlteracaoSenha,
    this.aguardandoConfirmacaoPin = false,
    this.contextoTimerAtivo,
    this.timestampExpiracaoAlarme,
    this.confirmacaoTatilAtiva = true,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'pin_real': pinReal,
        'tempo_padrao_timer': tempoPadraoTimer,
        'tipo_plano': tipoPlano,
        'plano_de_fundo_url': planoDeFundoUrl,
        'senha_pendente': senhaPendente,
        'timestamp_alteracao_senha': timestampAlteracaoSenha,
        'aguardando_confirmacao_pin': aguardandoConfirmacaoPin ? 1 : 0,
        'contexto_timer_ativo': contextoTimerAtivo,
        'timestamp_expiracao_alarme': timestampExpiracaoAlarme,
        'confirmacao_tatil_ativa': confirmacaoTatilAtiva ? 1 : 0,
      };

  factory UserConfig.fromMap(Map<String, dynamic> map) => UserConfig(
        id: map['id'] as int?,
        pinReal: map['pin_real'] as String?,
        tempoPadraoTimer: map['tempo_padrao_timer'] as int?,
        tipoPlano: map['tipo_plano'] as String? ?? 'free',
        planoDeFundoUrl: map['plano_de_fundo_url'] as String?,
        senhaPendente: map['senha_pendente'] as String?,
        timestampAlteracaoSenha: map['timestamp_alteracao_senha'] as String?,
        aguardandoConfirmacaoPin:
            (map['aguardando_confirmacao_pin'] as int?) == 1,
        contextoTimerAtivo: map['contexto_timer_ativo'] as String?,
        timestampExpiracaoAlarme: map['timestamp_expiracao_alarme'] as String?,
        confirmacaoTatilAtiva: (map['confirmacao_tatil_ativa'] as int?) == 1,
      );
}
