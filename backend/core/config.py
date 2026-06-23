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

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
