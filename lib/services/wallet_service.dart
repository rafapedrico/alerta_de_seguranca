import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'firebase_auth_service.dart';

/// Um produto consumível de recarga da Carteira em USD.
class ProdutoCredito {
  final String id;
  final double valorUsd;
  const ProdutoCredito(this.id, this.valorUsd);
}

/// Serviço central da Carteira em USD: expõe o saldo e o histórico de
/// créditos (ambos SOMENTE LEITURA no cliente — toda escrita é feita
/// pelas Cloud Functions, ver `firestore.rules`) e orquestra a compra de
/// recargas via `in_app_purchase` (Google Play), sempre confirmando a
/// compra no servidor (`confirmarCompraCredito`, callable) antes de
/// considerá-la concluída — nunca credita saldo otimisticamente no app.
class WalletService {
  WalletService._internal() {
    // Assinatura mantida viva pela duração inteira do app (singleton,
    // nunca cancelada) — por isso não é preciso guardar a referência ao
    // StreamSubscription retornado.
    InAppPurchase.instance.purchaseStream.listen(
      _aoAtualizarCompras,
      onError: (e) =>
          debugPrint('⚠️ [WalletService] Erro no stream de compras: $e'),
    );
  }
  static final WalletService _instance = WalletService._internal();
  factory WalletService() => _instance;

  /// Mesmos productId configurados no Play Console e em
  /// `functions/comprasService.js` (`PRODUTOS_CREDITO`).
  static const List<ProdutoCredito> produtosDisponiveis = [
    ProdutoCredito('credito_usd_1', 1),
    ProdutoCredito('credito_usd_5', 5),
    ProdutoCredito('credito_usd_10', 10),
  ];

  /// Mesmo valor de `CUSTO_WHATSAPP_USD` em `functions/constantes.js`.
  static const double custoWhatsappUsd = 0.10;

  final StreamController<String> _statusCompraController =
      StreamController<String>.broadcast();

  /// Emite eventos de status da última tentativa de compra ('sucesso',
  /// 'falha_verificacao', 'erro', 'loja_indisponivel',
  /// 'produto_nao_encontrado') — consumido pela CarteiraScreen para
  /// exibir feedback ao usuário.
  Stream<String> get statusCompra => _statusCompraController.stream;

  bool get _firebaseDisponivel =>
      Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

  DocumentReference<Map<String, dynamic>>? get _documentoUsuario {
    final uid = FirebaseAuthService().uidAtual;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('usuarios').doc(uid);
  }

  /// Saldo atual em USD, em tempo real. `0` se não houver sessão ativa ou
  /// o campo ainda não existir (conta recém-criada).
  Stream<double> saldoStream() {
    final doc = _documentoUsuario;
    if (!_firebaseDisponivel || doc == null) return Stream.value(0);
    return doc.snapshots().map((snap) {
      final saldo = snap.data()?['saldoUsd'];
      return saldo is num ? saldo.toDouble() : 0.0;
    });
  }

  /// Histórico de recargas e descontos (mais recente primeiro).
  Stream<List<Map<String, dynamic>>> historicoStream() {
    final doc = _documentoUsuario;
    if (!_firebaseDisponivel || doc == null) return Stream.value(const []);
    return doc
        .collection('historicoCreditos')
        .orderBy('criadoEm', descending: true)
        .limit(50)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList());
  }

  /// Inicia a compra do produto consumível [produtoId] via Google Play.
  /// O crédito real só acontece quando [_confirmarCompraNoServidor]
  /// receber `sucesso: true` da Cloud Function.
  Future<void> comprarCredito(String produtoId) async {
    try {
      final disponivel = await InAppPurchase.instance.isAvailable();
      if (!disponivel) {
        _statusCompraController.add('loja_indisponivel');
        return;
      }

      final resposta =
          await InAppPurchase.instance.queryProductDetails({produtoId});
      if (resposta.productDetails.isEmpty) {
        _statusCompraController.add('produto_nao_encontrado');
        return;
      }

      final param = PurchaseParam(productDetails: resposta.productDetails.first);
      await InAppPurchase.instance.buyConsumable(purchaseParam: param);
    } catch (e) {
      debugPrint('⚠️ [WalletService] Falha ao iniciar compra de $produtoId: $e');
      _statusCompraController.add('erro');
    }
  }

  Future<void> _aoAtualizarCompras(List<PurchaseDetails> compras) async {
    for (final compra in compras) {
      switch (compra.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _confirmarCompraNoServidor(compra);
          break;
        case PurchaseStatus.error:
          debugPrint(
              '⚠️ [WalletService] Erro na compra ${compra.productID}: ${compra.error}');
          _statusCompraController.add('erro');
          break;
        case PurchaseStatus.canceled:
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  /// Chama a Cloud Function callable `confirmarCompraCredito`, que
  /// verifica a compra na Play Developer API antes de creditar o saldo.
  /// Só marca a compra como concluída no dispositivo
  /// (`InAppPurchase.completePurchase`) em caso de SUCESSO do servidor —
  /// se a verificação falhar, deixa pendente para nova tentativa em vez
  /// de perder a compra silenciosamente.
  Future<void> _confirmarCompraNoServidor(PurchaseDetails compra) async {
    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('confirmarCompraCredito')
          .call<Map<String, dynamic>>({
        'produtoId': compra.productID,
        'purchaseToken': compra.verificationData.serverVerificationData,
      });

      final sucesso = resultado.data['sucesso'] == true;
      if (sucesso) {
        await InAppPurchase.instance.completePurchase(compra);
        debugPrint(
            '✅ [WalletService] Compra ${compra.productID} confirmada e creditada.');
        _statusCompraController.add('sucesso');
      } else {
        _statusCompraController.add('falha_verificacao');
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
          '⚠️ [WalletService] Compra ${compra.productID} rejeitada pelo servidor: '
          '${e.code} ${e.message}');
      _statusCompraController.add('falha_verificacao');
    } catch (e) {
      debugPrint('⚠️ [WalletService] Falha ao confirmar compra no servidor: $e');
      _statusCompraController.add('erro');
    }
  }
}
