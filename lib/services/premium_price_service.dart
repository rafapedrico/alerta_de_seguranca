import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'premium_purchase_service.dart';

/// Consulta o preço REAL do Plano Premium mensal diretamente da loja
/// (Google Play Billing / Apple App Store, conforme a plataforma) via
/// `in_app_purchase` — nunca um valor fixo no código. `ProductDetails.price`
/// já vem formatado pela própria loja, na moeda local da conta do
/// usuário (ex: "R$ 11,99", "$2.99", "€2.99"), então não há nenhuma
/// lógica de conversão/formatação de moeda aqui: repassamos exatamente
/// o que a loja devolve.
///
/// O produto de assinatura em si (compra real, `buyNonConsumable` +
/// validação de recibo) é responsabilidade de [PremiumPurchaseService] —
/// este serviço aqui SÓ lê o preço para exibição, nunca compra nada.
class PremiumPriceService {
  PremiumPriceService._internal();
  static final PremiumPriceService _instance = PremiumPriceService._internal();
  factory PremiumPriceService() => _instance;

  /// Id do produto de assinatura mensal cadastrado no Play Console —
  /// mesmo id usado por [PremiumPurchaseService] para a compra real.
  static const String idProdutoPremium = PremiumPurchaseService.idProdutoPremium;

  ProductDetails? _detalhesCache;
  Future<ProductDetails?>? _consultaEmAndamento;

  /// Preço do Plano Premium já formatado pela loja (moeda + valor no
  /// padrão local da conta do usuário) — `null` enquanto a consulta
  /// ainda não terminou, ou se a loja/produto não estiverem
  /// disponíveis. Quem chama deve tratar `null` como "mostrar texto
  /// genérico sem valor" (ver [PremiumPriceService], item 4 do pedido:
  /// nunca preencher com um preço fixo/hardcoded como fallback).
  ///
  /// Resultado cacheado em memória (produto de assinatura não muda de
  /// preço em tempo real durante a sessão do app) — chamadas repetidas
  /// não disparam uma nova consulta à loja; várias chamadas concorrentes
  /// durante a MESMA consulta em andamento compartilham o mesmo
  /// resultado, em vez de disparar `queryProductDetails` várias vezes.
  Future<String?> obterPrecoFormatado() async {
    final detalhes = await _obterDetalhes();
    return detalhes?.price;
  }

  Future<ProductDetails?> _obterDetalhes() {
    if (_detalhesCache != null) return Future.value(_detalhesCache);
    return _consultaEmAndamento ??= _consultar().whenComplete(() {
      _consultaEmAndamento = null;
    });
  }

  Future<ProductDetails?> _consultar() async {
    try {
      final disponivel = await InAppPurchase.instance.isAvailable();
      if (!disponivel) {
        debugPrint('⚠️ [PremiumPriceService] Loja indisponível neste aparelho/conta.');
        return null;
      }

      final resposta =
          await InAppPurchase.instance.queryProductDetails({idProdutoPremium});

      if (resposta.error != null) {
        debugPrint('⚠️ [PremiumPriceService] Erro ao consultar produto: ${resposta.error}');
      }
      if (resposta.notFoundIDs.isNotEmpty) {
        debugPrint(
            '⚠️ [PremiumPriceService] Produto "$idProdutoPremium" não encontrado na loja — '
            'verifique se o id está correto e publicado no Play Console/App Store Connect.');
      }
      if (resposta.productDetails.isEmpty) {
        return null;
      }

      _detalhesCache = resposta.productDetails.first;
      return _detalhesCache;
    } catch (e) {
      debugPrint('⚠️ [PremiumPriceService] Falha ao consultar preço na loja: $e');
      return null;
    }
  }
}
