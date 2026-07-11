import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';

/// Serviço responsável por controlar os limites mensais do Plano
/// Gratuito do aplicativo:
/// - 5 alertas de emergência por mês.
/// - 2 fotos (recurso de Captura e Dissuasão) por mês.
///
/// Os contadores são persistidos localmente via [SharedPreferences] (e
/// não no SQLite), por serem valores voláteis/reiniciáveis mensalmente,
/// sem necessidade de histórico/auditoria. O tipo de plano do usuário
/// ('free' ou pago) continua sendo lido do SQLite (`user_config.tipo_plano`,
/// ver [DatabaseHelper]), único ponto de verdade para essa informação.
///
/// Todos os métodos são protegidos por try/catch e NUNCA lançam exceção:
/// em caso de qualquer falha inesperada ao ler/gravar as preferências,
/// o serviço prefere ser permissivo (permitir a ação) a travar o fluxo
/// crítico de segurança do app.
class PlanoLimiteService {
  PlanoLimiteService._internal();
  static final PlanoLimiteService _instance = PlanoLimiteService._internal();
  factory PlanoLimiteService() => _instance;

  static const String _chaveAlertasUsados = 'plano_alertas_usados_mes';
  static const String _chaveFotosUsadas = 'plano_fotos_usadas_mes';
  static const String _chaveMesReferencia = 'plano_mes_referencia';

  /// Limite mensal de alertas de emergência do Plano Gratuito.
  // TODO(REVERTER ANTES DE PRODUÇÃO): valor temporariamente elevado para
  // 999 apenas para permitir testes físicos livres da tela de
  // dissuasão/botão "X". O valor de produção correto é 5.
  static const int limiteAlertasGratuito = 999;

  /// Limite mensal de fotos (Captura e Dissuasão) do Plano Gratuito.
  // TODO(REVERTER ANTES DE PRODUÇÃO): valor temporariamente elevado para
  // 999 apenas para permitir testes físicos livres da tela de
  // dissuasão/botão "X". O valor de produção correto é 2.
  static const int limiteFotosGratuito = 999;


  final DatabaseHelper _db = DatabaseHelper();

  /// Retorna a chave do mês corrente no formato "yyyy-MM", usada para
  /// detectar a virada de mês e resetar os contadores automaticamente.
  String _mesAtualFormatado() {
    final agora = DateTime.now();
    final mes = agora.month.toString().padLeft(2, '0');
    return '${agora.year}-$mes';
  }

  /// Deve ser chamado uma única vez, no boot do app (main.dart), para
  /// garantir que os contadores já estejam consistentes com o mês atual
  /// antes de qualquer verificação/incremento.
  Future<void> inicializar() async {
    await _garantirMesAtualizado();
  }

  /// Verifica se o mês salvo em disco ainda é o mês corrente. Se não for
  /// (ou se nunca foi salvo antes), zera os dois contadores e persiste o
  /// novo mês de referência.
  Future<void> _garantirMesAtualizado() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mesSalvo = prefs.getString(_chaveMesReferencia);
      final mesAtual = _mesAtualFormatado();

