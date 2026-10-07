package com.example.security_check_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Defeito 1.1: PIN correto no fim do cronômetro e, em seguida, o app
 * removido dos Recentes NÃO pode disparar o alerta de fechamento forçado.
 */
class DecisaoFechamentoForcadoTest {

    private val agora = 1_800_000_000_000L
    private val cronometro = Ocorrencia(
        RotinaCheckinAlarmActivity.TIPO_ALARME_CRONOMETRO,
        DespertadorAgenda.ID_CRONOMETRO,
        agora - 10_000L,
        agora + 50_000L,
    )

    @Test
    fun pinCorretoSeguidoDeRemoverDosRecentesNaoDisparaAlerta() {
        // PIN correto: a ocorrência é marcada como resolvida no nativo
        // (RotinaAlarmWakeService.resolver) e sai das pendentes.
        val resolvidas = listOf(cronometro.chave)
        val pendentes = emptyList<Ocorrencia>()

        // onTaskRemoved: nada a marcar.
        assertTrue(DecisaoFechamentoForcado.aMarcar(pendentes, resolvidas, agora).isEmpty())
        // Mesmo que a lista de pendentes ainda tivesse a ocorrência (corrida
        // com o serviço), ela continua sem ser marcada.
        assertTrue(DecisaoFechamentoForcado.aMarcar(listOf(cronometro), resolvidas, agora).isEmpty())
        // E uma marca antiga nunca dispara depois de resolvida.
        assertFalse(DecisaoFechamentoForcado.deveDisparar(setOf(cronometro.chave), resolvidas, cronometro.chave))
    }

    @Test
    fun removerDosRecentesSemPinDisparaAlerta() {
        val marcadas = DecisaoFechamentoForcado.aMarcar(listOf(cronometro), emptyList(), agora)
        assertEquals(listOf(cronometro), marcadas)
        assertTrue(
            DecisaoFechamentoForcado.deveDisparar(marcadas.map { it.chave }.toSet(), emptyList(), cronometro.chave),
        )
    }

    @Test
    fun prazoVencidoNaoEhMarcado() {
        val vencida = cronometro.copy(prazo = agora - 1L)
        assertTrue(DecisaoFechamentoForcado.aMarcar(listOf(vencida), emptyList(), agora).isEmpty())
    }

    @Test
    fun resolverUmDespertadorNaoAfetaOutro() {
        val d1 = Ocorrencia(RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA, 1, agora - 1_000L, agora + 600_000L)
        val d2 = Ocorrencia(RotinaCheckinAlarmActivity.TIPO_ALARME_ROTINA, 2, agora - 1_000L, agora + 600_000L)
        assertEquals(listOf(d2), DecisaoFechamentoForcado.aMarcar(listOf(d1, d2), listOf(d1.chave), agora))
    }
}
