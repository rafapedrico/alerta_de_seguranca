import 'package:flutter/widgets.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// Normalização INTERNACIONAL de telefones para E.164 (`+<DDI><número>`) —
/// o Guardião X é um produto global, então nenhuma regra fixa de país
/// (ex: sempre prefixar "+55") pode viver aqui. Usa `phone_numbers_parser`
/// (porta pura-Dart do libphonenumber do Google) tanto para o número da
/// própria conta ([CadastroScreen]) quanto para os contatos de emergência
/// importados da agenda ([ConfiguracoesTab]).
///
/// CORREÇÃO DE BUG REAL: a normalização antiga só prefixava "+55" quando o
/// texto não começava com "+", sem checar se o DDI já estava embutido nos
/// dígitos — um contato importado como "5515981343706" (DDI já incluso,
/// sem o "+") virava "+555515981343706" (DDI duplicado, E.164 inválido) e
/// nem SMS nem os demais canais chegavam de verdade a esse número.
/// `PhoneNumber.parse` detecta e remove esse DDI
/// duplicado automaticamente (ver `PhoneParser.parse` no pacote), além de
/// já remover prefixos de acesso nacional (ex: o "0" local) e caracteres
/// de formatação — não é preciso reimplementar nada disso manualmente.
class TelefoneUtils {
  TelefoneUtils._();

  /// Região usada como ÚLTIMO fallback — somente quando o número não tem
  /// nenhum indício de DDI E o locale do dispositivo também não permite
  /// deduzir uma região (ver [regiaoPadraoDoDispositivo]). Não é uma regra
  /// de negócio fixa, é só o valor inicial do produto antes de existir
  /// preferência de região por usuário.
  static const IsoCode regiaoFallbackFinal = IsoCode.BR;

  /// Deduz a região padrão do usuário a partir do locale atual do
  /// dispositivo (ex: `pt_BR` -> `IsoCode.BR`, `en_US` -> `IsoCode.US`) —
  /// usada como referência ao normalizar um número que não contém DDI
  /// explícito. Cai em [regiaoFallbackFinal] se o locale não expuser um
  /// código de país reconhecido pelo pacote.
  static IsoCode regiaoPadraoDoDispositivo() {
    final codigoPais =
        WidgetsBinding.instance.platformDispatcher.locale.countryCode;
    if (codigoPais == null || codigoPais.isEmpty) return regiaoFallbackFinal;
    try {
      return IsoCode.values.byName(codigoPais.toUpperCase());
    } catch (_) {
      return regiaoFallbackFinal;
    }
  }

  /// Normaliza [telefone] para E.164. [regiao] é usada apenas como
  /// referência para números SEM DDI explícito — se omitida, usa
  /// [regiaoPadraoDoDispositivo]. Retorna `null` se o número não puder
  /// ser validado em nenhuma interpretação razoável (mais seguro do que
  /// gravar/enviar para um número corrompido).
  static String? normalizarE164(String? telefone, {IsoCode? regiao}) {
    if (telefone == null) return null;
    final bruto = telefone.trim();
    if (bruto.isEmpty) return null;

    try {
      final numero = PhoneNumber.parse(
        bruto,
        callerCountry: regiao ?? regiaoPadraoDoDispositivo(),
      );
      return numero.isValid() ? numero.international : null;
    } catch (_) {
      return null;
    }
  }

  /// Remove de [contatos] (cada item com uma chave `'telefone'`, no
  /// formato de `DatabaseHelper.getContatosEmergencia()`) qualquer
  /// entrada cujo número normalizado (E.164) seja IGUAL ao do próprio
  /// usuário ([telefoneProprio], em qualquer formato — é normalizado
  /// aqui mesmo).
  ///
  /// CORREÇÃO DE BUG REAL (pedido do usuário, 2026-09-11): o próprio
  /// número do usuário podia acabar cadastrado como um dos seus contatos
  /// de emergência (ex: importado por engano da própria Agenda do
  /// aparelho, onde é comum haver uma entrada "Eu"/o próprio número) —
  /// nesse caso, TODOS os canais de disparo de alerta (SMS nativo e,
  /// pelo canal de nuvem, o Push/alarme sonoro no app receptor) enviavam
  /// o alarme de pânico de volta para o PRÓPRIO aparelho da vítima, que
  /// tocava o som de alerta bem na hora em que ela mais precisa passar
  /// despercebida. Usado nos DOIS pontos únicos de disparo:
  /// [EmergencyAlertService._enviarSms] (canal SMS) e
  /// `ContatosEmergenciaService._sincronizarComFirebase` (lista que
  /// alimenta o canal Push via Cloud Function).
  ///
  /// Propositalmente NÃO filtra a lista usada pelas telas de
  /// gerenciamento (Configurações/Família, via
  /// `DatabaseHelper.getContatosEmergencia()` direto) — o contato
  /// continua visível ali para o usuário revisar/excluir manualmente;
  /// só os canais de disparo são protegidos.
  static List<Map<String, dynamic>> excluirProprioNumero(
    List<Map<String, dynamic>> contatos,
    String? telefoneProprio,
  ) {
    final proprio = normalizarE164(telefoneProprio);
    if (proprio == null) return contatos;

    return contatos.where((contato) {
      final numeroContato = normalizarE164(contato['telefone'] as String?);
      return numeroContato != proprio;
    }).toList();
  }
}
