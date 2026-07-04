import 'package:flutter/material.dart';
import 'tabs/seguranca_tab.dart';
import 'tabs/familia_tab.dart';
import 'tabs/historico_tab.dart';
import 'tabs/configuracoes_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _indiceAbaAtual = 0;

  // Ordem exata das abas: Segurança, Família, Histórico
  final List<Widget> _telas = const [
    SegurancaTab(),
    FamiliaTab(),
    HistoricoTab(),
  ];

  final List<String> _titulos = const [
    'Segurança',
    'Família',
    'Histórico',
  ];

  void _aoSelecionarAba(int indice) {
    setState(() {
      _indiceAbaAtual = indice;
    });
  }

  void _abrirConfiguracoes(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('Configurações'),
          ),
          body: const ConfiguracoesTab(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titulos[_indiceAbaAtual], style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _abrirConfiguracoes(context),
          ),
        ],
      ),
      body: IndexedStack(
        index: _indiceAbaAtual,
        children: _telas,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _indiceAbaAtual,
        onTap: _aoSelecionarAba,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.shield),
            label: 'Segurança',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people),
            label: 'Família',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'Histórico',
          ),
        ],
      ),
    );
  }
}
