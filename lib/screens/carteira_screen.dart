import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../services/wallet_service.dart';

/// Tela/módulo de Carteira: saldo em USD, equivalência em envios de
/// WhatsApp, nota explicativa (Push via app é gratuito; WhatsApp de
/// contingência custa $0.10 USD) e histórico de recargas/descontos.
class CarteiraScreen extends StatefulWidget {
  const CarteiraScreen({super.key});

  @override
  State<CarteiraScreen> createState() => _CarteiraScreenState();
}

class _CarteiraScreenState extends State<CarteiraScreen> {
  final WalletService _wallet = WalletService();
  StreamSubscription<String>? _statusSub;
  bool _comprando = false;

  @override
  void initState() {
    super.initState();
    _statusSub = _wallet.statusCompra.listen(_aoReceberStatusCompra);
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  void _aoReceberStatusCompra(String status) {
    if (!mounted) return;
    setState(() => _comprando = false);

    final l10n = AppLocalizations.of(context)!;
    String? mensagem;
    Color cor = Colors.redAccent;
    switch (status) {
      case 'sucesso':
        mensagem = l10n.carteiraCompraSucesso;
        cor = Colors.green;
        break;
      case 'falha_verificacao':
        mensagem = l10n.carteiraCompraFalhaVerificacao;
        break;
      case 'loja_indisponivel':
        mensagem = l10n.carteiraLojaIndisponivel;
        break;
      case 'erro':
      case 'produto_nao_encontrado':
        mensagem = l10n.carteiraCompraErro;
        break;
    }

    if (mensagem != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mensagem), backgroundColor: cor, behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _comprar(String produtoId) async {
    if (_comprando) return;
    setState(() => _comprando = true);
    await _wallet.comprarCredito(produtoId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.carteiraTitulo)),
      body: StreamBuilder<double>(
        stream: _wallet.saldoStream(),
        initialData: 0,
        builder: (context, snapshotSaldo) {
          final saldo = snapshotSaldo.data ?? 0;
          final envios = (saldo / WalletService.custoWhatsappUsd).floor();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildCartaoSaldo(l10n, saldo, envios),
              const SizedBox(height: 12),
              _buildNotaExplicativa(l10n),
              const SizedBox(height: 20),
              Text(
                l10n.carteiraRecarregarTitulo,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _buildBotoesRecarga(),
              const SizedBox(height: 24),
              Text(
                l10n.carteiraHistoricoTitulo,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _buildHistorico(l10n),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCartaoSaldo(AppLocalizations l10n, double saldo, int envios) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4C7040), Color(0xFF2E4A28)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.carteiraSaldoAtual, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            '\$${saldo.toStringAsFixed(2)} USD',
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.carteiraAteNEnvios(envios),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildNotaExplicativa(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.carteiraNotaExplicativa,
              style: TextStyle(fontSize: 12.5, color: Colors.blue.shade900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBotoesRecarga() {
    return Row(
      children: WalletService.produtosDisponiveis.map((produto) {
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ElevatedButton(
              onPressed: _comprando ? null : () => _comprar(produto.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4C7040),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('+ \$${produto.valorUsd.toStringAsFixed(0)}'),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHistorico(AppLocalizations l10n) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _wallet.historicoStream(),
      builder: (context, snapshot) {
        final itens = snapshot.data ?? const [];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (itens.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              l10n.carteiraHistoricoVazio,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          );
        }
        return Column(
          children: itens.map((item) => _buildItemHistorico(l10n, item)).toList(),
        );
      },
    );
  }

  Widget _buildItemHistorico(AppLocalizations l10n, Map<String, dynamic> item) {
    final tipo = item['tipo'] as String? ?? '';
    final valor = (item['valorUsd'] as num?)?.toDouble() ?? 0;
    final descricao = item['descricao'] as String? ?? '';
    final criadoEm = item['criadoEm'];
    final data = criadoEm is Timestamp ? criadoEm.toDate() : null;
    final isRecarga = tipo == 'recarga';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isRecarga ? Colors.green.shade50 : Colors.orange.shade50,
          child: Icon(
            isRecarga ? Icons.add_card : Icons.chat,
            color: isRecarga ? Colors.green.shade700 : Colors.orange.shade700,
          ),
        ),
        title: Text(isRecarga ? l10n.carteiraTipoRecarga : l10n.carteiraTipoDesconto),
        subtitle: Text(
          descricao + (data != null ? ' — ${_formatarData(data)}' : ''),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Text(
          '${valor >= 0 ? '+' : ''}\$${valor.toStringAsFixed(2)}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: valor >= 0 ? Colors.green.shade700 : Colors.orange.shade700,
          ),
        ),
      ),
    );
  }

  String _formatarData(DateTime data) {
    String dois(int v) => v.toString().padLeft(2, '0');
    return '${dois(data.day)}/${dois(data.month)}/${data.year}';
  }
}
