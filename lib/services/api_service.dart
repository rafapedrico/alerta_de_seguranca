import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Serviço centralizado de comunicação com o Backend FastAPI
/// (security_backend), responsável por:
/// - Testar a conectividade entre o app e o servidor (heartbeat).
/// - Persistir remotamente os horários de rotina e tolerância cadastrados
///   na aba Família.
/// - Disparar o alerta máximo em tempo real para o servidor (em paralelo
///   ao SMS nativo já disparado pelo [EmergencyAlertService]), enviando
///   latitude, longitude e o contexto do alerta.
///
/// IMPORTANTE: A [baseUrl] aponta para o IP local da máquina rodando o
/// servidor Uvicorn/FastAPI na mesma rede Wi-Fi do celular. Em ambiente de
/// produção, esse valor deve ser substituído pelo domínio público real do
/// backend hospedado (ex: Render, Railway, AWS, etc.).
///
/// Todas as chamadas são protegidas por try/catch e NUNCA lançam exceção
/// para quem as invoca — falhas de rede são apenas registradas via
/// [debugPrint], garantindo que a ausência de conectividade com o backend
/// jamais interrompa o fluxo crítico de segurança do app (SMS nativo,
/// alarmes locais, etc.), que continua funcionando de forma 100%
/// independente do servidor.
class ApiService {
  ApiService._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
      ),
    );
  }

  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  /// URL base do backend FastAPI (rede local Wi-Fi).
  /// Ajuste este valor caso o IP da máquina que roda o servidor mude.
  /// (Atualizado em 08/07: o IP da máquina de desenvolvimento mudou de
  /// 192.168.15.10 para 192.168.15.7 — mantenha este valor sempre em
  /// sincronia com o IP local atual exibido por `ipconfig`/`ifconfig`.)
  static const String baseUrl = 'http://192.168.15.7:8000';

  /// Identificador do usuário/dispositivo usado em todas as requisições
  /// enquanto o app não possui autenticação real (Firebase Auth, etc.).
  /// TODO: substituir por um identificador único e persistente por
  /// instalação (ex: UUID salvo no SharedPreferences) assim que o fluxo
  /// de autenticação/multiusuário for implementado.
  static const String usuarioIdPadrao = 'usuario_dev_teste';

  late final Dio _dio;

  /// Envia um "heartbeat" para `/api/status`, testando a conectividade
  /// entre o app e o servidor. Retorna `true` se o servidor respondeu
  /// com sucesso (HTTP 200), ou `false` em qualquer outro caso (timeout,
  /// servidor fora do ar, sem rede, etc.).
  Future<bool> enviarStatus(double bateria, String versao) async {
    try {
      final response = await _dio.post(
        '/api/status',
        data: {
          'usuario_id': usuarioIdPadrao,
          'app_versao': versao,
          'bateria_percentual': bateria.round(),
        },
      );
      debugPrint('✅ [ApiService] /api/status respondeu: ${response.data}');
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('⚠️ [ApiService] Falha ao conectar em /api/status: $e');
      return false;
    }
  }

  /// Envia (persiste remotamente) um alarme de rotina de check-in para
  /// `/api/rotinas`, refletindo fielmente o modelo real do app
  /// (AlarmeRotina): um único horário + tolerância em minutos. Retorna
  /// `true` em caso de sucesso (HTTP 201), ou `false` em qualquer falha
  /// de rede.
  ///
  /// [horario] deve estar no formato "HH:mm:ss".
  Future<bool> salvarRotina({
    required String horario,
    required int toleranciaMinutos,
    int? alarmeId,
    String? etiqueta,
    String? contextoPersonalizado,
    List<String>? diasSemana,
    bool ativo = true,
  }) async {
    try {
      final response = await _dio.post(
        '/api/rotinas',
        data: {
          'usuario_id': usuarioIdPadrao,
          if (alarmeId != null) 'alarme_id': alarmeId,
          'horario': horario,
          'tolerancia_minutos': toleranciaMinutos,
          if (etiqueta != null) 'etiqueta': etiqueta,
          if (contextoPersonalizado != null)
            'contexto_personalizado': contextoPersonalizado,
          if (diasSemana != null) 'dias_semana': diasSemana,
          'ativo': ativo,
        },
      );
      debugPrint('✅ [ApiService] /api/rotinas respondeu: ${response.data}');
      return response.statusCode == 201;
    } catch (e) {
      debugPrint('⚠️ [ApiService] Falha ao conectar em /api/rotinas: $e');
      return false;
    }
  }

  /// Dispara o alerta máximo em tempo real para o backend, em
  /// `/api/alerta`, enviando a localização atual (latitude/longitude) e o
  /// contexto do evento. Deve ser chamado em paralelo ao disparo do SMS
  /// nativo (ver [EmergencyAlertService.dispararAlertaDeEmergencia]).
  ///
  /// Retorna `true` em caso de sucesso (HTTP 200), ou `false` em qualquer
  /// falha de rede — nunca lança exceção.
  ///
  /// [timestampLocal] deve conter a data/hora EXATA (horas, minutos e
  /// segundos locais do aparelho) do momento em que o disparo foi
  /// originado — usada tanto pelo SOS padrão (manual ou automático via
  /// cronômetro) quanto pelo SOS de coação (PIN incorreto 2x seguidas).
  /// Se omitido, usa o horário local atual no instante da chamada.
  Future<bool> dispararAlertaWeb({
    required double latitude,
    required double longitude,
    required String contexto,
    DateTime? timestampLocal,
  }) async {
    try {
      final momento = timestampLocal ?? DateTime.now();
      final response = await _dio.post(
        '/api/alerta',
        data: {
          'usuario_id': usuarioIdPadrao,
          'latitude': latitude,
          'longitude': longitude,
          'contexto': contexto,
          'timestamp': momento.toUtc().toIso8601String(),
          // Campo adicional com a hora EXATA local (horas:minutos:segundos)
          // do disparo, em formato legível, para exibição/registro direto
          // no backend sem depender de conversão de fuso horário.
          'timestamp_local': _formatarTimestampLocal(momento),
        },
      );

      debugPrint('🚨 [ApiService] /api/alerta respondeu: ${response.data}');
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('⚠️ [ApiService] Falha ao conectar em /api/alerta: $e');
      return false;
    }
  }

  /// Formata um [DateTime] LOCAL no padrão "dd/MM/yyyy HH:mm:ss",
  /// contendo horas, minutos e segundos exatos do disparo, para ser
  /// enviado como campo auxiliar legível ao backend (ver
  /// [dispararAlertaWeb]).
  String _formatarTimestampLocal(DateTime momento) {
    String doisDigitos(int valor) => valor.toString().padLeft(2, '0');
    return '${doisDigitos(momento.day)}/${doisDigitos(momento.month)}/${momento.year} '
        '${doisDigitos(momento.hour)}:${doisDigitos(momento.minute)}:${doisDigitos(momento.second)}';
  }
}

