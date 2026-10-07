import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/models/alarme_rotina.dart';
import 'package:security_check_app/services/alarme_nativo_service.dart';
import 'package:security_check_app/services/aviso_entrega_service.dart';
import 'package:security_check_app/services/pin_seguro.dart';
import 'package:security_check_app/services/rotina_alarme_service.dart';

void main() {
  group('PinSeguro', () {
    test('hash com sal confere só o PIN certo', () {
      final hash = PinSeguro.gerarHash('4821');
      expect(PinSeguro.ehHash(hash), isTrue);
      expect(hash.contains('4821'), isFalse);
      expect(PinSeguro.confere('4821', hash), isTrue);
      expect(PinSeguro.confere('4822', hash), isFalse);
    });

    test('dois hashes do mesmo PIN são diferentes (sal)', () {
      expect(PinSeguro.gerarHash('1111'), isNot(PinSeguro.gerarHash('1111')));
    });

    test('PIN antigo em texto puro continua aceito até a migração', () {
      expect(PinSeguro.confere('1234', '1234'), isTrue);
      expect(PinSeguro.confere('0000', '1234'), isFalse);
    });

    test('sem PIN cadastrado nada confere (nunca um PIN padrão)', () {
      expect(PinSeguro.confere('1234', null), isFalse);
      expect(PinSeguro.confere('1234', ''), isFalse);
      expect(PinSeguro.temPin(null), isFalse);
    });
  });

  group('Despertador pausado', () {
    Map<String, dynamic> alarme({required Set<int> dias, String? pausadoEm, int hora = 23, int minuto = 59}) =>
        AlarmeRotina(
          id: 1,
          hora: hora,
          minuto: minuto,
          diasSemana: dias,
          pausadoEm: pausadoEm,
        ).toMap();

    test('editar preserva a pausa (toMap/fromMap)', () {
      final hoje = AlarmeRotina.dataIso(DateTime.now());
      final editado = AlarmeRotina.fromMap(alarme(dias: {1, 2, 3, 4, 5, 6, 7}, pausadoEm: hoje));
      expect(editado.pausado, isTrue);
      expect(editado.toMap()['alarme_pausado'], hoje);
    });

    test('pausa antiga ("1", sem fim) não pausa mais', () {
      final mapa = alarme(dias: {1})..['alarme_pausado'] = '1';
      expect(AlarmeRotina.fromMap(mapa).pausado, isFalse);
    });

    test('"Retorna" é a próxima ocorrência real, fora do dia pausado', () {
      final hoje = DateTime.now();
      final amanha = hoje.add(const Duration(days: 1));
      final depois = hoje.add(const Duration(days: 2));
      // Só o dia de depois de amanhã: a pausa de hoje não pode virar "amanhã".
      final proxima = RotinaAlarmeService.proximaOcorrenciaValida(
        alarme(dias: {depois.weekday}, pausadoEm: AlarmeRotina.dataIso(hoje)),
      );
      expect(proxima, isNotNull);
      expect(proxima!.weekday, depois.weekday);
      expect(AlarmeRotina.dataIso(proxima) == AlarmeRotina.dataIso(amanha), isFalse);
    });
  });

  test('etiqueta interna nunca vai para a nuvem', () {
    expect(AlarmeNativoService.etiquetaParaNuvem(AlarmeRotina.chaveEtiquetaPadrao), '');
    expect(AlarmeNativoService.etiquetaParaNuvem('Academia'), 'Academia');
    expect(AlarmeNativoService.etiquetaParaNuvem(null), '');
  });

  group('Aviso de entrega (aviso_entrega_alerta)', () {
    test('tipo do servidor é aceito', () {
      expect(AvisoEntregaService.tipos.contains('aviso_entrega_alerta'), isTrue);
    });

    test('statusEntrega tem prioridade; sem ele, situacao (pendente = tentando)', () {
      expect(AvisoEntregaService.statusDoPush({'statusEntrega': 'entregue', 'situacao': 'pendente'}),
          StatusEntregaContato.entregue);
      expect(AvisoEntregaService.statusDoPush({'situacao': 'pendente'}), StatusEntregaContato.tentando);
      expect(AvisoEntregaService.statusDoPush({'situacao': 'nao_entregue'}), StatusEntregaContato.naoEntregue);
    });

    test('nomeContato, senão nomeDestinatario', () {
      expect(AvisoEntregaService.nomeDoContato({'nomeContato': 'Ana', 'nomeDestinatario': 'B'}), 'Ana');
      expect(AvisoEntregaService.nomeDoContato({'nomeDestinatario': 'Bia'}), 'Bia');
    });
  });
}
