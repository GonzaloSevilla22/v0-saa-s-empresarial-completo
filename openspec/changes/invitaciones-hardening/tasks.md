> Governance **CRÍTICO** (auth / invitaciones). Sign-off del PO por mandato (2026-11-06: *«dale hacelo»*), OQ-2..OQ-9 por la opción recomendada (`design.md` §Open Questions). **Tanda única** (D9): un PR de apply con DB + backend + frontend (la Edge Function no cambia). **OQ-1 resuelta por el PO (2026-11-06): la URL pública `/invitacion/<token>` se conserva** (D6).
>
> **TDD estricto**: cada grupo arranca en RED (test o gate que falla por la razón correcta contra el código de `main`), luego GREEN, triangulación y refactor. Evidencia en `openspec/changes/invitaciones-hardening/evidence/` (`red.log`, `mutantes.log`, cadena de KPI, capturas).
>
> Migración reservada: **`20261094000001_invitaciones_hardening.sql`** (prod `MAX(version) = 20261093000001` el 2026-11-06; re-verificar al empezar).

## 0. Checkpoints antes de escribir código

- [ ] 0.1 Re-medir en prod (sólo `SELECT`): `MAX(version)`, invitaciones por estado (esperado 1 aceptada, 0 pendientes), filas `org_invite` por estado y con `metadata ? 'token'`, policies de `account_invitations` y `email_logs`, privilegios de tabla de `anon`/`authenticated`. Si hay invitaciones pendientes, anotarlo (OQ-3: se hashean en el lugar y siguen funcionando).
- [ ] 0.2 `md5(replace(prosrc, E'\r',''))` y `md5(replace(pg_get_functiondef(oid), E'\r',''))` en prod de las seis funciones de invitación contra la tabla de `design.md` §Context; si alguna difiere, PARAR y rebasar sobre el cuerpo vivo. Guardar los cinco cuerpos de partida completos en `evidence/cuerpos-previos/` (son el rollback).
- [ ] 0.3 Construir la base local con `supabase db reset` y verificar que los md5 locales de `prosrc` (sin `\r`) == prod.
- [ ] 0.4 Grep de consumidores de `account_invitations.token`, de `token` en `rpc_invite_member` (retorno) y de `/invitations/` y `/invitacion/` en `frontend/`, `backend/`, `supabase/functions/`, `supabase/tests/`, `scripts/` y `.github/workflows/`; anotar la lista en `evidence/callers.txt`. Todo caller de la lista se migra en este PR (regla: al endurecer un contrato, migrar TODOS los callers).
- [ ] 0.5 Grep de `KPI_Validation.yml` por los nombres de las cinco funciones reescritas y por `20261085000001`: confirmar el eslabón con preflight md5 de `20261085000001` (líneas ~1733-1788) y cualquier otro que las nombre. Verificar que ningún paso de la cadena reaplica `20260606000001` (DDL sobre `token`).
- [ ] 0.6 Safety net: correr y anotar el baseline de `test_multiusuario_invitaciones.sql`, `test_accept_invitation_binding.sql`, `test_invite_member_roles_and_plan_gate.sql`, `test_membership_rpcs_pivot_rewrite.sql`, `backend/tests/test_invitations*.py`, `frontend/__tests__/send-email-templates.test.ts`, `invitation-next.test.ts`, los tests de `components/invitations/` y de `route-access`. Un fallo preexistente se reporta, no se arregla.

## 1. Gate SQL nuevo (RED)

