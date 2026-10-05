import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/services/indicacao_service.dart';

void main() {
  group('IndicacaoService.codigoDoReferrer', () {
    test('lê o código de "ref=CODIGO"', () {
      expect(IndicacaoService.codigoDoReferrer('ref=ABC234'), 'ABC234');
    });

    test('ignora os parâmetros utm_* que a Play Store junta', () {
      expect(
        IndicacaoService.codigoDoReferrer('utm_source=google-play&utm_medium=organic&ref=XYZ789'),
        'XYZ789',
      );
    });

    test('aceita minúsculas e hífen, como o servidor', () {
      expect(IndicacaoService.codigoDoReferrer('ref=abc-234'), 'ABC234');
    });

    test('sem ref, vazio ou fora do formato: nulo', () {
      expect(IndicacaoService.codigoDoReferrer(null), isNull);
      expect(IndicacaoService.codigoDoReferrer(''), isNull);
      expect(IndicacaoService.codigoDoReferrer('utm_source=google-play&utm_medium=organic'), isNull);
      // O, 0, I, 1 e L não fazem parte do alfabeto.
      expect(IndicacaoService.codigoDoReferrer('ref=ABCO10'), isNull);
      expect(IndicacaoService.codigoDoReferrer('ref=ABC23'), isNull);
    });
  });

  test('motivos do servidor', () {
    expect(IndicacaoService.motivoDoServidor('ok'), MotivoIndicacao.ok);
    expect(IndicacaoService.motivoDoServidor('codigo_invalido'), MotivoIndicacao.codigoInvalido);
    expect(IndicacaoService.motivoDoServidor('autoindicacao'), MotivoIndicacao.autoindicacao);
    expect(IndicacaoService.motivoDoServidor('ja_vinculado'), MotivoIndicacao.jaVinculado);
    expect(IndicacaoService.motivoDoServidor('ja_premium'), MotivoIndicacao.jaPremium);
    expect(IndicacaoService.motivoDoServidor('outro'), MotivoIndicacao.erro);
  });
}
