from pydantic import model_validator
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

    # ── v31-tenancy-pool-rls Paso 2 (D6) — grupo 7 ───────────────────────
    # Palanca INDEPENDIENTE del Paso 1, APAGADA por defecto: mergear deja
    # el código inerte. Encendida: get_db_conn adopta el rol `authenticated`
    # (rolbypassrls=false, verificado en prod) con alcance TRANSACCIONAL
    # (`SET LOCAL ROLE`, NUNCA `SET ROLE` de sesión — D6/D1) en la MISMA
    # transacción del Paso 1, inmediatamente después de inyectar los claims
    # — mismo punto, no pueden divergir (D6, mitigación del "falla
    # abierto"). El rol nunca persiste más allá del COMMIT/ROLLBACK: la
    # conexión vuelve al pool como `postgres` para el siguiente request.
    # `get_service_conn` (webhook de pagos, relay CAE) NO adopta este rol
    # bajo ninguna combinación de palancas (D5) — son los 3 consumidores
    # que dependen de BYPASSRLS y la razón por la que se descartó
    # `ALTER ROLE postgres NOBYPASSRLS`.
    # Apagar es la reversión más rápida disponible: reinicio del servicio
    # (~50s), sin rebuild ni redeploy — vuelve a `postgres` con BYPASSRLS,
    # el estado actual de hoy, no uno peor (design.md "Rollback paso 2").
    tenancy_rls_role_enabled: bool = False

    # ── mp-real-subscriptions (D2bis/D6) — Camino A ──────────────────────
    # Palanca de activación, APAGADA por defecto: mergear el código de este
    # change lo deja INERTE — el flujo de upgrade sigue creando la
    # `Preference` de pago único de siempre. Mismo patrón que
    # tenancy_tx_scope_enabled: encenderla en Render es decisión del PO,
    # condicionada a DOS cosas que el agente no puede verificar solo
    # (design.md Amendment "Activación gated"):
    #   (1) v31-mp-upgrade-webhook-fix tarea 5.1 (pago E2E real) verificada.
    #   (2) Los 3 preapproval_plan de producción creados (tasks.md 9.1) y
    #       sus IDs cargados en mp_plan_id_inicial/avanzado/pro (abajo).
    # Apagarla es la reversión más rápida disponible: reinicio del servicio,
    # sin rebuild ni redeploy — los preapproval ya autorizados en MP siguen
    # cobrando igual (el rollback de código no los cancela).
    billing_subscriptions_enabled: bool = False
    # IDs de los preapproval_plan de PRODUCCIÓN (creados MANUAL PO, tasks.md
    # 9.1 — nunca en el código). El init_point se construye de forma
    # determinística a partir del ID (verificado en sandbox 2026-08-01):
    # https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=<id>
    mp_plan_id_inicial: str = ""
    mp_plan_id_avanzado: str = ""
    mp_plan_id_pro: str = ""

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

    # v31-tenancy-pool-rls Paso 2 (tasks.md 7.5) — combinación inválida por
    # diseño: `tenancy_rls_role_enabled=True` sin `tenancy_tx_scope_enabled=True`
    # no tiene NINGÚN efecto de aislamiento (D6 depende de D1: el `SET LOCAL
    # ROLE` sólo tiene alcance transaccional dentro de la transacción
    # explícita que abre el Paso 1; sin ella, bajo Supavisor en transaction
    # mode cada statement es su propia transacción implícita, así que el
    # cambio de rol se deshace de inmediato y nunca llega a cubrir la query
    # de negocio siguiente) — encenderla sola sería "creer que hay
    # aislamiento cuando no lo hay", el peor estado posible para este
    # change. Falla EXPLÍCITO al construir `Settings()` (arranque del
    # proceso), no en silencio: de las 4 combinaciones de las dos palancas,
    # ésta es la única inválida (tasks.md 7.5).
    @model_validator(mode="after")
    def _validate_tenancy_rls_role_requires_tx_scope(self) -> "Settings":
        if self.tenancy_rls_role_enabled and not self.tenancy_tx_scope_enabled:
            raise ValueError(
                "tenancy_rls_role_enabled=True requiere tenancy_tx_scope_enabled=True "
                "(v31-tenancy-pool-rls Paso 2 depende de la transacción explícita del "
                "Paso 1 — design.md D6). Encender sólo el Paso 2 es un estado inválido: "
                "sin la transacción del Paso 1, `SET LOCAL ROLE` no tiene alcance "
                "transaccional que lo sostenga hasta la query de negocio — el cambio de "
                "rol se pierde de inmediato y el backend sigue bypaseando RLS en "
                "silencio. Encendé también TENANCY_TX_SCOPE_ENABLED, o apagá "
                "TENANCY_RLS_ROLE_ENABLED."
            )
        return self


settings = Settings()
