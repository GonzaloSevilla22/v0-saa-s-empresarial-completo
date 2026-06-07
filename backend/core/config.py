from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    supabase_jwt_secret: str = "dev-secret"
    app_env: str = "development"
    database_url: str = ""
    redis_url: str = ""
    backend_allowed_origin: str = "*"
    # Payments — service_role solo para el webhook MercadoPago (server-to-server)
    service_role_key: str = ""
    mercadopago_webhook_secret: str = ""
    mercadopago_access_token: str = ""
    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
