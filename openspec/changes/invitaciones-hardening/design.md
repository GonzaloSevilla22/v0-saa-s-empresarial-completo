## Context

La invitación a una cuenta quedó completa con la tanda C de `multiusuario-operativo` (migración `20261085000001`, PR #654) y la demo real del PO pasó el 2026-11-06 (7/7). El flujo vivo es:

1. `POST /members/invitations` (FastAPI) → `rpc_invite_member` crea la fila con un token en claro (`account_invitations.token`) → `rpc_send_invitation_email` (misma transacción) encola el email `org_invite` en `email_logs` con `metadata.token` en claro.
2. El disparador `on_email_log_insert` (`send_email_log_webhook`) hace `net.http_post` a la Edge Function `send-email` con `to_jsonb(NEW)` en el cuerpo; la función arma la plantilla con `metadata.token`, envía por Resend y actualiza la fila a `sent` / `failed` / `partial`. El token queda para siempre en `metadata`.
3. El invitado abre `APP_URL/invitacion/<token>`; la pantalla llama `GET /invitations/{token}` y `POST /invitations/{token}/accept`. El token aparece en el access log de Render, en el log de requests de Vercel, en el historial del navegador, en `?next=/invitacion/<token>` del ingreso y del registro, y en el enlace de confirmación de Supabase (`emailRedirectTo`).
4. `/organizacion/invitar` lista con `rpc_list_account_invitations` (`send_count`, `last_sent_at`), sin ver si la entrega falló.

Y en paralelo, la policy original `account_invitations_owner_all` (`FOR ALL TO authenticated`, de `20260606000001`) deja al dueño hacer `INSERT/UPDATE/DELETE` directo por PostgREST sobre su cuenta, salteando el cupo, el catálogo de roles y la validación de email de `rpc_invite_member`.

### Mediciones de producción (2026-11-06, sólo `SELECT` por MCP)

- `MAX(version) = 20261093000001`, 340 migraciones. `20261094000001` libre (local: último archivo `20261093000001_productos_padre_variantes.sql`).
- `account_invitations`: **1 fila en toda la historia, `accepted`**; **0 pendientes**. Columnas: `id, account_id, email, token, status, invited_by, created_at, expires_at, role, roles, account_display_name, revoked_at, revoked_by`. Índices sobre `token`: `account_invitations_token_key` (UNIQUE) e `idx_account_invitations_token` (redundante).
- `email_logs` con `event_type = 'org_invite'`: **1 fila, `sent`, con `metadata.token`**. Total de la tabla: 546 `sent`, 25 `failed`. Constraint `UNIQUE (user_id, event_type, metadata)`; único disparador `on_email_log_insert` (AFTER INSERT).
- Policies vivas de `account_invitations`: sólo `account_invitations_owner_all` (`ALL`, `authenticated`). De `email_logs`: sólo `Admins can view email logs` (`SELECT`, administradores de plataforma).
- Privilegios de tabla sobre `account_invitations`: **`authenticated`: SELECT, INSERT, UPDATE, DELETE y TRUNCATE**; **`anon`: SELECT** (inerte por RLS: no hay policy para `anon`). `TRUNCATE` no pasa por RLS. PostgREST no emite `TRUNCATE`, así que hoy no es alcanzable desde la API, pero es un privilegio que la tabla no necesita. Hallazgo lateral: `authenticated` tiene `TRUNCATE` en **63 de 81** tablas de `public` (`anon` en 0) — candidato aparte.
- Cuerpos vivos (md5 sin `\r`), que son los de partida del preflight:

| Función | `md5(prosrc)` | `md5(pg_get_functiondef)` |
|---|---|---|
| `rpc_invite_member(text,uuid,text[])` | `ff9d4a38e7dad25455d13249195263ec` | `0cec90f5fb0cdcd747c369647fdd2c1e` |
| `rpc_accept_invitation(text)` | `92abe7e8e0c66314ff6d47230a8a913c` | `09563201411b269e391c48526a11b947` |
| `rpc_send_invitation_email(uuid,text,boolean)` | `69fcdf85dbb2706ab0f212c808bf83e3` | `5a6aac3e993406b7539db52b42e3f196` |
| `rpc_list_account_invitations(uuid)` | `4b5e932632bb9f28afc31b560f8cb715` | `b225917e99bc26e19ff884c8ed517f86` |
| `rpc_invitation_preview(text)` | `59b966c0ac826c036e132c9efba5cfd2` | `3fdc685ce7e5aedae6da58641fa99197` |
| `rpc_revoke_invitation(uuid)` (no se toca) | `a2efc1f683ca2c190fa545dbaa3c2394` | `dfc9549422ebbbace8b9c2f639e040b3` |

Los dos primeros `md5(prosrc)` coinciden con los que la tanda C dejó registrados en `CHANGES.md` y en el eslabón de `KPI_Validation.yml`: nadie los redefinió desde entonces.

## Goals / Non-Goals

**Goals:**
- Que ningún almacenamiento persistente del sistema (tablas, logs de Render y Vercel, historial del navegador, parámetros `next`, enlace de confirmación de Supabase) conserve un token de invitación vigente en claro más allá del intento de entrega.
- Que `account_invitations` sólo se escriba por las funciones `SECURITY DEFINER` del dominio, con un gate permanente.
- Que el invitador vea si la última entrega falló y pueda reenviar sin esperar el enfriamiento.
- Cero regresión del flujo que el PO probó: invitar, link sin sesión, registro, aceptar, Tablero del negocio, reenviar y revocar.

**Non-Goals:**
- La ligadura por email exacto (minúsculas): queda como está.
- Rebotes posteriores a la aceptación del proveedor (no hay webhook de eventos de Resend).
- Revocar `TRUNCATE` de `authenticated` en las otras 62 tablas (candidato `revoke-truncate-app-roles`).
- Cambiar los topes (OQ-8 de `multiusuario-operativo`) más allá de excluir los envíos fallidos del enfriamiento.
- `query-keys-por-cuenta` (candidato del fix `cambio-de-negocio-cache-vieja`).

## Decisions

### D1 — `token_hash` (sha256 hex) reemplaza a `token`; la columna en claro se elimina
`account_invitations.token_hash text` con índice único parcial (`WHERE token_hash IS NOT NULL`); `DROP COLUMN token` (arrastra sus dos índices). Hash con un helper interno `public._invitation_token_hash(p_token text) RETURNS text IMMUTABLE` = `encode(sha256(convert_to(p_token, 'UTF8')), 'hex')` (built-in de PG ≥ 11, sin depender de `pgcrypto`), `SECURITY INVOKER`, sin `EXECUTE` para `PUBLIC`/`anon`/`authenticated` (el chequeo (4) del gate de ACLs barre por el prefijo `_`); lo usan tres funciones (envío, vista previa, aceptación), así que la Regla de Tres justifica el helper.

Sin sal ni KDF: el token son 32 bytes de `gen_random_bytes`; la fuerza bruta sobre 256 bits no es un vector, y un hash determinístico es lo que permite buscar por índice.

**Alternativas**: (a) conservar `token` con `CHECK (token IS NULL)` — evita el `DROP COLUMN` pero deja una columna muerta que invita a volver a escribirla; (b) cifrar con una clave de Vault — reversible, que es justo lo que no queremos. Se elige el `DROP`: ninguna migración vieja que la cadena de CI reaplica (`20261049`, `20261050`, `20261051`, `20261085`) hace DDL sobre `token` (sólo cuerpos plpgsql, que no se validan contra columnas al crearse), y `20260606000001` no se reaplica (verificado por grep del workflow). Riesgo residual en la tarea 2.1.

### D2 — El token nace en el envío, en cada envío
Hoy `rpc_invite_member` genera el token y el primer `rpc_send_invitation_email` lo reusa; con sólo el hash guardado, el envío ya no podría reconstruirlo. Por eso **`rpc_send_invitation_email` genera un token nuevo en cada envío** (el primero incluido), guarda su hash y lo pone en `metadata.token` y en el retorno (para «Copiar link», OQ-6 de `multiusuario-operativo`). `rpc_invite_member` crea la fila con `token_hash = NULL` (una invitación sin enviar no se puede aceptar; como creación y envío van en la misma transacción del request, esa fila nunca se observa) y **deja de devolver `token`** (BREAKING interno: el backend ya usa el del envío, verificado en `services/invitations.py`). `p_renew` conserva su sentido: renovar el vencimiento a 7 días y revivir una vencida; el primer envío conserva el vencimiento de la creación.

Consecuencia deliberada: el bloque (a) de `test_multiusuario_invitaciones.sql` («el primer envío NO rota el token») cambia a «cada envío emite un token nuevo y sólo su hash queda en la fila».

**Alternativa**: que `rpc_invite_member` devuelva el token y el backend se lo pase al envío — viola la regla dura de `CLAUDE.md` (el token del email sale de la base, nunca de un parámetro).

### D3 — El token se retira de `email_logs` apenas termina el intento de entrega
La plantilla necesita el token: viaja en `metadata.token` del `INSERT` y llega a `send-email` dentro del cuerpo de `net.http_post` (`to_jsonb(NEW)`), así que la función nunca vuelve a leer la fila para armar el correo. Un disparador nuevo **`trg_email_logs_strip_invite_token` `BEFORE UPDATE OF status ON email_logs`**, `WHEN (NEW.event_type = 'org_invite' AND NEW.status IS DISTINCT FROM 'pending' AND NEW.metadata ? 'token')`, hace `NEW.metadata := NEW.metadata - 'token'`. Cubre los tres desenlaces que escribe `send-email` (`sent`, `failed`, `partial`) sin tocar la Edge Function, y cualquier escritor futuro. Además, al reenviar, `rpc_send_invitation_email` retira `token` de las filas anteriores de esa misma invitación que sigan `pending` (sus tokens ya están rotados). La migración purga las filas `org_invite` no pendientes que todavía lo tengan (hoy 1).

La `UNIQUE (user_id, event_type, metadata)` no se rompe al quitar la clave: `metadata` conserva `invitation_id` y `sent_at` (`clock_timestamp()`), distintos entre envíos.

**Ventana residual aceptada**: mientras la fila está `pending` (segundos) el token existe en `email_logs` (lo ven sólo los administradores de plataforma por su policy) y en `net.http_request_queue` de `pg_net` hasta que la request sale. Una fila que quedara `pending` para siempre (Vault sin configurar, `pg_net` caído) conserva el token hasta que la invitación vence o se reenvía; la lista lo muestra como `unconfirmed` (D7).

**Alternativas**: (a) guardar en `metadata` el link ya armado — sigue siendo el mismo secreto con otra forma; (b) que `send-email` haga el `UPDATE ... metadata - 'token'` — depende de que la Edge Function se despliegue y de que el `UPDATE` no falle; el disparador es el punto de paso obligado.

### D4 — `account_invitations` sólo para las funciones del dominio
`DROP POLICY account_invitations_owner_all`; `REVOKE ALL ON public.account_invitations FROM PUBLIC, anon, authenticated` (incluye `TRUNCATE`, `REFERENCES`, `TRIGGER`); RLS sigue habilitada y sin policies para los roles de aplicación (doble cierre: privilegio y fila). `service_role` y el dueño de las funciones conservan lo suyo. Lectura: **ninguna** directa; la pantalla ya usa `rpc_list_account_invitations` y la aceptación/vista previa son RPCs. Verificado por grep: ningún consumidor de `frontend/`, `backend/` ni `supabase/functions/` lee la tabla por PostgREST (sólo `lib/database.types.ts`, que se regenera).

Gate permanente nuevo `supabase/tests/test_invitaciones_hardening.sql` (molde `test_email_logs_insert_cerrado.sql` + `test_accounts_privilege_columns.sql`): `has_table_privilege` y `has_any_column_privilege` en falso para `anon`/`authenticated` en los siete privilegios; ninguna policy de `account_invitations` para esos roles; ataque real con `SET LOCAL ROLE authenticated` + claims del dueño (`INSERT` / `UPDATE` / `DELETE` / `SELECT` → `42501`); y las seis RPCs ejecutadas de punta a punta siguen funcionando.

### D5 — La API recibe el token en el cuerpo
`POST /invitations/preview` y `POST /invitations/accept` con `InvitationTokenRequest { token: str }` (Pydantic v2, `max_length=256`). La forma del token se sigue validando en el **service** (`_reject_malformed_token`) para que un token malformado responda el **mismo 404** que uno vencido, no un 422 distinguible. Se retiran `GET /invitations/{token}` y `POST /invitations/{token}/accept` en el mismo PR, sin convivencia: hay 0 invitaciones pendientes en prod y el único cliente es el frontend propio (ventana de deploy aceptada, ver Riesgos). El access log de Uvicorn/Render registra método y path, nunca el cuerpo. Ningún `logger` del módulo imprime el token (gate por grep en el test del router).

### D6 — La pantalla pública: fragmento + cookie `httpOnly` + Server Actions
El enlace pasa a **`APP_URL/invitacion#<token>`** (plantilla y «Copiar link»). El fragmento no viaja en ninguna request HTTP, así que no queda en Vercel, Render ni en el `Referer`.

- `app/invitacion/page.tsx` (Server Component, público, `noindex` + `no-referrer` como hoy) monta un componente cliente que, al montar, lee `location.hash`, hace `history.replaceState(null, "", "/invitacion")` (el token sale del historial) y llama la Server Action `stashInvitationTokenAction(token)`, que valida la forma y guarda la cookie **`aliadata_invitation`** (`httpOnly`, `Secure` en producción, `SameSite=Lax`, `Path=/invitacion`, `Max-Age` 7 días, opciones desde `lib/supabase/cookie-options.ts`). Sin hash y sin cookie: estado «Abrí el enlace del email de invitación».
- La vista previa y la aceptación son Server Actions (`previewInvitationAction`, `acceptInvitationAction`) que leen la cookie y llaman a FastAPI desde el servidor con el token de acceso de la sesión (mismo patrón que las rutas de `app/api/billing/`); el token nunca vuelve al JS del navegador. La aceptación exitosa y un 404 definitivo **borran la cookie**. Después de aceptar, el cliente sigue con `adoptActiveAccount` como hoy.
- El `next` del ingreso, del registro y de la verificación de email pasa a ser la constante **`/invitacion`**: `safeInvitationNext` acepta exactamente esa cadena (más estrecha que la allow-list actual); `signUpAction` la re-valida. El enlace de confirmación de Supabase deja de llevar el token.
- `isInvitationPath` pasa a `pathname === "/invitacion"`; `/invitacion` sigue en `PUBLIC_PREFIXES`. Se retira `app/invitacion/[token]/`.
- Abrir la confirmación del registro en otro dispositivo o navegador ya no devuelve a la invitación (no hay cookie): la pantalla pide abrir de nuevo el enlace del email, que sigue vigente. Mismo navegador, otra pestaña: funciona (la cookie es del navegador, no de la pestaña).

**Alternativas (con costo/beneficio)**:
- (a) **Dejar el path** con `no-referrer`/`noindex` (lo de hoy, más el arreglo de la API del D5): costo cero en el frontend; el token sigue en el log de Vercel (retención corta), el historial del navegador, los `next` y el enlace de confirmación de Supabase. Aceptable porque el token solo no alcanza (identidad), pero no cumple el objetivo.
- (b-lite) **Fragmento + `sessionStorage`** y llamadas directas del navegador a FastAPI: menos piezas que la cookie, pero `sessionStorage` es por pestaña y el correo de confirmación del registro abre una pestaña nueva — se rompe justo el camino del invitado nuevo, que es el principal; `localStorage` lo arreglaría a costa de dejar el token legible por JS durante días.
- (b) **Fragmento + cookie `httpOnly` + Server Actions** (elegida): costo moderado (tres Server Actions, un componente cliente chico, reescritura del camino de datos de `InvitationAcceptance`); saca el token de todo log y almacenamiento legible por JS, y conserva el camino del registro en el mismo navegador.

### D7 — Estado de la última entrega en el listado
`rpc_list_account_invitations` cambia su tipo de retorno (suma dos columnas al final) → **`DROP FUNCTION` + `CREATE`**, nunca `CREATE OR REPLACE` (no se puede cambiar `RETURNS TABLE`), con `REVOKE`/`GRANT`/`COMMENT` re-emitidos. Columnas nuevas, derivadas del envío más reciente de esa invitación en `email_logs` (`ORDER BY created_at DESC LIMIT 1` en el mismo `LATERAL`):
- `last_delivery_status text`: `sent` (`sent` o `partial`: un único destinatario), `failed`, `queued` (`pending` con menos de 15 minutos), `unconfirmed` (`pending` con 15 minutos o más: el disparador o la Edge Function no respondieron) o `NULL` (nunca se envió);
- `last_delivery_at timestamptz`: `sent_at` si hubo entrega, si no `created_at` del envío.

`error_details` **no** se expone (puede traer texto del proveedor); la pantalla explica genéricamente. Backend: `InvitationOut` suma los dos campos opcionales (compatible en cualquier orden de deploy).

**Superficie** (`/organizacion/invitar`, ruta y menú existentes — Organización → Invitar): en cada fila de `PendingInvitations`, un distintivo con tokens semánticos («Enviado» / «En cola» / «No se pudo enviar» / «Sin confirmación»), la fecha en la línea secundaria, y con `failed` o `unconfirmed` el botón «Reenviar» pasa a variante primaria con el texto de ayuda «El email no llegó a salir. Revisá la dirección y reenviala.». Lectores de pantalla: el estado va en el `aria-label` de la fila. Verificación visual en 375 px y ≥1024 px, claro y oscuro.

### D8 — Un envío fallido no cuenta para el enfriamiento
El enfriamiento de 10 minutos por invitación ignora los envíos cuya fila quedó `failed`; el tope diario de 20 por cuenta los sigue contando (cada intento le cuesta al proveedor). Sin esto, el «Reenviar» destacado del D7 respondería 429 durante 10 minutos justo cuando más se lo necesita.

### D9 — Migración única, tanda única
`20261094000001_invitaciones_hardening.sql`: (0) preflight por `md5(prosrc)` de las cinco funciones (acepta el de partida de la tabla de arriba o el propio; aborta con el md5 observado si no); (1) columna, backfill y `DROP COLUMN` guardados por existencia (idempotente); (2) helper; (3) cinco reescrituras desde el cuerpo vivo (cuatro `CREATE OR REPLACE` con la misma firma, el listado con `DROP` + `CREATE`); (4) disparador de `email_logs` y purga; (5) policy y privilegios; (6) ACLs re-emitidas; (7) introspección que aborta si algo no quedó (sin `token`, sin policy, sin privilegios de tabla, una sola definición viva por función, ACLs sin `anon`/`PUBLIC`, el helper sin `EXECUTE` para `authenticated`, el disparador presente).

**Tanda única** (un PR de apply con DB + backend + Edge Function + frontend): son cuatro piezas que cambian juntas el mismo contrato (el enlace, las rutas de la API y el retorno del listado), con 0 invitaciones pendientes en prod; separarlas obligaría a convivencia de rutas y de formatos de enlace para proteger un tráfico que no existe. Los cambios que sí cruzan deploys son compatibles en cualquier orden: el listado suma columnas opcionales y `rpc_invite_member` sin `token` no rompe al backend viejo (ya no lo usa).

## Risks / Trade-offs

- [Ventana de deploy: Render (backend), Vercel (frontend) y la Edge Function salen a minutos de distancia; un invitado que abra un enlace en esa ventana puede ver un 404 o el estado «abrí el enlace del email»] → 0 pendientes hoy; el enlace sigue vigente y basta reabrirlo; el apply verifica el orden real de `deploy.yml` y lo anota.
- [La cadena de reaplicación de `KPI_Validation.yml` y el `\i` de `test_membership_rpcs_pivot_rewrite.sql` reinstalan cuerpos viejos que leen `token`] → la tarea 6 retira el eslabón de `20261085000001` (regla escrita en el propio workflow: tiene preflight md5 sobre funciones que esta migración redefine), suma el de `20261094000001` al final y el reconverge-5 del gate; el preflight de esta migración acepta los cuerpos de la tanda C como partida, así que reconverge solo.
- [Un escáner de enlaces del correo (Safe Links) descarta el fragmento] → la pantalla sin hash ni cookie explica que hay que abrir el enlace desde el email; la mayoría de los reescritores conserva el fragmento. Si el humo real lo contradice, la alternativa (a) es un retroceso barato (OQ-1).
- [Confirmar el registro en otro dispositivo ya no vuelve a la invitación] → mensaje explícito y el enlace del email sigue vigente.
- [El disparador nuevo sobre `email_logs` toca una tabla con tráfico de todos los correos] → `WHEN` filtra por `event_type = 'org_invite'` antes de ejecutar nada; `EXPLAIN` no aplica (disparador por fila), se mide en el humo.
- [Ventana `pending` con el token en `email_logs` y en la cola de `pg_net`] → aceptada y declarada (D3); sólo la leen administradores de plataforma.

## Migration Plan

1. Merge del PR de apply → `deploy.yml`: build de Next, `supabase db push --include-all` (`20261094000001`), `functions deploy` (plantilla) y deploy de Render.
2. Verificación post-merge en prod (sólo `SELECT`): `MAX(version) = 20261094000001`; columna `token` ausente y `token_hash` presente; 0 policies y 0 privilegios de tabla de `anon`/`authenticated` sobre `account_invitations`; 0 filas `org_invite` no pendientes con `metadata ? 'token'`; `md5(prosrc)` de las cinco funciones = los del PR; una sola definición viva por función; ACLs sin `anon`/`PUBLIC`; disparador presente; deploy de Render del commit.
3. Humo real del PO (`docs/pendientes-manuales-po.md`): invitar, abrir el enlace sin sesión (la URL queda en `/invitacion`), registrarse, aceptar; ver el estado «Enviado»; reenviar.

**Rollback**: restaurar los cinco cuerpos de partida (guardados en `evidence/cuerpos-previos/` por el apply), la policy original y los privilegios previos; `ADD COLUMN token text` vuelve vacía (los tokens en claro no se pueden reconstruir: las invitaciones pendientes al momento del rollback se reenvían). Frontend/backend por revert del PR.

## Open Questions

Todas resueltas por la opción recomendada — **Sign-off del PO por mandato (2026-11-06: "dale hacelo")**. Las marcadas con ⚠ cambiarían el diseño si el PO opinara distinto.

- ⚠ **OQ-1 — Forma del enlace público.** (a) dejar el path; (b-lite) fragmento + `sessionStorage`; **(b) fragmento + cookie `httpOnly` + Server Actions** ← recomendada y firmada (D6). Con (a) desaparecen D6 y la mitad del frontend; con (b-lite) se pierde el camino del registro con confirmación.
- ⚠ **OQ-2 — Columna en claro.** **(a) `DROP COLUMN token`** ← firmada (D1); (b) conservarla vacía con `CHECK (token IS NULL)`. (b) sólo cambia la tarea 2.1.
- **OQ-3 — Backfill.** **(a) hashear en el lugar** ← firmada (hoy 1 fila aceptada; una pendiente al momento de aplicar seguiría funcionando con su enlace); (b) invalidar las pendientes (obliga a reenviar).
- **OQ-4 — `email_logs.metadata.token`.** **(a) disparador `BEFORE UPDATE` que lo retira al salir de `pending`** ← firmada (D3); (b) que lo haga la Edge Function; (c) guardar el link armado.
- **OQ-5 — Lectura directa de `account_invitations`.** **(a) ninguna; todo por RPC** ← firmada (D4); (b) conservar un `SELECT` de dueño sin la columna del hash.
- ⚠ **OQ-6 — Convivencia de las rutas viejas de la API.** **(a) retirarlas en el mismo PR** ← firmada (D5); (b) mantenerlas 30 días con aviso en logs (molde del reenviador de MP). (b) agrega un tramo de convivencia y su retiro con fecha.
- **OQ-7 — Envío fallido y enfriamiento.** **(a) no cuenta para el enfriamiento, sí para el tope diario** ← firmada (D8); (b) cuenta para ambos.
- **OQ-8 — Detalle del error de entrega.** **(a) sólo el estado, sin `error_details`** ← firmada (D7); (b) mostrar el texto del proveedor.
- **OQ-9 — Tandas.** **(a) tanda única** ← firmada (D9); (b) DB + backend primero y frontend después.
