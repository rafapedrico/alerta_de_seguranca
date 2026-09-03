import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'firebase_auth_service.dart';

/// Eventos best-effort emitidos por [PremiumPurchaseService.eventos] —
/// só para a UI reagir (loading/snackbar/diálogo de erro etc.). NUNCA a
/// fonte de verdade sobre se o usuário É Premium — isso continua sendo
/// exclusivamente [PlanoCicloService] (`isPremium` em `usuarios/{uid}`
/// no Firestore, só gravável pelo Admin SDK).
enum PremiumCompraEvento { pendente, concedida, semDireito, erro, erroValidacao, cancelada }

/// Serviço responsável pelo fluxo REAL de compra da assinatura mensal do
/// Plano Premium via Google Play Billing — fecha a lacuna documentada em
/// [PremiumPriceService] (que só consultava o PREÇO exibido na tela,
/// nunca comprava de fato) e em `functions/planoCicloService.js` (não
/// existia, neste projeto, nenhuma verificação de recibo de compra).
///
/// FLUXO COMPLETO:
/// 1. [comprarPremium] dispara `InAppPurchase.buyNonConsumable` — mesmo
///    para assinaturas: o plugin `in_app_purchase` não tem um
///    `buySubscription` separado, `buyNonConsumable` é o método correto
///    também para produtos do tipo `subs` no Play Billing.
/// 2. O RESULTADO não vem do retorno de [comprarPremium] (que só
///    confirma que a UI nativa de pagamento foi aberta) — chega depois,
///    de forma ASSÍNCRONA, pelo `purchaseStream` do plugin. [iniciar]
///    assina esse stream uma única vez, no boot do app (ver
///    `main.dart::iniciarServicosPosLoginOuDashboard`), nunca a partir de
///    um widget: a tela que abriu a compra pode não existir mais quando
///    o resultado chegar.
/// 3. Toda compra em estado `purchased`/`restored` é enviada à Cloud
///    Function `validarCompraPremium`, que consulta a Play Developer API
///    de verdade antes de conceder `isPremium` (ver
///    `functions/premiumPurchaseService.js`) — o cliente NUNCA decide
///    sozinho que uma compra é válida.
/// 4. [InAppPurchase.completePurchase] é chamado ao final de QUALQUER
///    desfecho (sucesso, sem direito, erro, cancelamento) sempre que
///    `pendingCompletePurchase` indicar que é necessário — obrigatório
///    pelo Play Billing: uma compra não confirmada em até 3 dias é
///    automaticamente estornada pelo Google.
class PremiumPurchaseService {
  PremiumPurchaseService._internal();
  static final PremiumPurchaseService _instance = PremiumPurchaseService._internal();
  factory PremiumPurchaseService() => _instance;

  /// Id do produto de assinatura mensal cadastrado no Play Console
  /// (Monetise > Products > Subscriptions) — precisa ser EXATAMENTE
  /// este id lá. Mesmo id usado em [PremiumPriceService] (consulta de
  /// preço) e em `functions/premiumPurchaseService.js` (validação).
  static const String idProdutoPremium = 'assinatura_mensal';

  StreamSubscription<List<PurchaseDetails>>? _subscricao;
  bool _iniciado = false;

  final StreamController<PremiumCompraEvento> _eventosController =
      StreamController<PremiumCompraEvento>.broadcast();

  /// Stream best-effort para a UI (loading/snackbar/diálogo) reagir aos
  /// desfechos da compra — perder um listener aqui (tela fechada no meio
  /// do fluxo) nunca afeta o resultado real, que já foi ou será
  /// processado de qualquer forma pelo `purchaseStream` nativo.
  Stream<PremiumCompraEvento> get eventos => _eventosController.stream;

  /// Assina o `purchaseStream` do plugin — deve ser chamado UMA única
  /// vez por sessão do engine, no boot do app. Idempotente (chamadas
  /// repetidas são ignoradas).
  void iniciar() {
    if (_iniciado) return;
    _iniciado = true;

    _subscricao = InAppPurchase.instance.purchaseStream.listen(
      _aoReceberAtualizacoesDeCompra,
      onError: (Object erro) {
        debugPrint('⚠️ [PremiumPurchaseService] Erro no purchaseStream: $erro');
      },
    );

    // Rejoga (pelo MESMO purchaseStream acima) qualquer compra que o
    // usuário já possui mas cuja validação com o backend não tenha sido
    // concluída ainda (ex: uma chamada anterior a `validarCompraPremium`
    // falhou por falta de rede, ou o app foi fechado/morto entre o
    // pagamento e a validação) — mesma filosofia de retry automático já
    // usada em `RetryUploadService` no resto do app: nunca exigir que o
    // usuário perceba/reporte manualmente que "pagou mas não recebeu".
    // Best-effort — uma falha aqui só adia a próxima tentativa para o
    // próximo boot, nunca trava o app.
    unawaited(
      InAppPurchase.instance.restorePurchases().catchError((Object e) {
        debugPrint('⚠️ [PremiumPurchaseService] restorePurchases() falhou (não crítico): $e');
      }),
    );
  }

  /// Cancela a assinatura ao `purchaseStream` — só para testes/cleanup;
  /// nunca chamado no fluxo normal do app (o serviço vive pela sessão
  /// inteira do engine).
  void encerrar() {
    _subscricao?.cancel();
    _subscricao = null;
    _iniciado = false;
  }

