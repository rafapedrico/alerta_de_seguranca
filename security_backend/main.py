"""
Security Backend API
=====================
API dedicada em FastAPI para servir como backend do sistema de segurança
do app Flutter (security_check_app).

Endpoints iniciais:
- POST /api/rotinas -> Salva o alarme de rotina de check-in (horário + tolerância).
- POST /api/alerta  -> Dispara o alerta máximo em tempo real (lat/long/contexto).
- POST /api/status  -> Checa a conectividade entre o celular e o servidor.

Para rodar localmente:
    .venv\\Scripts\\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
"""

from datetime import datetime, time
from typing import Optional

from fastapi import FastAPI, status
from pydantic import BaseModel, Field

app = FastAPI(
    title="Security Check App - Backend API",
    description="API responsável por gerenciar rotinas, alertas de emergência e status de conectividade do app de segurança.",
    version="1.0.0",
)


# ---------------------------------------------------------------------------
# MODELOS (Schemas) - Formato JSON esperado/retornado por cada endpoint
# ---------------------------------------------------------------------------

class RotinaPayload(BaseModel):
    """Payload enviado pelo app para salvar um alarme de rotina/check-in.

    Reflete fielmente o modelo real do app Flutter (AlarmeRotina): um
    ÚNICO horário de check-in (não um intervalo início/fim), com uma
    tolerância em minutos antes de disparar o alerta automático caso o
    usuário não confirme "Cheguei bem" a tempo.
    """

    usuario_id: str = Field(..., description="Identificador único do usuário/dispositivo")
    alarme_id: Optional[int] = Field(
        default=None, description="Id local (SQLite) do alarme de rotina no app, se já existente"
    )
    horario: time = Field(..., description="Horário do check-in de rotina (HH:MM:SS)")
    tolerancia_minutos: int = Field(
        ..., ge=0, description="Tempo de tolerância (em minutos) antes de disparar alerta"
    )
    etiqueta: Optional[str] = Field(
        default=None, description="Nome/etiqueta livre do alarme (ex: 'Chegada no trabalho')"
    )
    contexto_personalizado: Optional[str] = Field(
        default=None, description="Dica de contexto usada na mensagem de SMS de emergência"
    )
    dias_semana: Optional[list[str]] = Field(
        default=None,
        description="Dias da semana em que a rotina é válida (ex: ['segunda', 'terca'])",
    )
    ativo: Optional[bool] = Field(
        default=True, description="Se o alarme de rotina está ativo ou não"
    )

    class Config:
        json_schema_extra = {
            "example": {
                "usuario_id": "user_123",
                "alarme_id": 1,
                "horario": "22:00:00",
                "tolerancia_minutos": 15,
                "etiqueta": "Chegada no trabalho",
                "contexto_personalizado": "Indo de moto para o trabalho",
                "dias_semana": ["segunda", "terca", "quarta", "quinta", "sexta"],
                "ativo": True,
            }
        }


class AlertaPayload(BaseModel):
    """Payload enviado pelo app ao disparar o alerta máximo em tempo real."""

    usuario_id: str = Field(..., description="Identificador único do usuário/dispositivo")
    latitude: float = Field(..., description="Latitude atual do dispositivo")
    longitude: float = Field(..., description="Longitude atual do dispositivo")
    contexto: str = Field(
        ..., description="Contexto/motivo do alerta (ex: 'rotina_nao_confirmada', 'botao_panico')"
    )
    timestamp: Optional[datetime] = Field(
        default=None, description="Momento em que o alerta foi gerado (UTC). Se omitido, usa o horário do servidor."
    )

    class Config:
        json_schema_extra = {
            "example": {
                "usuario_id": "user_123",
                "latitude": -23.55052,
                "longitude": -46.633308,
                "contexto": "botao_panico",
                "timestamp": "2026-07-06T21:15:00Z",
            }
        }


class StatusPayload(BaseModel):
    """Payload enviado pelo app para checar a conectividade com o servidor."""

    usuario_id: str = Field(..., description="Identificador único do usuário/dispositivo")
    app_versao: Optional[str] = Field(default=None, description="Versão atual do app Flutter")
    bateria_percentual: Optional[int] = Field(
        default=None, ge=0, le=100, description="Percentual de bateria do dispositivo no momento do ping"
    )

    class Config:
        json_schema_extra = {
            "example": {
                "usuario_id": "user_123",
                "app_versao": "1.0.0",
                "bateria_percentual": 87,
            }
        }


# ---------------------------------------------------------------------------
# ENDPOINTS
# ---------------------------------------------------------------------------

@app.post("/api/rotinas", status_code=status.HTTP_201_CREATED, tags=["Rotinas"])
async def salvar_rotina(payload: RotinaPayload):
    """
    Recebe e salva o alarme de rotina de check-in (horário + tolerância)
    configurado pelo usuário na aba Família do app.
    """
    # TODO: persistir em banco de dados (ex: PostgreSQL, SQLite, etc.)
    return {
        "mensagem": "Rotina salva com sucesso.",
        "dados_recebidos": payload,
        "alarme_id": payload.alarme_id,
    }


@app.post("/api/alerta", status_code=status.HTTP_200_OK, tags=["Alerta"])
async def disparar_alerta(payload: AlertaPayload):
    """
    Recebe o disparo de alerta máximo em tempo real, contendo latitude, longitude
    e o contexto do evento. Deve acionar as notificações de emergência
    (SMS, push notification, contatos de confiança, etc.).
    """
    timestamp_final = payload.timestamp or datetime.utcnow()

    # TODO: acionar lógica real de emergência (SMS, push, ligação, etc.)
    return {
        "mensagem": "Alerta recebido e processado com sucesso.",
        "usuario_id": payload.usuario_id,
        "localizacao": {
            "latitude": payload.latitude,
            "longitude": payload.longitude,
        },
        "contexto": payload.contexto,
        "timestamp_processado": timestamp_final,
    }


@app.post("/api/status", status_code=status.HTTP_200_OK, tags=["Status"])
async def checar_status(payload: StatusPayload):
    """
    Endpoint de heartbeat/health-check. O app usa esta rota periodicamente
    para confirmar que existe conectividade entre o celular e o servidor.
    """
    return {
        "mensagem": "Conectado com sucesso ao servidor.",
        "servidor_hora_atual": datetime.utcnow(),
        "usuario_id": payload.usuario_id,
        "app_versao": payload.app_versao,
        "bateria_percentual": payload.bateria_percentual,
    }


@app.get("/", tags=["Root"])
async def root():
    """Rota raiz simples para verificar se a API está no ar."""
    return {"status": "online", "servico": "Security Check App - Backend API"}
