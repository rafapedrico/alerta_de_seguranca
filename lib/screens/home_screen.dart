import 'package:flutter/material.dart';
import 'tabs/seguranca_tab.dart';
import 'tabs/historico_tab.dart';
import 'tabs/configuracoes_tab.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2, // Apenas Segurança e Histórico nas abas
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Security Check', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {
                // Abrimos a tela envolvendo-a em um Scaffold para corrigir a tela vermelha
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => Scaffold(
                      appBar: AppBar(
                        title: const Text('Configurações'),
                      ),
                      body: const ConfiguracoesTab(), // Abre o conteúdo das configurações
                    ),
                  ),
                );
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.shield), text: 'Segurança'),
              Tab(icon: Icon(Icons.history), text: 'Histórico'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            SegurancaTab(),
            HistoricoTab(),
          ],
        ),
      ),
    );
  }
}