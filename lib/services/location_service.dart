import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Serviço centralizado de geolocalização proativa.
///
/// Estratégia adotada (definida junto com o time de segurança):
///
/// 1. Permissão ao iniciar: assim que a tela de Segurança é aberta, o app
///    verifica e solicita a permissão de localização do Android
///    ('While in Use'), garantindo que o GPS esteja liberado antes mesmo
///    de o usuário precisar ativar o cronômetro.
///
/// 2. Captura proativa (warm-up): no exato instante em que o cronômetro de
///    check-in é iniciado, uma localização de alta precisão é buscada
///    IMEDIATAMENTE em segundo plano e guardada em memória como a
///    "Localização Atualizada".
///
/// 3. Loop de atualização: enquanto o cronômetro estiver ativo, a cada
///    2 minutos uma nova localização é obtida e SUBSTITUI a anterior em
///    memória — mantendo sempre apenas o registro mais recente do
///    aparelho, sem acumular histórico.
///
/// 4. Envio do alerta: no momento do disparo de emergência, o SMS usa
///    imediatamente essa última localização salva em memória por este
///    fluxo proativo, sem depender de uma nova consulta (lenta) ao GPS
///    no momento crítico.
class LocationService {
  LocationService._internal();
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;

  /// Intervalo entre atualizações automáticas de localização enquanto o
  /// cronômetro de check-in estiver ativo.
  static const Duration intervaloAtualizacao = Duration(minutes: 2);

  /// Última posição capturada em memória (a "Localização Atualizada").
  /// É sempre sobrescrita: nunca mantemos histórico, apenas o registro
  /// mais recente do aparelho.
  Position? _ultimaPosicao;

  Timer? _timerAtualizacao;

  Position? get ultimaPosicao => _ultimaPosicao;

  /// Verifica e solicita a permissão de localização ('While in Use') junto
  /// ao sistema operacional Android. Deve ser chamado assim que a tela de
  /// Segurança for aberta (ou na inicialização do app), garantindo que o
  /// GPS esteja liberado antes do usuário precisar ativar o cronômetro.
  ///
  /// Retorna `true` se a permissão foi concedida (When in Use ou Always),
  /// `false` caso contrário.
  Future<bool> garantirPermissaoDeLocalizacao() async {
    try {
      final bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) {
        debugPrint('📍 Serviço de localização (GPS) está desativado no aparelho.');
        return false;
      }

      LocationPermission permissao = await Geolocator.checkPermission();

      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }

      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        debugPrint('📍 Permissão de localização negada pelo usuário.');
        return false;
      }

      // permissao concedida: whileInUse ou always.
      return true;
    } catch (e) {
      debugPrint('⚠️ Falha ao solicitar permissão de localização: $e');
      return false;
    }
  }

  /// Busca a localização atual com alta precisão e guarda em memória,
  /// substituindo qualquer registro anterior (regra de descarte).
  ///
  /// Usado tanto no "warm-up" (ao iniciar o cronômetro) quanto em cada
  /// ciclo do loop de atualização periódica.
  Future<Position?> capturarLocalizacaoAtual() async {
    try {
      final bool temPermissao = await garantirPermissaoDeLocalizacao();
      if (!temPermissao) return _ultimaPosicao;

      final posicao = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      // Regra de descarte: sempre substitui a posição anterior pela mais
      // recente, mantendo em memória apenas o último registro do aparelho.
      _ultimaPosicao = posicao;
      debugPrint(
          '📍 Localização atualizada em memória: ${posicao.latitude}, ${posicao.longitude}');
      return _ultimaPosicao;
    } catch (e) {
      debugPrint('⚠️ Falha ao capturar localização atual: $e');
      // Mantém a última posição válida conhecida em memória (se existir),
      // para que o fluxo de emergência ainda tenha uma coordenada útil.
      return _ultimaPosicao;
    }
  }

  /// Inicia o ciclo de vida do GPS atrelado ao cronômetro de check-in:
  ///
  /// 1. Faz o "warm-up": busca a localização atual imediatamente.
  /// 2. Agenda um Timer.periodic para repetir a captura a cada 2 minutos
  ///    enquanto o cronômetro estiver ativo.
  ///
  /// Deve ser chamado no exato momento em que o usuário clica em
  /// "Iniciar Cronômetro".
  Future<void> iniciarCicloDeAtualizacao() async {
    // Cancela qualquer ciclo anterior ainda em execução, por segurança.
    pararCicloDeAtualizacao();

    // Passo 2 (Warm-up): busca IMEDIATA da localização precisa, em
    // segundo plano, no exato momento em que o cronômetro é iniciado.
    await capturarLocalizacaoAtual();

    // Passo 3: loop de atualização a cada 2 minutos enquanto o cronômetro
    // permanecer ativo.
    _timerAtualizacao = Timer.periodic(intervaloAtualizacao, (timer) async {
      await capturarLocalizacaoAtual();
    });
  }

  /// Interrompe o ciclo de atualização periódica de localização. Deve ser
  /// chamado sempre que o cronômetro for parado/desarmado (com sucesso ou
  /// por disparo de emergência).
  void pararCicloDeAtualizacao() {
    _timerAtualizacao?.cancel();
    _timerAtualizacao = null;
  }

  /// Limpa a última localização guardada em memória. Opcionalmente pode
  /// ser chamado após o envio do alerta de emergência, para não reutilizar
  /// coordenadas antigas em um próximo ciclo de check-in.
  void limparLocalizacao() {
    _ultimaPosicao = null;
  }

  /// Formata a última posição conhecida em memória em texto legível
  /// (latitude/longitude + link clássico do Google Maps) para ser
  /// inserido no corpo do SMS de emergência.
  ///
  /// Caso não exista nenhuma posição em memória (fluxo proativo nunca
  /// rodou ou falhou completamente), tenta como último recurso obter a
  /// última localização conhecida do aparelho (cache do sistema) antes de
  /// desistir.
  Future<String> obterLocalizacaoFormatadaParaAlerta() async {
    Position? posicao = _ultimaPosicao;

    if (posicao == null) {
      try {
        posicao = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }

    if (posicao == null) {
      return 'Não foi possível obter a localização atual do aparelho.';
    }

    return _formatarPosicao(posicao);
  }

  String _formatarPosicao(Position posicao) {
    return 'Latitude: ${posicao.latitude}, Longitude: ${posicao.longitude} '
        '(https://maps.google.com/?q=${posicao.latitude},${posicao.longitude})';
  }
}