- [ ] 1.1 Escribir `supabase/tests/test_invitaciones_hardening.sql` (molde `test_email_logs_insert_cerrado.sql` / `test_accounts_privilege_columns.sql`; conteo de bloques ejecutados con aserción final):
  - (a) `account_invitations` no tiene columna `token` y sí `token_hash` con índice único; `rpc_send_invitation_email` devuelve un token cuyo `_invitation_token_hash` es el `token_hash` de la fila, y la fila no contiene el token en ninguna columna.
  - (b) cada envío (primero y reenvío) emite un token distinto; sólo el último acepta; el primero da el mismo `P0404` que uno vencido.
  - (c) `email_logs`: la fila nueva lleva `metadata.token`; al pasarla a `sent`, `failed` y `partial` (tres casos) pierde la clave; una fila de otro `event_type` con una clave `token` en `metadata` NO se toca; al reenviar, las filas `pending` anteriores de esa invitación pierden la clave.
  - (d) privilegios: `has_table_privilege` falso para `anon` y `authenticated` en `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`; `has_any_column_privilege` falso; ninguna policy de `account_invitations` con `anon`/`authenticated`/`public` en `roles`.
  - (e) ataque real: con `SET LOCAL ROLE authenticated` y los claims del DUEÑO, `INSERT` (sin cupo), `UPDATE` de `roles`, `DELETE` y `SELECT` directos fallan con `42501`; 0 filas cambiadas.
  - (f) las seis RPCs siguen funcionando de punta a punta con roles reales (dueño invita, administrador lista y revoca, el invitado ve la vista previa y acepta por el token del envío; la aceptación activa el negocio).
  - (g) listado: `last_delivery_status` = `NULL` sin envío, `queued` con `pending` reciente, `unconfirmed` con `pending` de 15 minutos o más (fixture con `created_at` corrido), `sent` con `sent` y con `partial`, `failed` con `failed`; toma el envío MÁS RECIENTE; sigue sin exponer token ni `error_details`.
  - (h) enfriamiento: un envío `failed` hace 1 minuto no bloquea el reenvío; uno `sent` hace 1 minuto sí (`P0439 invitation_cooldown`); los `failed` cuentan para el tope diario.
  - (i) ACLs: el helper `_invitation_token_hash` sin `EXECUTE` para `PUBLIC`/`anon`/`authenticated`; las seis funciones de invitación sin `anon`/`PUBLIC` y con `authenticated`; una sola definición viva de cada una.
- [ ] 1.2 Correrlo contra la base de `main`: debe fallar por la razón correcta en cada bloque (guardar `evidence/red.log`).

## 2. Migración `20261094000001_invitaciones_hardening.sql` (GREEN)