      if (mesSalvo != mesAtual) {
        await prefs.setString(_chaveMesReferencia, mesAtual);
        await prefs.setInt(_chaveAlertasUsados, 0);
        await prefs.setInt(_chaveFotosUsadas, 0);
        debugPrint(
            '📅 [PlanoLimiteService] Novo mês detectado ($mesAtual): contadores de alertas/fotos resetados.');
      }
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao verificar/atualizar o mês de referência: $e');
    }
  }

  /// Retorna `true` se o usuário possui um plano pago (qualquer valor de
  /// `tipo_plano` diferente de 'free'), isentando-o de qualquer limite.
  ///
  /// BLINDAGEM REFORÇADA: caso [DatabaseHelper.getUserConfig] retorne
  /// `null` (ex: nenhuma linha ainda criada em `user_config` — cenário
  /// comum logo após uma instalação limpa, antes do primeiro cadastro de
  /// PIN) ou qualquer outra falha de leitura ocorra, este método NUNCA
  /// deve ser a causa de um bloqueio no fluxo crítico de segurança. Por
  /// isso, tanto o caso `config == null` quanto qualquer exceção
  /// resultam explicitamente em `false` (tratado como Plano Gratuito),
  /// mas os métodos que efetivamente decidem se a ação é permitida
  /// ([podeDispararAlerta]/[podeTirarFoto]) SEMPRE preferem o caminho
  /// permissivo em caso de falha de leitura dos contadores em si (ver
  /// abaixo) — garantindo que uma configuração ausente/corrompida jamais
  /// impeça um alerta ou uma foto de emergência.
  Future<bool> _possuiPlanoPago() async {
    try {
      final config = await _db.getUserConfig();
      if (config == null) {
        // Nenhuma configuração cadastrada ainda: trata como Plano
        // Gratuito (não pago), mas isso por si só NÃO bloqueia nada —
        // apenas faz com que os contadores de limite passem a ser
        // verificados normalmente.
        debugPrint(
            'ℹ️ [PlanoLimiteService] Nenhum user_config encontrado ainda — tratando como Plano Gratuito, sem bloquear o fluxo.');
        return false;
      }
      final tipoPlano = (config['tipo_plano'] as String?) ?? 'free';
      return tipoPlano.trim().toLowerCase() != 'free';
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao consultar tipo de plano: $e');
      // Em caso de falha na leitura, assume-se o comportamento mais
      // restritivo (plano gratuito) SOMENTE para efeito de qual "regra"
      // se aplica — nunca bloqueia sozinho, pois quem decide o bloqueio
      // de fato são podeDispararAlerta()/podeTirarFoto() abaixo, que já
      // são 100% permissivos em qualquer cenário de falha.
      return false;
    }
  }


  // ==========================================================
  // ALERTAS DE EMERGÊNCIA (limite: 5/mês no Plano Gratuito)
  // ==========================================================

  /// Verifica se o usuário ainda pode disparar um novo alerta de
  /// emergência neste mês. Planos pagos sempre retornam `true`.
  Future<bool> podeDispararAlerta() async {
    await _garantirMesAtualizado();
    if (await _possuiPlanoPago()) {
      debugPrint('🚨 [PlanoLimiteService] Plano pago detectado — alerta sempre permitido.');
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final usados = prefs.getInt(_chaveAlertasUsados) ?? 0;
      final permitido = usados < limiteAlertasGratuito;
      debugPrint(
          '🚨 [PlanoLimiteService] podeDispararAlerta() -> usados=$usados / limite=$limiteAlertasGratuito / permitido=$permitido');
      return permitido;
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao verificar limite de alertas: $e — permitindo por padrão.');
      // Falha ao ler o contador: prefere-se permitir o disparo, já que
      // este é um recurso crítico de segurança e nunca deve ser bloqueado
      // por uma falha técnica no controle de limites.
      return true;
    }
  }


  /// Incrementa o contador de alertas de emergência usados neste mês.
  /// Chamado internamente pelo [EmergencyAlertService] logo após um
  /// disparo bem-sucedido. Planos pagos não incrementam o contador (não
  /// é necessário, já que nunca são bloqueados por ele).
  Future<void> incrementarAlertaUsado() async {
    if (await _possuiPlanoPago()) return;
    try {
      await _garantirMesAtualizado();
      final prefs = await SharedPreferences.getInstance();
      final usados = prefs.getInt(_chaveAlertasUsados) ?? 0;
      await prefs.setInt(_chaveAlertasUsados, usados + 1);
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao incrementar contador de alertas: $e');
    }
  }

  // ==========================================================
  // FOTOS (Captura e Dissuasão) (limite: 2/mês no Plano Gratuito)
  // ==========================================================

  /// Verifica se o usuário ainda pode tirar uma nova foto (Captura e
  /// Dissuasão) neste mês. Planos pagos sempre retornam `true`.
  ///
  /// BLINDAGEM PERMISSIVA: qualquer falha inesperada durante esta
  /// verificação (SharedPreferences indisponível, valor corrompido etc.)
  /// resulta em `true` — nunca travando a abertura da câmera por uma
  /// falha puramente técnica no controle de limites.
  Future<bool> podeTirarFoto() async {
    await _garantirMesAtualizado();
    if (await _possuiPlanoPago()) {
      debugPrint('📷 [PlanoLimiteService] Plano pago detectado — foto sempre permitida.');
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final usadas = prefs.getInt(_chaveFotosUsadas) ?? 0;
      final permitido = usadas < limiteFotosGratuito;
      debugPrint(
          '📷 [PlanoLimiteService] podeTirarFoto() -> usadas=$usadas / limite=$limiteFotosGratuito / permitido=$permitido');
      return permitido;
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao verificar limite de fotos: $e — permitindo por padrão.');
      return true;
    }
  }


  /// Incrementa o contador de fotos usadas neste mês. Chamado pela
  /// [CameraCapturaScreen] logo após a foto ser "tirada" (mesmo que não
  /// persistida em disco).
  Future<void> incrementarFotoUsada() async {
    if (await _possuiPlanoPago()) return;
    try {
      await _garantirMesAtualizado();
      final prefs = await SharedPreferences.getInstance();
      final usadas = prefs.getInt(_chaveFotosUsadas) ?? 0;
      await prefs.setInt(_chaveFotosUsadas, usadas + 1);
    } catch (e) {
      debugPrint('⚠️ [PlanoLimiteService] Falha ao incrementar contador de fotos: $e');
    }
  }
}
