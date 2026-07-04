import 'package:flutter/material.dart';

class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

class _HistoricoTabState extends State<HistoricoTab> {
  final List<String> _activities = [
    'Aguardando check-in de Segurança',
    'Alarme Reiniciado',
    'Envio para Contato (Mamãe)',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _activities.length,
            itemBuilder: (context, index) {
              return ListTile(
                leading: const Icon(Icons.history),
                title: Text(_activities[index]),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    // Implement delete functionality here
                  },
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            onPressed: () {
              // Implement delete selected items functionality here
            },
            icon: const Icon(Icons.delete_forever),
            label: const Text('Apagar itens selecionados'),
          ),
        ),
      ],
    );
  }
}
