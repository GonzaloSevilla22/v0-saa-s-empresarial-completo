## Why

`multiusuario-operativo` (archivado 2026-10-17, demo real del PO PASÓ el 2026-11-06) dejó cuatro hallazgos de seguridad sobre la invitación a una cuenta: el token se guarda en claro en dos tablas, el dueño puede escribir invitaciones por PostgREST saltando la RPC, el token viaja en el path de la API y de la pantalla, y la lista de invitaciones no muestra una entrega fallida. Ninguno es explotable solo (la aceptación exige la identidad invitada), pero la invitación es el único camino por el que alguien entra a un negocio ajeno y el flujo ya tiene usuarios reales. El PO lo aprobó textualmente el 2026-11-06: *«dale hacelo»*.

Governance **CRÍTICO** (auth / membresías): análisis y propose acá; el apply corre con este mismo sign-off.

## What Changes

- **El token deja de guardarse en claro** (`invitation-token-hash`). `account_invitations.token` se reemplaza por `token_hash` (sha256 hex, índice único); el token se genera en `rpc_send_invitation_email` en **cada** envío (también en el primero), se devuelve una sola vez al invitador para «Copiar link» y viaja a la plantilla en `email_logs.metadata.token`, de donde un disparador lo **retira** apenas la fila deja de estar pendiente (enviada, fallida o parcial). La vista previa y la aceptación buscan por hash. Backfill: se hashea en el lugar lo que haya (hoy 1 fila, aceptada), nada se invalida. **BREAKING interno**: `rpc_invite_member` deja de devolver `token` (su único caller ya usa el del envío).
- **`account_invitations` queda sólo para las funciones del dominio**. Se retira la policy `account_invitations_owner_all` (`FOR ALL`) y se revocan todos los privilegios de tabla a `anon` y `authenticated` (hoy `authenticated` tiene `SELECT/INSERT/UPDATE/DELETE/TRUNCATE` y `anon` `SELECT`). Nadie lee la tabla por PostgREST: el listado ya es `rpc_list_account_invitations`. Gate SQL permanente.
- **El token sale del path**. **BREAKING interno** de la API: `GET /invitations/{token}` → `POST /invitations/preview` y `POST /invitations/{token}/accept` → `POST /invitations/accept`, ambos con `{ "token": … }` en el cuerpo. La pantalla pública pasa de `/invitacion/<token>` a `/invitacion#<token>`: el fragmento nunca llega a un servidor; la página lo guarda en una cookie `httpOnly` de vida corta mediante una Server Action, limpia la URL y hace la vista previa y la aceptación por Server Actions que leen esa cookie. El `next` del ingreso, el registro y la verificación de email pasa a ser la constante `/invitacion` (sin token). La ruta `/invitacion/[token]` se retira.
- **La lista muestra el estado de la entrega** (`invitation-delivery-status`). `rpc_list_account_invitations` suma `last_delivery_status` (`queued` / `sent` / `failed` / `unconfirmed`) y `last_delivery_at`, sin exponer el detalle del proveedor. `/organizacion/invitar` muestra el estado con un distintivo y, si la última entrega falló, destaca «Reenviar» con una explicación. Un envío fallido no cuenta para el enfriamiento de 10 minutos (sí para el tope diario).
- Migración única **`20261094000001_invitaciones_hardening.sql`**, que reescribe cinco funciones desde su cuerpo VIVO con preflight por md5 y retira el eslabón de `20261085000001` de `KPI_Validation.yml`.

**Fuera de alcance (declarado)**: la ligadura por email exacto en minúsculas queda como está (invitar a `ab@gmail.com` y registrarse como `a.b@gmail.com` sigue terminando en «no disponible»; la salida es reinvitar). Tampoco se registran rebotes posteriores a la aceptación del proveedor (Resend sin webhook de eventos): «Enviado» significa que el proveedor aceptó el correo. Los `TRUNCATE` que `authenticated` conserva en otras 62 tablas quedan como candidato aparte.

## Capabilities

### New Capabilities

_(ninguna)_

### Modified Capabilities

- `account-invitation-flow`: el token no se conserva en claro (nuevo), la tabla sólo se escribe por las funciones del dominio (nuevo), el enlace lleva el token en el fragmento y la API lo recibe en el cuerpo (modifica la pantalla de aceptación), la lista muestra el estado de la última entrega (modifica la gestión de pendientes) y un envío fallido no cuenta para el enfriamiento (modifica los topes).
- `transactional-email-delivery`: la plantilla `org_invite` arma el enlace con el token en el fragmento (`APP_URL/invitacion#<token>`).

## Impact

- **DB**: `account_invitations` (`token` → `token_hash`, índice único, policy y privilegios), `email_logs` (disparador `BEFORE UPDATE` que retira `metadata.token` de `org_invite` al salir de `pending`; purga de las filas ya no pendientes), helper interno `_invitation_token_hash(text)` sin `EXECUTE` para los roles de aplicación; reescritas `rpc_invite_member`, `rpc_send_invitation_email`, `rpc_invitation_preview`, `rpc_accept_invitation` (misma firma) y `rpc_list_account_invitations` (cambia el tipo de retorno → `DROP FUNCTION` + `CREATE`). `rpc_revoke_invitation` no cambia.
- **Backend**: `backend/routers/invitations.py`, `backend/services/invitations.py`, `backend/repositories/invitation_repository.py`, `backend/schemas/invitations.py` + tests.
- **Edge Function**: `supabase/functions/_shared/email-templates.ts` (enlace con fragmento) → redeploy de `send-email` (lo hace `deploy.yml`).
- **Frontend**: `app/invitacion/page.tsx` (nueva) y retiro de `app/invitacion/[token]/`, Server Actions de la invitación, `components/invitations/InvitationAcceptance.tsx`, `components/invitations/PendingInvitations.tsx`, `hooks/data/use-invitations.ts`, `lib/auth/invitation-next.ts`, `lib/auth/route-access.ts`, `lib/supabase/middleware.ts`, `lib/query-keys.ts`, `app/auth/actions.ts`, `lib/database.types.ts`.
- **CI**: `.github/workflows/KPI_Validation.yml` (retira el eslabón de `20261085000001`, suma el de `20261094000001` y el gate nuevo), `supabase/tests/test_membership_rpcs_pivot_rewrite.sql` (reconverge-5), gates ajustados `test_multiusuario_invitaciones.sql` y `test_accept_invitation_binding.sql`, gate nuevo `test_invitaciones_hardening.sql`.
- **Superficie frontend**: `/organizacion/invitar` (ruta y entrada de menú existentes: Organización → Invitar) con el estado de entrega, y la pantalla pública `/invitacion` a la que se llega desde el email. Escritorio y móvil, tema claro y oscuro.
- **Producción (medido 2026-11-06, sólo SELECT)**: 1 invitación en toda la historia (aceptada), 0 pendientes; 1 email `org_invite` (`sent`, con token en `metadata`); `email_logs` total 546 `sent` / 25 `failed`.
