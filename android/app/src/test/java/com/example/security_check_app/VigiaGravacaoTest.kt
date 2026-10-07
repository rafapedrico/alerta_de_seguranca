package com.example.security_check_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Redução de custo: grava só com 30 m de deslocamento ou a cada 5 min parado. */
class VigiaGravacaoTest {
    @Test
    fun primeiraGravacaoSempre() = assertTrue(VigiaLocalizacaoService.deveGravar(null, null))

    @Test
    fun paradoMenosDe5MinNaoGrava() = assertFalse(VigiaLocalizacaoService.deveGravar(10f, 4 * 60_000L))

    @Test
    fun paradoHa5MinGrava() = assertTrue(VigiaLocalizacaoService.deveGravar(10f, 5 * 60_000L))

    @Test
    fun deslocamentoDe30mGrava() = assertTrue(VigiaLocalizacaoService.deveGravar(30f, 60_000L))

    @Test
    fun deslocamentoMenorQue30mNaoGrava() = assertFalse(VigiaLocalizacaoService.deveGravar(29f, 60_000L))
}
