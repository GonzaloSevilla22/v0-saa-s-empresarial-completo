from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    supabase_jwt_secret: str = "dev-secret"
    app_env: str = "development"
    database_url: str = ""
    redis_url: str = ""
    backend_allowed_origin: str = "*"
    # Payments — webhook MercadoPago (server-to-server)
    supabase_url: str = ""           # https://<ref>.supabase.co
    service_role_key: str = ""       # para Supabase Admin REST API
    mercadopago_webhook_secret: str = ""
    mercadopago_access_token: str = ""
    # CAE relay trigger — shared secret for the machine endpoint POST /fiscal/documents/process-pending-cron
    # Read from env var RELAY_SECRET. If unset/empty the endpoint rejects ALL calls (fail-closed).
    relay_secret: str | None = None

    # ── v22-afip-delegation-billing: Certificado representante de la plataforma (CRÍTICO) ──
    # Governance CRÍTICO: la clave privada aquí permite facturar por CUALQUIER usuario
    # representado. NUNCA exponer al cliente, NUNCA loguear. Leer solo server-side.
    # Configurar en Render secrets / env vars del deployment:
    #   AFIP_PLATFORM_CERT: contenido PEM del certificado del representante
    #   AFIP_PLATFORM_KEY:  contenido PEM de la clave privada del representante
    #   AFIP_PLATFORM_CUIT: CUIT del representante (ej. "20422662457" para AliadataProd)
    afip_platform_cert: str = ""   # PEM del certificado (BEGIN CERTIFICATE)
    afip_platform_key:  str = ""   # PEM de la clave privada — CRÍTICO, nunca loguear
    afip_platform_cuit: str = ""   # CUIT del representante (sin guiones o con)

    # ── fiscal-receptor-iva-relay: umbral de identificación obligatoria del receptor ──
    # RG 5824/2026 (vigente 12/02/2026): a partir de este importe, ARCA exige identificar
    # al consumidor final (CUIT/DNI). Por debajo, DocTipo=99 (sin identificar) es válido.
    # Constante de config (Gate 0 OQ-3): actualizar acá cuando una RG futura cambie el monto.
    afip_consumidor_final_threshold: int = 10_000_000

    # ── v31-tenancy-pool-rls Paso 1 (D1/D8) ──────────────────────────────
    # Palanca de rollout, APAGADA por defecto: mergear deja el código
    # inerte. Encenderla en Render (decisión del PO, tasks.md 4.4) hace que
    # get_db_conn envuelva cada request en una transacción explícita con
    # los claims de request.jwt.claims en alcance TRANSACCIONAL
    # (equivalente a SET LOCAL) en vez del alcance de sesión actual — ver
    # backend/core/database.py::get_db_conn y design.md D1/D2.
    # Apagar es la reversión más rápida disponible: reinicio del servicio
    # (~50s), sin rebuild ni redeploy.
    tenancy_tx_scope_enabled: bool = False
    # D4: idle_in_transaction_session_timeout con el mismo alcance
    # transaccional, para que un request colgado no retenga la transacción
    # (y la conexión física) indefinidamente. Sólo aplica cuando
    # tenancy_tx_scope_enabled=True. Literal de intervalo de Postgres.
    tenancy_tx_idle_timeout: str = "30s"

    # mp-real-subscriptions (hallazgo 2026-08-01, sign-off PO): `extra="ignore"`
    # es obligatorio. Sin esto, pydantic-settings v2 rechaza CUALQUIER variable
    # presente en `.env` o en el entorno que no tenga un campo declarado acá
    # (`ValidationError: extra_forbidden`) — y lo hace al importar el módulo,
    # rompiendo TODA la app (y toda la suite de tests que la importe
    # transitivamente). Se disparó en vivo al cargar `MERCADOPAGO_TEST_ACCESS_TOKEN`
    # en `backend/.env` para la validación de sandbox de mp-real-subscriptions —
    # ninguna variable nueva de config, sandbox o de un dev distinto debería
    # poder tumbar el arranque del backend.
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


settings = Settings()
