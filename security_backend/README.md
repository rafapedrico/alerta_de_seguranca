# Security Backend API

Backend em **FastAPI** para o app **security_check_app** (Flutter).

## Estrutura

```
security_backend/
├── .venv/              # Ambiente virtual Python (não versionar)
├── main.py             # Aplicação FastAPI com os endpoints
├── requirements.txt     # Dependências do projeto
└── README.md
```

## Setup do ambiente

```bash
cd security_backend
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
```

## Rodando o servidor

Para rodar acessível também por outros dispositivos na mesma rede Wi-Fi
(ex: celular com o app Flutter), use `--host 0.0.0.0`:

```bash
.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

O servidor ficará disponível em:
- No PC: http://127.0.0.1:8000
- Na rede local (para o celular conectar): **http://192.168.15.10:8000**
- Documentação automática (Swagger): http://192.168.15.10:8000/docs

> ⚠️ Verifique se o celular está na **mesma rede Wi-Fi** que o computador, e se o Firewall do Windows permite conexões na porta 8000.

## Endpoints

### `POST /api/rotinas`
Salva os horários de rotina e tolerância configurados no app.

```json
{
  "usuario_id": "user_123",
  "horario_inicio": "22:00:00",
  "horario_fim": "06:00:00",
  "tolerancia_minutos": 15,
  "dias_semana": ["segunda", "terca", "quarta", "quinta", "sexta"]
}
```

### `POST /api/alerta`
Dispara o alerta máximo em tempo real (SOS), enviando localização e contexto.

```json
{
  "usuario_id": "user_123",
  "latitude": -23.55052,
  "longitude": -46.633308,
  "contexto": "botao_panico",
  "timestamp": "2026-07-06T21:15:00Z"
}
```

### `POST /api/status`
Verifica a conectividade entre o app e o servidor (heartbeat).

```json
{
  "usuario_id": "user_123",
  "app_versao": "1.0.0",
  "bateria_percentual": 87
}
```