  /// Dispara a compra da assinatura mensal do Plano Premium. Retorna
  /// `false` sem abrir nada se não houver sessão, a loja estiver
  /// indisponível ou o produto não for encontrado (mesmo tratamento
  /// permissivo/silencioso de [PremiumPriceService]) — o CHAMADOR decide
  /// se quer mostrar algum feedback nesses casos (ex: manter o texto
  /// genérico já exibido).
  ///
  /// O resultado da compra em si NÃO vem do retorno deste método — ver
  /// documentação da classe.
  Future<bool> comprarPremium() async {
    final String? uid = FirebaseAuthService().uidAtual;
    if (uid == null) {
      debugPrint('⚠️ [PremiumPurchaseService] Sem sessão autenticada — compra cancelada.');
      return false;
    }

    final bool disponivel = await InAppPurchase.instance.isAvailable();
    if (!disponivel) {
      debugPrint('⚠️ [PremiumPurchaseService] Loja indisponível neste aparelho/conta.');
      return false;
    }

    final ProductDetailsResponse resposta =
        await InAppPurchase.instance.queryProductDetails({idProdutoPremium});
    if (resposta.error != null || resposta.productDetails.isEmpty) {
      debugPrint(
          '⚠️ [PremiumPurchaseService] Produto "$idProdutoPremium" indisponível na loja '
          '(erro: ${resposta.error}, notFoundIDs: ${resposta.notFoundIDs}).');
      return false;
    }

    final ProductDetails produto = resposta.productDetails.first;

    // ANTI-FRAUDE (ver documentação completa em
    // `functions/premiumPurchaseService.js::validarCompraPremium`):
    // amarra esta compra ao uid do Firebase de quem está comprando AGORA
    // — sem isso, um único purchaseToken válido poderia, em tese, ser
    // reenviado por outras contas Firebase para reivindicar o mesmo
    // Premium de graça. Só disponível via `GooglePlayPurchaseParam`
    // (Android); em outras plataformas usa o `PurchaseParam` genérico —
    // hoje irrelevante, já que o app só está publicado no Android (ver
    // site: "Em breve na App Store"), mas evita quebrar caso o iOS seja
    // adicionado no futuro sem ninguém lembrar de revisitar este método.
    final PurchaseParam purchaseParam = Platform.isAndroid
        ? GooglePlayPurchaseParam(productDetails: produto, applicationUserName: uid)
        : PurchaseParam(productDetails: produto, applicationUserName: uid);

    try {
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: purchaseParam);
      return true;
    } catch (e) {
      debugPrint('⚠️ [PremiumPurchaseService] Falha ao iniciar a compra: $e');
      return false;
    }
  }

  Future<void> _aoReceberAtualizacoesDeCompra(List<PurchaseDetails> compras) async {
    for (final PurchaseDetails compra in compras) {
      // Outro produto (não deveria existir nenhum outro configurado
      // neste app, mas nunca custa ser explícito) — ignora e nem sequer
      // completa, para não interferir em nenhum outro fluxo de compra.
      if (compra.productID != idProdutoPremium) continue;

      switch (compra.status) {
        case PurchaseStatus.pending:
          debugPrint('⏳ [PremiumPurchaseService] Compra pendente (aguardando confirmação)...');
          _eventosController.add(PremiumCompraEvento.pendente);
          break;

        case PurchaseStatus.error:
          debugPrint('❌ [PremiumPurchaseService] Erro na compra: ${compra.error}');
          _eventosController.add(PremiumCompraEvento.erro);
          break;

        case PurchaseStatus.canceled:
          debugPrint('🚫 [PremiumPurchaseService] Compra cancelada pelo usuário.');
          _eventosController.add(PremiumCompraEvento.cancelada);
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _validarEConceder(compra);
          break;
      }

      // OBRIGATÓRIO pelo Play Billing: sem isso, a compra fica "pendente
      // de confirmação" indefinidamente e o Google a reembolsa
      // automaticamente em até 3 dias. Chamado em TODO desfecho acima
      // (sucesso, sem direito, erro, cancelamento) sempre que o plugin
      // sinalizar que é necessário — nunca condicionado a nada ter dado
      // certo (ver [_validarEConceder]: mesmo uma falha de rede na
      // validação completa a compra do lado do Play Billing; a
      // recuperação para esse caso é o `restorePurchases()` no próximo
      // boot, ver [iniciar]).
      if (compra.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(compra);
      }
    }
  }

  Future<void> _validarEConceder(PurchaseDetails compra) async {
    try {
      final HttpsCallableResult<dynamic> resultado = await FirebaseFunctions.instance
          .httpsCallable('validarCompraPremium')
          .call(<String, dynamic>{
        'purchaseToken': compra.verificationData.serverVerificationData,
        'productId': compra.productID,
      });

      final Map<dynamic, dynamic>? dados = resultado.data as Map<dynamic, dynamic>?;
      final bool isPremium = dados?['isPremium'] == true;

      if (isPremium) {
        debugPrint('✅ [PremiumPurchaseService] Premium validado e concedido com sucesso.');
        _eventosController.add(PremiumCompraEvento.concedida);
      } else {
        debugPrint(
            '⚠️ [PremiumPurchaseService] Compra validada mas sem direito a Premium agora '
            '(estado: ${dados?['subscriptionState']}).');
        _eventosController.add(PremiumCompraEvento.semDireito);
      }
    } catch (e) {
      // Falha de REDE/BACKEND ao validar — a compra JÁ foi feita de
      // verdade na Play Store (o pagamento já ocorreu do lado do
      // Google), então isto NÃO significa que a compra falhou. A
      // recuperação automática para este caso é o `restorePurchases()`
      // chamado a cada boot em [iniciar], que rejoga esta mesma compra
      // pelo purchaseStream até a validação finalmente ter sucesso.
      debugPrint('⚠️ [PremiumPurchaseService] Falha ao validar a compra com o backend: $e');
      _eventosController.add(PremiumCompraEvento.erroValidacao);
    }
  }
}
