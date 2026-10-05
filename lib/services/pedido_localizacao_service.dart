import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'firebase_auth_service.dart';
import 'rastreamento_continuo_service.dart';

/// Resposta ao push SILENCIOSO `pedido_localizacao` (callable
/// `pedirLocalizacaoAtual`, ver `functions/localizacaoContinuaService.js`
/// no repositório do servidor): quem monitora tocou em "Ver no mapa" e o
/// servidor pediu a posição ATUAL deste aparelho (o alvo).
///
/// Lê o GPS UMA vez e grava em `usuarios/{meuUid}/monitoramento/atual`
/// (merge) os MESMOS campos que o app iOS grava e lê — `latitude`,
/// `longitude`, `precisao`, `atualizadoEm`, `origem`,
/// `rastreamentoContinuo`, mais `plataforma: "android"`. Com o
/// rastreamento contínuo DESLIGADO grava `rastreamentoContinuo: false` (o
/// aparelho fica fora da varredura `detectarLocalizacaoParada` do
/// servidor); ligado, `true` — o mesmo valor que o serviço contínuo grava
/// (ver `RastreamentoContinuo.kt`). NUNCA exibe notificação: roda inteiro
/// dentro do handler do FCM, com o app aberto, em segundo plano ou fechado.
///
/// Sem posição nova (GPS desligado, sem permissão "Permitir o tempo
/// todo" com o app fechado, timeout) não grava nada — o app de quem pediu
/// cai sozinho na última posição conhecida, depois de ~20 s.
class PedidoLocalizacaoService {
  PedidoLocalizacaoService._();

  static const String tipoPush = 'pedido_localizacao';

  /// Evita duas leituras de GPS simultâneas no mesmo isolate (reentrega
  /// do FCM ou dois pedidos em sequência).
  static bool _emAndamento = false;

  static Future<void> responderPedido(Map<String, dynamic> data) async {
    if (_emAndamento) return;
    _emAndamento = true;
    try {
      // Isolate de background recém-criado: a sessão persistida pode ainda
      // estar sendo restaurada, e o token precisa estar pronto antes da
      // primeira escrita (ver [FirebaseAuthService.garantirTokenPronto]).
      final uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid == null) {
        debugPrint('📍 [PedidoLocalizacao] Sem sessão — pedido ignorado.');
        return;
      }

      final posicao = await _lerGpsUmaVez();
      if (posicao == null) return;

      final continuo = await RastreamentoContinuoService.ativoNoAparelho();
      await FirebaseAuthService().garantirTokenPronto();
      await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .collection('monitoramento')
          .doc('atual')
          .set({
        'latitude': posicao.latitude,
        'longitude': posicao.longitude,
        'precisao': posicao.accuracy,
        'atualizadoEm': FieldValue.serverTimestamp(),
        'origem': 'pedido',
        'plataforma': 'android',
        'rastreamentoContinuo': continuo,
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 10));
      debugPrint('📍 [PedidoLocalizacao] Posição atual enviada '
          '(origem do push: ${data['origem']}).');
    } catch (e) {
      debugPrint('⚠️ [PedidoLocalizacao] Falha ao responder pedido de localização: $e');
    } finally {
      _emAndamento = false;
    }
  }

  /// Só CONFERE a permissão — nunca pede (não há tela no isolate de
  /// background) — e não usa posição em cache: a resposta tem de ser a
  /// posição de agora.
  static Future<Position?> _lerGpsUmaVez() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('📍 [PedidoLocalizacao] GPS desligado — pedido ignorado.');
        return null;
      }
      final permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        debugPrint('📍 [PedidoLocalizacao] Sem permissão de localização — pedido ignorado.');
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (e) {
      debugPrint('⚠️ [PedidoLocalizacao] Falha ao ler o GPS: $e');
      return null;
    }
  }
}
