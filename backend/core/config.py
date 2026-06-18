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
    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