- [ ] 2.1 Bloque 0, preflight por `md5(prosrc)` sin `\r` de las cinco funciones reescritas: acepta el de partida (`design.md` §Context) o el de esta migración, aborta con el md5 observado si no; imprime `N cuerpos de partida verificados por md5, M ya reaplicados`.
- [ ] 2.2 Columna: `ADD COLUMN IF NOT EXISTS token_hash text`; si la columna `token` existe (SQL dinámico guardado por `information_schema`): backfill `token_hash = _invitation_token_hash(token)` donde `token IS NOT NULL`, luego `DROP COLUMN token` (arrastra `account_invitations_token_key` e `idx_account_invitations_token`); `CREATE UNIQUE INDEX IF NOT EXISTS ... (token_hash) WHERE token_hash IS NOT NULL`; `COMMENT ON COLUMN`. Idempotente (OQ-2 a, OQ-3 a).
- [ ] 2.3 Helper `public._invitation_token_hash(text) RETURNS text LANGUAGE sql IMMUTABLE` (`encode(sha256(convert_to(p_token,'UTF8')),'hex')`), `SECURITY INVOKER`, `SET search_path`, `REVOKE ALL ... FROM PUBLIC, anon, authenticated`; `COMMENT`.
- [ ] 2.4 `rpc_invite_member(text,uuid,text[])` desde el cuerpo VIVO: inserta `token_hash = NULL`, deja de generar y devolver `token`; todo lo demás idéntico (`CREATE OR REPLACE`, misma firma; `COMMENT` vivo conservado y ampliado).
- [ ] 2.5 `rpc_send_invitation_email(uuid,text,boolean)` desde el cuerpo VIVO: token nuevo en CADA envío (`gen_random_bytes(32)`), guarda sólo su hash; `p_renew` sigue renovando el vencimiento y reviviendo una vencida; el enfriamiento excluye `email_logs.status = 'failed'` (D8), el tope diario no; antes del `INSERT`, `UPDATE email_logs SET metadata = metadata - 'token'` de las filas `pending` previas de esa invitación; el orden autoridad → estado → topes → escritura y el destinatario `v_inv.email` intactos.
- [ ] 2.6 `rpc_invitation_preview(text)` y `rpc_accept_invitation(text)` desde el cuerpo VIVO: buscan por `token_hash = _invitation_token_hash(p_token)`; el resto idéntico (mismo `P0404`, `FOR UPDATE`, ligadura a la identidad, activación de la cuenta).
- [ ] 2.7 `rpc_list_account_invitations(uuid)`: `DROP FUNCTION` + `CREATE` (cambia `RETURNS TABLE`, nunca `CREATE OR REPLACE`) desde el cuerpo VIVO, sumando al final `last_delivery_status text` y `last_delivery_at timestamptz` (D7), derivados del envío más reciente en el mismo `LATERAL`; `REVOKE`/`GRANT`/`COMMENT` re-emitidos.
- [ ] 2.8 Disparador `trg_email_logs_strip_invite_token` `BEFORE UPDATE OF status ON public.email_logs FOR EACH ROW WHEN (...)` con su función `SECURITY INVOKER` (sin `EXECUTE` para roles de aplicación); purga: `UPDATE email_logs SET metadata = metadata - 'token' WHERE event_type = 'org_invite' AND status <> 'pending' AND metadata ? 'token'` (hoy 1 fila). `DROP TRIGGER IF EXISTS` antes de crear.
- [ ] 2.9 `DROP POLICY IF EXISTS account_invitations_owner_all`; `REVOKE ALL ON public.account_invitations FROM PUBLIC, anon, authenticated`; RLS sigue habilitada (aserción).
- [ ] 2.10 ACLs re-emitidas de las seis funciones (`REVOKE ... FROM PUBLIC, anon` / `GRANT ... TO authenticated, service_role`).
- [ ] 2.11 Bloque de introspección final que aborta si: existe `token`; falta `token_hash` o su índice; hay policies o privilegios de tabla para los roles de aplicación; alguna función de invitación tiene más de una definición, `anon`/`PUBLIC` con `EXECUTE` o `authenticated` sin él; el helper es ejecutable por `authenticated`; falta el disparador; `rpc_send_invitation_email` no tiene el guard de autoridad antes del `INSERT` en `email_logs`. Imprime un OK con marcador literal propio.
- [ ] 2.12 Aplicar dos veces sobre la base local: la segunda pasada informa `0 cuerpos de partida ..., 5 ya reaplicados` y `schema_snapshot` idéntico. Gate de 1.1 en VERDE.
- [ ] 2.13 Mutantes (guardar `evidence/mutantes.log`, todos deben matarse): policy `FOR ALL` restaurada; `GRANT SELECT` a `authenticated`; `GRANT TRUNCATE` a `authenticated`; columna `token` restaurada y escrita; envío que reusa el token en el primer envío; disparador sin `partial`; disparador que borra `token` de cualquier `event_type`; enfriamiento que cuenta `failed`; listado que no ordena por el envío más reciente; helper ejecutable por `authenticated`.

## 3. Gates existentes ajustados a propósito

- [ ] 3.1 `test_multiusuario_invitaciones.sql`: el bloque (a) pasa de «el primer envío NO rota el token» a «cada envío emite un token nuevo y la fila sólo guarda su hash»; todo lugar que leía `account_invitations.token` toma el token del retorno del envío. Documentar el cambio en el encabezado del gate.
- [ ] 3.2 `test_accept_invitation_binding.sql`: obtiene el token del retorno de `rpc_send_invitation_email` (no de la tabla); el resto de los bloques idénticos.
- [ ] 3.3 `test_membership_rpcs_pivot_rewrite.sql`: suma **Fase 13b-reconverge-5** `\i supabase/migrations/20261094000001_invitaciones_hardening.sql` después del reconverge-4 (el `\i` de `20261085000001` reinstala los cuerpos de la tanda C, que leen `token`; el preflight de `20261094000001` los acepta como partida). Documentar en el comentario.
- [ ] 3.4 Correr los cuatro gates de invitación + el nuevo en el orden de la cadena: verdes.

## 4. Backend (FastAPI, tres capas)

- [ ] 4.1 RED en `backend/tests/test_invitations.py`: `POST /invitations/preview` y `POST /invitations/accept` con `{ "token": ... }` responden como hoy (200, 404 idéntico para token vencido, rotado, de otra identidad o malformado, 409 ya miembro); `GET /invitations/{token}` y `POST /invitations/{token}/accept` ya no existen (404/405); un token malformado en el cuerpo da el MISMO 404 que uno vencido (no 422); el listado devuelve `last_delivery_status` y `last_delivery_at`; ningún `logger` del módulo recibe el token (captura con `caplog` sobre preview, accept, create y resend).
- [ ] 4.2 GREEN: `schemas/invitations.py` (`InvitationTokenRequest` con `token: str` `max_length=256`; `InvitationOut` suma los dos campos opcionales), `routers/invitations.py` (rutas nuevas, retiro de las viejas, docstring del módulo), `services/invitations.py` (sin cambios de lógica: `_reject_malformed_token` sigue siendo la única validación de forma), `repositories/invitation_repository.py` (sin cambios de RPC).
- [ ] 4.3 `backend/tests/test_invitations_integration.py` contra la base real: el token sale del envío; la fila guarda el hash; reenviar invalida el anterior; el registro del envío conserva el token mientras está `pending` y lo pierde al marcarlo `sent`; el listado trae el estado de entrega.
- [ ] 4.4 Backend completo como en CI (coverage ≥ 87 %, módulos de invitación al 100 %) e integración contra la base local.

## 5. Plantilla del email (sin cambios, regresión)

- [ ] 5.1 Confirmar con `frontend/__tests__/send-email-templates.test.ts` (sin tocar la plantilla) que el botón de `org_invite` sigue siendo `APP_URL + "/invitacion/" + encodeURIComponent(token)` con el token del envío, y que los casos existentes (token sin forma → sin botón, URL ajena ignorada, escape del nombre) siguen verdes. Si la plantilla no cambia, `send-email` no necesita redeploy.

## 6. CI (`KPI_Validation.yml`)

- [ ] 6.1 **RETIRAR el eslabón de reaplicación de `20261085000001`** (regla escrita en el propio bloque: una migración posterior que redefine `rpc_invite_member` / `rpc_accept_invitation` / las funciones nuevas lo rebasa; su preflight md5 abortaría contra los cuerpos de esta migración). Dejar un comentario de retiro con el motivo, como los retiros anteriores (p.ej. el de `20261086000001`).
- [ ] 6.2 Sumar al FINAL de la cadena el bloque de reaplicación de `20261094000001`: dos pasadas sin tolerancia con `0 cuerpos de partida verificados por md5, 5 ya reaplicados` en ambas, marcador de introspección, md5 de los cinco cuerpos nuevos, una sola definición por función, `schema_snapshot` idéntico; y su propia «REGLA PARA EL PR SIGUIENTE».
- [ ] 6.3 Cablear `test_invitaciones_hardening.sql` como paso del job (estricto, `ON_ERROR_STOP=1`), después de los gates de invitación existentes.
- [ ] 6.4 Cadena completa de `KPI_Validation.yml` sobre `db reset` limpio en local: todo verde (guardar `evidence/cadena-kpi.txt`); `check_backend_table_refs` y `check_frontend_table_refs` OK.

## 7. Frontend — la pantalla pública habla con la API por el cuerpo (D5, D6)

La ruta `/invitacion/[token]`, `safeInvitationNext`, `signUpAction`, `route-access`, el middleware (`no-referrer` + `noindex`), registro, ingreso, verificación de email y «Copiar link» **no cambian** (decisión del PO, D6). Nada de Server Actions ni cookie.

- [ ] 7.1 RED en los tests de `hooks/data/use-invitations`: `useInvitationPreview(token)` hace `POST /invitations/preview` con `{ token }` en el cuerpo y `useAcceptInvitation(token)` hace `POST /invitations/accept` con `{ token }`; la URL de ninguna de las dos solicitudes contiene el token (aserción sobre la ruta del mock de `pythonClient`); la vista previa sigue sin reintentar ante un 404; `queryKeys.invitations.preview` no incluye el token en la clave.
- [ ] 7.2 GREEN en `hooks/data/use-invitations.ts` y `lib/query-keys.ts` (la caché de la vista previa se distingue por un resumen no reversible o por la ruta actual, nunca por el token en claro; documentar la elección).
- [ ] 7.3 Tests de `components/invitations/InvitationAcceptance` en verde sin cambios de comportamiento: sin sesión genérico con «Ingresar»/«Crear cuenta» que vuelven a `/invitacion/<token>`, identidad correcta con vista previa y Aceptar → `adoptActiveAccount`, otra identidad / vencida con un solo mensaje, ya miembro; ajustar sólo los mocks de red a las rutas nuevas.
- [ ] 7.4 Grep de `/invitations/${` y `/invitations/{` en `frontend/`: ningún caller queda en las rutas viejas.

## 8. Frontend — estado de entrega en `/organizacion/invitar` (D7)

- [ ] 8.1 RED en los tests de `PendingInvitations`: distintivo «Enviado» / «En cola» / «No se pudo enviar» / «Sin confirmación» según `last_delivery_status` y nada si es `null`; con `failed` y `unconfirmed`, «Reenviar» en variante primaria y el texto de ayuda; el estado está en el nombre accesible de la fila; nunca se muestra texto del proveedor.
- [ ] 8.2 GREEN: tipo `InvitationRow` en `hooks/data/use-invitations.ts` (dos campos nuevos), `PendingInvitations.tsx` con tokens semánticos y componentes base (`Badge` vía cva), sin colores literales; `lib/database.types.ts` regenerado (sin `token`, con `token_hash`).
- [ ] 8.3 `tsc --noEmit` sin errores nuevos (baseline: 8 errores de 5 archivos de test ajenos); vitest completo en shards, 0 fallos nuevos.

## 9. Humo local y verificación visual

- [ ] 9.1 Humo local con build de producción (GoTrue, FastAPI real, PostgREST, Mailpit con el puente de correo de la tanda C): invitar → correo con enlace `/invitacion/<token>` → abrir sin sesión → crear cuenta → volver a la invitación → aceptar → Tablero del negocio; ingresar con el mismo usuario desde un segundo navegador sin tocar la invitación → entra al negocio; reenviar (el enlace viejo da el mensaje único); revocar; forzar una entrega `failed` (fila a mano en el puente) → la lista la muestra y «Reenviar» no espera el enfriamiento. Verificar en el access log de FastAPI que **ninguna línea** contiene el token (`grep` del token = 0); en el de `next start` aparece sólo en la ruta de la pantalla (riesgo aceptado, D6).
- [ ] 9.2 Red-team: `POST` directo a PostgREST sobre `account_invitations` con tokens de dueño, administrador, invitado y anónimo (`SELECT`/`INSERT`/`PATCH`/`DELETE` → 401/403, 0 filas); rutas viejas de la API → 404/405; token malformado, vencido y de otra identidad con cuerpo de error idéntico byte a byte.
- [ ] 9.3 Capturas de `/organizacion/invitar` (con los cuatro estados de entrega) en 375 px y ≥1024 px, tema claro y oscuro, sin desborde horizontal; contraste AA de los distintivos (gate `token-contrast-aa`); y una pasada de regresión de `/invitacion/<token>` (sin sesión, vista previa, mensaje único) en las mismas cuatro combinaciones.

## 10. Cierre del apply

- [ ] 10.1 PR del apply con la evidencia, `CHANGES.md` (ficha del change pasa a APPLY) y `docs/pendientes-manuales-po.md` (sección del humo real del PO). `CLAUDE.md` no se toca (se actualiza en el archive).
- [ ] 10.2 Post-merge en prod (sólo `SELECT`, a cargo del orquestador): `MAX(version) = 20261094000001`; sin `token`, con `token_hash`; 0 policies y 0 privilegios de tabla para `anon`/`authenticated` en `account_invitations`; 0 filas `org_invite` no pendientes con `metadata ? 'token'`; md5 de los cinco cuerpos = los del PR; ACLs; disparador presente; deploy de Render del commit (sin él las rutas nuevas dan 404).
- [ ] 10.3 [PO] Humo real: invitar a un email propio, abrir el enlace sin sesión (en la PC o el celular), registrarse o ingresar, aceptar, ingresar desde otro dispositivo sin volver a tocar la invitación, ver «Enviado» en la lista, reenviar.
- [ ] 10.4 Archive del change (spec `account-invitation-flow` sincronizada, `CLAUDE.md` ítem nuevo y fila de migraciones).
