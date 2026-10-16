## Context

### Cómo se descubrió

La auditoría de stock del 2026-10-14 (onboarding de un cliente en General Roca) corrió un humo de 75 pasos como `authenticated`, en `ROLLBACK`, contra el stack local. El bloque S20 armó una cuenta A con un vendedor y un administrador, y un tercer usuario con dos membresías: su cuenta personal y A. Material: `scratchpad/stock_audit/smoke_stock.sql` y `smoke_out_with.txt`.

| Paso | Qué se probó | Resultado |
|---|---|---|
| R3a | vendedor vende por formulario un producto del dueño | **FAIL** `P0403 Permission denied to product` |
| R3b | administrador, ídem | **FAIL** `P0403` |
| R3c | vendedor vende por POS un producto del dueño | OK |
| R3d | dueño edita una venta del vendedor | **FAIL** `P0403 sale belongs to another user` |
| R3e | dueño borra una venta del vendedor | OK |
| R3f | administrador edita una venta del dueño | **FAIL** `P0403` |
| R3g | vendedor carga una compra de un producto del dueño | **FAIL** `P0403` |
| R3h | vendedor ajusta stock a mano | rechazado por rol, **esperado** |
| R3i | vendedor transfiere stock | rechazado por la matriz FSM, **esperado** |
| R3j | usuario de dos cuentas vende por POS un producto de A | **FAIL** `P0409 stock_insuficiente`: buscó el stock en la cuenta personal (`current_account_ids()` devolvió `[personal, A]`) |
| R3k | ídem por formulario | **FAIL** `P0403` |
| R3l | ídem, venta de servicio (sin producto) | **FAIL silencioso**: la venta quedó en la **cuenta personal** |

### Base viva, medida el 2026-10-14

Fuente: producción (`gxdhpxvdjjkmxhdkkwyb`), `MAX(version) = 20261078000001`, 327 migraciones, 246 funciones en `public`. El inventario se hizo sobre el `pg_get_functiondef` de las 250 funciones de la base local (`supabase_db_v0-saa-s-empresarial-completo`, misma `MAX(version)`). Se verificó que coincide con prod comparando `md5` por grupo de nombre, sin `\r`: son idénticas **todas** salvo dos casos. La base local tiene cuatro funciones que prod ya no tiene: los dos overloads legacy de `rpc_atomic_create_sale` y `rpc_atomic_create_purchase`, más un `_gate_d89_force_p0409` que dejó un gate. Y `rpc_safe_delete_product` difiere por un `\r`. Ninguna de esas entra en el alcance.

**Patrón A — `SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1`, sin `ORDER BY`: 45 funciones**, todas `SECURITY DEFINER`:

| Dominio | Funciones |
|---|---|
| Ventas | `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_atomic_update_sale_operation`, `rpc_delete_sale_operation`, `rpc_quick_sale`, `rpc_issue_credit_note`, `rpc_emit_pending_cae`, `rpc_emit_sale_invoice` |
| Compras y gastos | `rpc_create_purchase_operation`, `rpc_create_purchase_operation_v2`, `rpc_atomic_update_purchase_operation`, `rpc_delete_purchase_operation`, `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense`, `rpc_import_expenses` |
| Cuenta corriente | `rpc_create_customer_account`, `rpc_create_supplier_account`, `rpc_register_payment_received`, `rpc_register_payment_made`, `rpc_register_supplier_charge`, `rpc_reverse_payment_received`, `rpc_reverse_payment_made`, `rpc_update_customer_charge_due_date`, `rpc_update_supplier_charge_due_date`, `rpc_set_default_payment_terms` |
| Banco | `rpc_create_bank_account`, `rpc_update_bank_account`, `rpc_register_bank_movement`, `rpc_import_bank_statement`, `rpc_open_reconciliation_session`, `rpc_close_reconciliation_session`, `rpc_create_reconciliation_match`, `rpc_undo_reconciliation_match` |
| Stock, productos, sucursales | `rpc_transfer_stock`, `rpc_reverse_stock_movement`, `rpc_bulk_upsert_products`, `rpc_import_products`, `rpc_set_default_product_category`, `rpc_open_branch`, `rpc_close_branch` |
| Reportes y billing | `rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin`, `rpc_product_profitability`, `rpc_request_subscription_cancellation` |

**Patrón B — `account_members WHERE user_id = … ORDER BY … LIMIT 1`, con tres criterios distintos: 5 sitios**:

| Sitio | Orden |
|---|---|
| `custom_access_token_hook` | `created_at, id` |
| `rpc_my_active_account_roles` | `created_at, id` |
| `rpc_my_effective_plan` | `created_at, account_id` |
| `rpc_atomic_log_ai_insight` | `account_id` |
| trigger `set_insight_account_id` (por `NEW.user_id`) | `account_id` |

**Patrón C — conjunto sin materializar que agrega o rechaza**:
- Mezclan todas las cuentas del usuario en un mismo total: `get_dashboard_financials`, `get_dashboard_critical_stock`, `get_dashboard_critical_stock_items` (`account_id IN (SELECT current_account_ids())`) y `rpc_period_comparison` (`ARRAY(SELECT current_account_ids())`).
- `rpc_import_products` hace lo contrario: **rechaza** al usuario de dos cuentas con `P0403 cuenta_ambigua`.

**Patrón D — la cuenta sale de la entidad y se valida con `IN (SELECT current_account_ids())`**. Es correcto como chequeo de pertenencia. Lo usan:
- presupuestos: `rpc_create_quote`, `rpc_update_quote`, `rpc_delete_quote`, `rpc_transition_quote` y `rpc_convert_quote_to_sale`;
- remitos: `rpc_create_sale_delivery_note`, `rpc_create_purchase_delivery_note`, `rpc_update_delivery_note`, `rpc_update_purchase_delivery_note`, `rpc_cancel_delivery_note`, `rpc_get_delivery_note` y `rpc_convert_delivery_note_to_sale`;
- los respaldos de tenencia `c28_register_cash_movement`, `c30_register_customer_account_movement` y `c30_register_supplier_account_movement`;
- `_stock_manual_adjustment` y `rpc_commercial_issuer`.

**Patrón E — guard por autor sobre entidades de la cuenta: 6 funciones.**

| Función | Guard del producto | Guard del documento |
|---|---|---|
| `rpc_create_sale_operation` | `v_product.user_id <> v_uid` → `P0403` | — |
| `rpc_create_sale_operation_v2` | ídem | — |
| `rpc_create_purchase_operation` | ídem | — |
| `rpc_create_purchase_operation_v2` (sin `EXECUTE` para `authenticated`) | ídem | — |
| `rpc_atomic_update_sale_operation` | `v_product.user_id != v_uid` | `sales.user_id != v_uid` → `P0403`, y el `FOR UPDATE` filtra `s.user_id = v_uid` |
| `rpc_atomic_update_purchase_operation` | ídem | `purchases.user_id != v_uid` |

En las seis, **el producto se busca sin filtro de cuenta** (`SELECT … FROM products WHERE id = … FOR UPDATE`). El único guard de tenencia del producto **es** el de autor. Sacarlo sin reemplazarlo deja vender o comprar productos de otra cuenta.

Además:
- `rpc_safe_delete_product` (dos overloads) filtra por `products.user_id`, pero no tiene ningún llamador en `frontend/`, `backend/` ni `supabase/functions/`.
- No son guards de entidad, y quedan como están:
  - `rpc_bulk_upsert_products(p_user_id)`, `rpc_increment_ai_usage` y `rpc_increment_export_usage` validan que el parámetro sea `auth.uid()`;
  - las 14 búsquedas de idempotencia en `operation_idempotency WHERE user_id = v_uid` y los *replays* por `sales.user_id`/`purchases.user_id` son por actor: el mismo usuario reintenta su propia clave.

**Patrón F — RPCs de operaciones sin ningún guard de rol en SQL: 8.**
- Alta: `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation`, `rpc_create_purchase_operation_v2`.
- Edición: `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`.
- Borrado: `rpc_delete_sale_operation`, `rpc_delete_purchase_operation`.

Las de gastos, el POS (`_c29_confirm_order_core`), cobros y pagos y la transferencia sí exigen `is_account_writer`. Del lado de FastAPI, los services de `sales.py`, `purchases.py` y `expenses.py` sólo llaman `require_role(auth, ["user", "admin"])`, que es el rol de **plataforma**. Hoy nada impide que un `viewer` cree, edite o borre ventas y compras. No ocurre sólo porque no existe ningún `viewer`.

**RLS**:
- **98 policies sobre 64 tablas** usan `current_account_ids()` y 45 usan `is_account_writer`.
- `account_invitations_owner_all` sólo deja ver y escribir invitaciones al dueño (`accounts.owner_user_id`): un administrador no puede listarlas por PostgREST.
- `account_members_self_select` y `account_members_same_account_select` (vía `get_account_ids_for_user`) ven todas las membresías del usuario.
- Quedan policies legacy por `company_users`/`user_id` en `product_variants` y en `suppliers` («Users can access their suppliers»). `export_logs` y `billing_events` se leen por usuario.

**Backend**:
- `core/deps.py::get_account_id` resuelve la membresía más antigua `(created_at, id)`. Se inyecta en **139** endpoints de 28 routers.
- `core/database.py::get_db_conn` empuja a la base sólo `{"sub", "role": "authenticated"}`. El `app_metadata` del token **no llega a SQL** por FastAPI; por PostgREST, sí.
- `core/guards.py::require_account_role` decide con el claim `account_roles`, que el hook calcula para **la membresía más antigua**. Si falta, consulta `rpc_my_active_account_roles()`, también la más antigua.
- `services/product_categories.py` ya documenta la divergencia: la RPC escribe en la cuenta de su `LIMIT 1` y el GET siguiente lee la de `get_account_id` (hallazgo F5, 2026-09-08).

**Edge Functions**:
- `_shared/reporting-canon.ts::resolveActiveAccountId` resuelve la más antigua `(created_at, id)`. La usan `ai-insights`, `ai-precio` y `generate-export`, y `ai-estadisticas` tiene una copia en línea.
- El resto delega en RPCs del patrón A.

**Frontend**:
- `contexts/auth-context.tsx` resuelve la más antigua `(created_at, id)`, desde la ronda 3 de la Parte C de `v3-rbac-multirole`.
- De ahí sale `user.accountId`, que consumen `useOrgRole` (37 archivos de producción lo usan, sin contar los tests) y los hooks de datos.
- No existe ningún selector de cuenta.

**Invitaciones**:
- `rpc_invite_member` tiene dos overloads. El de 2 argumentos lo usa la invitación rápida de `components/settings/TeamSection.tsx` y resuelve a `viewer`. El de 3 lo usa `/organizacion/invitar`.
- `rpc_accept_invitation` ya liga la invitación al email del aceptante: lo lee de `auth.users` si el claim no lo trae y responde con el mismo error que un token vencido. Toma `FOR UPDATE` antes de validar. **No tiene llamador.**
- `account_invitations`: **0 filas en toda la historia de prod**. El token es hex de 64 caracteres, en claro. `CHECK status IN ('pending','accepted','expired')`. Vence a los 7 días.
- `send-email` no tiene plantilla de invitación, no escapa ningún dato que interpola y arma sus links con la constante `APP_URL = "https://www.aliadata.com.ar"`.
- Dato de `v3-rbac-multirole`, que este diseño respeta: la aceptación **tiene que ir por FastAPI**. Por PostgREST el `P0404` llega como HTTP 500.

**Producción hoy**:
- 41 cuentas, 41 miembros, 41 usuarios, **0 cuentas con más de un miembro**, **0 usuarios con más de una membresía** y 0 usuarios sin membresía.
- 41 roles `owner`, tanto en `account_members` como en el pivot.
- 0 invitaciones y 0 emails `org_invite`.
- `max_users` por plan: gratis 1, inicial 2, avanzado 5, pro 10.

**Daño histórico: ninguno.** 0 filas con un autor que no sea miembro de su cuenta en 5.595 productos, 1.178 ventas, 679 compras, 259 gastos, 1.209 clientes y 5.154 movimientos de stock. Las únicas 10 discrepancias son *insights* legacy con `account_id NULL` (2026-06-11 al 18), ajenos a este change.

### Restricciones

- Governance **CRÍTICO**. Toda reescritura parte del `pg_get_functiondef` **vivo** de prod, con un *preflight* de `md5` sin `\r`. Si difiere, se parte del vivo y se anota el desvío.
- Al reescribir una RPC se conservan su `COMMENT` vivo y sus ACLs, y se re-emiten. Para cambiar una firma se usa `DROP FUNCTION` + `CREATE`, nunca `CREATE OR REPLACE` con un `DEFAULT` nuevo: deja vivo el overload viejo (`42725`).
- Las columnas de privilegio de `profiles` nunca son escribibles por PostgREST: allow-list por columna (gate `test_accounts_privilege_columns.sql`).
- Un guard que delega en un chequeo posterior **no es guard** (`tenancy-guard-caja-outbox`). Un guard de tenencia que distingue "existe en otra cuenta" de "no existe" filtra información (`cuenta-corriente-party-guard`, `P0404` indistinguible).
- Superficie frontend obligatoria, en escritorio y en móvil, con tema claro y oscuro.

## Goals / Non-Goals

**Goals:**
- Una sola definición de "cuenta activa", la misma en la base, en el token, en FastAPI, en las Edge Functions y en el frontend, persistida y elegible por el usuario.
- Que un miembro con el rol adecuado pueda vender, comprar, editar y borrar sobre los productos y documentos de **su cuenta**, sin importar quién los creó.
- Que ningún miembro pueda hacer más de lo que su rol permite, con la base como autoridad: el guard es autosuficiente en cada RPC.
- Que un invitado reciba un email, acepte desde una pantalla y quede trabajando en el negocio, no en su cuenta personal.
- Gates que ejecuten las RPCs con un segundo miembro y con un usuario de dos cuentas, con control negativo de cada guard.

**Non-Goals:**
- **Separación fina por dominio en la RLS** (`rbac-rls-grano-fino`): las policies siguen distinguiendo escritor de lector. La separación fina se hace en las RPCs de ventas y compras de la tanda B y en FastAPI.
- **POS, gastos, cobros, banco y stock**: ya exigen `is_account_writer` y no tienen guard por autor. Ajustar su capacidad fina (por ejemplo, que el POS exija `CAN_SELL` en vez de `is_account_writer`) queda como candidato.
- **Cuotas de IA y exportación por cuenta**: hoy se cuentan por usuario en `profiles`, así que cada miembro tiene su propio cupo contra el plan de la cuenta. Es una decisión comercial: queda como candidato.
- **Activar `single-session-per-user`**: es una acción del PO en el Dashboard, posterior a la validación de la tanda C.
- **Cerrar el `INSERT` abierto de `email_logs`** (hallazgo lateral): va como hotfix propio (OQ-7).
- **Borrar o abandonar la cuenta personal**, y salir de una cuenta por cuenta propia: candidatos.
- **Retirar `rpc_safe_delete_product`** (sin llamadores) y las policies legacy por `company_users`: candidatos.
- Entrada "Equipo" en el menú lateral: se llega como hoy, desde Configuración → Equipo. Si el PO la quiere, modifica la spec `responsive-shell`, que ya está desactualizada respecto del código: no lista Presupuestos ni Remitos.

## Decisions

### D1 — `current_account_ids()` devuelve sólo la cuenta activa

Se redefine `current_account_ids()` para que devuelva **0 o 1 fila**: la cuenta activa del caller (D3). Sigue siendo `SETOF uuid`, `STABLE SECURITY DEFINER`, con el mismo nombre y la misma firma.

**Por qué**: es el único punto por el que pasan las 45 funciones del patrón A, las 98 policies de RLS, los agregados del patrón C y los chequeos de pertenencia del patrón D.
- Con una sola fila, el `LIMIT 1` sin orden deja de ser ambiguo.
- Los agregados dejan de mezclar cuentas.
- La RLS por PostgREST muestra sólo la cuenta activa, consistente con lo que ve la pantalla.
- Los chequeos del patrón D pasan a exigir que la entidad sea **de la cuenta activa**. Es más estricto que hoy y es deseable: una pestaña desfasada no puede convertir un presupuesto de otra cuenta.
- `rpc_import_products` deja de rechazar al usuario de dos cuentas: su `count(*) > 1` queda inerte. Se documenta en el gate.

Para los 41 usuarios de hoy, todos de una sola cuenta, el resultado es **idéntico**. El gate lo fija con un control explícito.

**Alternativas descartadas**:
- *Reescribir las 45 funciones con un `current_account_id()` singular*: ~45 cuerpos copiados del vivo en una migración. Se pisa con tres changes hermanos y no arregla ni la RLS ni los agregados.
- *Pasar `p_account_id` a cada RPC*: cambia 45 firmas (`DROP` + `CREATE`, `42725`), todos los callers y la RLS de PostgREST quedaría mezclando igual.
- *Dejar `current_account_ids()` con todas las membresías y agregar un `ORDER BY` adentro*: el orden de un `SETOF` consumido con `LIMIT 1` no está garantizado por SQL. Y los agregados seguirían mezclando.

**Lo que hay que saber**:
- El nombre en plural queda por compatibilidad. Su `COMMENT` dice "la cuenta activa (0 o 1 fila)".
- Quien necesite **todas** las membresías tiene `get_account_ids_for_user(auth.uid())`, que ya existe y no cambia, o `account_members` por la policy `self_select`.
- Las notificaciones en tiempo real de otras cuentas dejan de llegar hasta que el usuario cambie a ellas. Es aceptable: la campana es de la cuenta activa.
- Por PostgREST, `accounts` (policy `accounts_member_select`) muestra sólo la fila de la cuenta activa. `/facturacion`, `/planes` y el `auth-context` leen la activa, que es lo correcto. La lista del selector sale de `rpc_my_accounts()` (`DEFINER`, D5), no de esa policy.
- Las policies de escritura y los triggers que validan con `current_account_ids()` pasan a exigir **la cuenta activa**: es el comportamiento buscado. Las 45 policies que validan con `is_account_writer(account_id)` siguen admitiendo cualquier cuenta donde el usuario sea escritor, y no cambian. No abren nada nuevo: hoy ya es así. La escritura directa de tablas por PostgREST queda como candidato de la familia `stock-ledger-solo-rpc`, igual que hoy.

### D2 — La preferencia se persiste por usuario en `profiles.active_account_id` (OQ-1)

Columna nueva `profiles.active_account_id uuid NULL REFERENCES accounts(id) ON DELETE SET NULL`.
- No es escribible por PostgREST: nace fuera de la allow-list y el gate de columnas se amplía.
- Sólo la escriben dos funciones:
  - `rpc_set_active_account(p_account_id)` (`SECURITY DEFINER`, `EXECUTE` para `authenticated`), que valida la membresía y responde `P0404` si no es miembro, indistinguible de una cuenta inexistente;
  - `rpc_accept_invitation` (D7).

**Por qué por usuario**: la preferencia viaja con la persona a cualquier dispositivo, es una fila y una función, y el hook la puede leer.

**Alternativas**:
- *Por sesión* (clave `session_id` del claim): cada dispositivo con su propia cuenta, sin "saltos" entre dispositivos. Agrega una tabla por sesión y una política de limpieza. El salto entre dispositivos ya queda contenido por D6.
- *Cookie*: FastAPI está en otro dominio (Render) y el token viaja sólo por el encabezado de autorización (spec `backend-auth`), así que la cookie no llega.
- *Sin persistencia* (siempre la más antigua, y elegir en cada login): el invitado aterrizaría en su cuenta personal cada vez.

### D3 — Precedencia: claim, preferencia, membresía más antigua; claim inválido = sin cuenta activa

Función interna `resolve_active_account(p_user_id uuid) RETURNS uuid`:
- es `SECURITY DEFINER` y `STABLE`;
- tiene `EXECUTE` sólo para `supabase_auth_admin`, nunca para `anon` ni `authenticated`, porque recibe un usuario por parámetro (misma lección que `get_account_ids_for_user`, h4);
- devuelve la preferencia si sigue siendo una membresía y, si no, la membresía más antigua por `(created_at, id)`, el criterio vigente.

`current_account_ids()`:
1. si el claim `app_metadata.account_id` del request **está presente**, devuelve esa cuenta **sólo si** `auth.uid()` sigue siendo miembro de ella; si no, **cero filas**;
2. si el claim **falta**, devuelve `resolve_active_account(auth.uid())`;
3. sin `auth.uid()`, cero filas, como hoy.

**Por qué el claim primero**: el token es la unidad de consistencia de un request. Los claims de rol y de plan que FastAPI usa para autorizar describen la cuenta del claim. Si SQL leyera la preferencia de la base mientras el token describe otra cuenta, el rol autorizado y la cuenta escrita podrían ser de cuentas distintas.

**Por qué el fail-closed**: un miembro quitado de la cuenta, con el token todavía vigente, no debe caer en silencio en su otra cuenta mientras la pantalla le muestra la anterior. Recibe "sin cuenta activa" (`P0403`/`403`), y el frontend lo maneja renovando el token: el hook resuelve la que corresponda y la pantalla se recarga.

**El caso "claim ausente"** cubre los tokens emitidos antes del deploy (viven a lo sumo 15 minutos: `Access token expiry` es de 900 s desde 2026-09-17) y cualquier contexto que empuje claims mínimos.

### D4 — El token transporta la cuenta; FastAPI la empuja; los claims de rol sólo valen con cuenta

- `custom_access_token_hook` resuelve con `resolve_active_account(user_id)` (deja de tener su propio `ORDER BY … LIMIT 1`). Emite `app_metadata.account_id` junto con `account_role`, `account_roles` y `plan` **de esa cuenta**. El blindaje de degradación queda igual: un error devuelve los claims intactos y deja `WARNING`.
- `AuthContext` suma la clave `account_id: str | None`. `get_db_conn` empuja `{"sub", "role", "app_metadata": {"account_id": …}}` cuando el token la trae, así SQL resuelve igual por FastAPI y por PostgREST.
- `require_account_role` usa los claims `account_roles`/`account_role` **sólo si** el contexto trae `account_id`. Sin `account_id` (token viejo), consulta la base. La excepción sensible de `CAN_CONFIGURE` no cambia.
- `rpc_my_active_account_roles()` devuelve los roles de la membresía en `current_account_ids()`. `rpc_my_effective_plan()` y `rpc_atomic_log_ai_insight` usan `current_account_ids()`. El trigger `set_insight_account_id` usa `current_account_ids()` cuando `NEW.user_id = auth.uid()` y `resolve_active_account(NEW.user_id)` en los otros casos (por ejemplo, una Edge Function con service role).
- `get_account_id` pasa a `SELECT cai FROM public.current_account_ids() AS cai`: la **misma** función que SQL, sin un criterio paralelo. El 403 "No active account found" se conserva.
- Edge Functions: `resolveActiveAccountId` llama a la RPC `current_account_ids` con el JWT del usuario. `ai-estadisticas` deja su copia en línea y usa la compartida.
- Frontend: `auth-context` toma la cuenta activa de `rpc_my_accounts()` (D5) y deja de ordenar `account_members` por su cuenta.

### D5 — Selector y cambio de cuenta

- `rpc_my_accounts()` (`SECURITY DEFINER`, `EXECUTE` para `authenticated`) devuelve una fila por membresía del caller con:
  - `account_id`, `is_active` y los roles activos;
  - si es dueño;
  - los campos **crudos** del nombre (marca `display_name`, fiscal `nombre_fantasia` y `razon_social`, marca `legal_name`, dueño `business_name`);
  - el estado de billing de la cuenta.

  No calcula el nombre visible en SQL: lo calcula `previewIssuer` de `lib/document-branding.ts`, que ya está atada a `backend/services/commercial_documents/issuer.py` por el fixture `document_issuer_cascade_cases.json`. Así no nace una tercera cascada.
- **Dónde**: `AccountSwitcher` en el `SidebarHeader` de `components/app-sidebar.tsx`.
  - En el drawer móvil es el mismo componente.
  - Se muestra sólo con dos o más cuentas.
  - Muestra el nombre del negocio activo y el rol propio; al tocarlo, la lista con nombre y rol de cada cuenta.
  - Usa los tokens semánticos y los componentes base, con targets de 44 px en móvil.
- **Cambio**: `rpc_set_active_account(id)` por supabase-js → `refreshSession()` (renovación forzada por el manejador de tokens) → señal `account:switched` en `lib/auth/session-bus.ts`, sin token en el mensaje, como manda la regla 1 del bus → `queryClient.clear()` → `router.replace('/dashboard')` y toast "Ahora estás en {negocio}". Las otras pestañas, al recibir la señal, hacen lo mismo.
- Se usa supabase-js y no FastAPI para el arranque y el cambio, para no colgar el arranque de la app del *cold start* de Render (~50 s). El único error posible de `rpc_set_active_account` es una carrera: la membresía se revocó entre que se listó y se eligió. Se muestra como error genérico y se recarga la lista, así que el 500 de PostgREST para `P04xx` no llega a la UI.

### D6 — Guard de pestaña desfasada: `X-Account-Id`

`lib/api/python-client.ts` manda `X-Account-Id: <user.accountId>` en cada request a FastAPI. Se compone en `auth-headers.ts`, el único sitio que arma encabezados. `get_account_id` compara:
- **sin header** → no compara, por compatibilidad con scripts y clientes viejos;
- **header distinto de la cuenta resuelta** → `409` RFC 7807 con `type` `account_switched`.

El cliente intercepta ese `409`: renueva el token, limpia la caché y lleva al Tablero con un aviso.

El hueco que cierra: el token es el mismo para todas las pestañas (cookies `httpOnly` compartidas). Al cambiar de cuenta en una, la otra sigue mostrando la cuenta anterior, pero sus requests ya salen con el token nuevo. Sin este guard, un alta sin entidad (una venta de servicio, un gasto) escrita desde la pestaña vieja caería en la cuenta nueva **en silencio**. Las escrituras con entidad (producto, presupuesto, sucursal) ya fallan cerradas por D1 y D8.

`core/cors.py` agrega `X-Account-Id` a los encabezados permitidos. Para las pocas escrituras directas por supabase-js (`rpc_stock_adjustment`, `rpc_transfer_stock`, `rpc_create_branch`, `rpc_open_branch`, `rpc_close_branch`, `rpc_deactivate_branch`, `rpc_adjust_branch_stock`), todas con entidad, la protección es D1. Se documenta como residuo.

### D7 — La cuenta personal del invitado se conserva y la aceptación activa el negocio (OQ-2)

`handle_new_user` no cambia: todo registro crea su cuenta propia. `rpc_accept_invitation`, además de lo que ya hace, fija `profiles.active_account_id = v_inv.account_id` en la misma transacción. El frontend renueva el token después de aceptar, y el hook emite la cuenta del negocio.

**Por qué no "sin cuenta personal para el invitado"**:
- `handle_new_user` es el trigger más crítico del alta y no puede saber con certeza que el registro viene de una invitación: la metadata del registro la controla quien se registra.
- Entre el registro y la aceptación (verificación de email de por medio) el usuario quedaría **sin ninguna cuenta**, y toda pantalla fallaría.
- La cuenta personal le da al invitado su propio período de prueba. El selector la hace explícita en vez de esconderla.

### D8 — Guard de producto y de documento por cuenta activa, dentro del `SELECT … FOR UPDATE` (tanda B)

En las seis funciones del patrón E:
- **Producto**: `SELECT … FROM products WHERE id = v_item.product_id AND account_id = v_account_id FOR UPDATE`. `NOT FOUND` → `P0404 Product not found`, el mismo texto que hoy da un id inexistente. Un producto de otra cuenta es indistinguible de uno que no existe. Se elimina el `IF v_product.user_id <> v_uid`.
- **Documento** (edición): el chequeo `user_id != v_uid` se reemplaza por "todas las filas de `p_sale_ids`/`p_purchase_ids` son de `v_account_id`" (`P0404` si alguna no lo es). El `FOR UPDATE` filtra `s.account_id = v_account_id`. La regla de autor para documentos ajenos es la de D9.
- `products.user_id`, `sales.user_id` y `purchases.user_id` se siguen **escribiendo** como autoría (spec `multi-tenant`, «`user_id` conservado como autoría»): nunca se vuelven a usar como eje de autorización.

El guard es **autosuficiente**: cada RPC filtra por la cuenta en su propio `SELECT`, sin depender de un chequeo posterior ni de FastAPI.

### D9 — Capacidad en la base, con helper canónico, y espejo en FastAPI (OQ-3, OQ-4)

Helper nuevo `_account_assert_capability(p_account_id uuid, p_roles text[], p_message text)`:
- `STABLE`, `SECURITY INVOKER` y sin `EXECUTE` para los roles de aplicación, porque lo invocan las RPCs `DEFINER`;
- primero `is_account_writer(p_account_id)` → `P0401 unauthorized`, y después que `account_user_active_roles(p_account_id, auth.uid())` interseque `p_roles` → `P0403 insufficient_role: <mensaje>`.

Es la misma forma de `_stock_assert_can_adjust`, `_quote_assert_can_write` y `_delivery_note_assert_role_dir`: con esas tres, la Regla de Tres está alcanzada. Las tres existentes **no** se migran en este change (candidato), para no tocar funciones fuera de alcance.

Matriz **recomendada** (OQ-3 y OQ-4), que espeja las constantes de `backend/core/rbac.py`:

| Operación | Quién |
|---|---|
| Alta de venta por formulario | `CAN_SELL` = owner, admin, seller, cashier |
| Alta de compra | `CAN_PURCHASE` = owner, admin, purchases |
| Editar o borrar una venta | owner y admin, cualquiera; seller y cashier, **sólo las propias** (`sales.user_id = auth.uid()`) |
| Editar o borrar una compra | owner y admin, cualquiera; purchases, **sólo las propias** |

- Un documento ajeno sin autoridad → `P0403 insufficient_role`. Su existencia no se oculta: el miembro ya la ve en el listado.
- FastAPI suma `require_account_role(conn, auth, CAN_SELL / CAN_PURCHASE)` en los services. No son capacidades sensibles, así que deciden con el claim (D4). La regla de autor sólo la decide la base: FastAPI no conoce al autor sin leerlo.
- Un test lee la migración y `rbac.py` y falla si divergen, como los tests espejo de `remitos-venta` y `presupuestos-modulo`.
- Frontend: `lib/rbac-capabilities.ts` suma `CAN_PURCHASE` (con su test espejo). Los botones "Nueva venta", "Nueva compra", "Editar" y "Eliminar" se ocultan sin la capacidad. "Editar" y "Eliminar" sobre un documento ajeno, sin owner ni admin, también.

### D10 — La invitación vive en FastAPI y el email se encola en SQL desde la fila (tanda C)

- **Endpoints**, con router y service nuevos en `routers/members.py` o un `invitations.py` hermano; capacidad `CAN_CONFIGURE` = owner o admin, la misma autoridad que ya exige `rpc_invite_member`:
  - `POST /members/invitations` (crear y enviar);
  - `GET /members/invitations` (pendientes);
  - `POST /members/invitations/{id}/resend`;
  - `DELETE /members/invitations/{id}` (revocar);
  - `GET /invitations/{token}` (vista previa);
  - `POST /invitations/{token}/accept`.

  Todos traducen `P04xx` a RFC 7807 por el handler global.
- **Envío**: el service llama a `rpc_invite_member(email, account_id, roles)` y después a `rpc_send_invitation_email(p_invitation_id, p_account_display_name)`. El nombre lo calcula `resolve_commercial_issuer(account_id)` (cascada canónica, el invitador es miembro de la cuenta activa). La RPC:
  - valida que el caller sea owner o admin **de la cuenta de la invitación**;
  - exige que la invitación esté `pending` y vigente;
  - aplica los topes de D13;
  - guarda el snapshot `account_display_name` en la fila (lo necesita la vista previa, porque el invitado todavía no es miembro);
  - inserta en `email_logs` con `event_type = 'org_invite'`, `recipient` = **el email de la fila**, `user_id` = el invitador y `metadata` con:
    - `token`, **de la fila**;
    - `account_name`, el snapshot recortado a 120 caracteres;
    - `inviter_name`, leído de `profiles`;
    - las etiquetas de los roles, del catálogo;
    - `expires_at`.

  Nada de lo que define a quién le llega ni qué link lleva sale de un parámetro. Lo único que viene del caller es el nombre del negocio, que un owner o admin ya controla desde la marca.
- **Plantilla** `org_invite` en `send-email`:
  - todo dato interpolado pasa por `escapeHtml` (`_shared/html-escape.ts`, nuevo, canónico);
  - el CTA es `${APP_URL}/invitacion/${encodeURIComponent(token)}`, con `APP_URL` constante y **nunca** una URL tomada de la metadata (hoy `meeting_notice` usa `metadata.url`: ver OQ-7);
  - texto: "{Invitador} te invitó a sumarte a {Negocio} en ALIADATA como {roles}. La invitación vence el {fecha}."

**Por qué FastAPI y no supabase-js**: el `P0404` y el `P0409` de la aceptación tienen que llegar como 404/409 y no como 500 (dato medido por `v3-rbac-multirole`). Además, crear y enviar quedan en la misma transacción del request.

**Por qué el email se encola en SQL y no lo inserta el service**: no depende de la policy abierta de `email_logs` (OQ-7). Si esa policy se cierra, la invitación sigue funcionando.

### D11 — Orden de apply con los changes hermanos

Las ocho funciones de la tanda B las reescriben también otros changes:

| Función | `fix/stock-edicion-sucursal-y-piso` | `remitos-compra` B | `edicion-operaciones-con-dinero` | multiusuario B |
|---|---|---|---|---|
| `rpc_atomic_update_sale_operation` | sí | — | sí | sí |
| `rpc_atomic_update_purchase_operation` | sí | sí | sí | sí |
| `rpc_create_purchase_operation` | — | sí (extrae `_purchase_operation_core`) | — | sí |
| `rpc_delete_purchase_operation` | — | sí | posible | sí |
| `rpc_create_sale_operation(_v2)`, `rpc_delete_sale_operation` | — | — | posible (borrado) | sí |

**Orden recomendado**:
1. `fix/stock-edicion-sucursal-y-piso`, que está en curso y es el diff más chico;
2. `remitos-compra` tanda B, ya firmada;
3. **multiusuario tanda B**;
4. `edicion-operaciones-con-dinero`.

**La tanda A no toca ninguna de esas funciones** y puede ir primera, antes que todas. La tanda C depende de la B, no de los hermanos.

**Por qué multiusuario B antes que `edicion-operaciones-con-dinero`**: es un cambio de **autorización**, acotado al bloque de guards del principio y al `SELECT` del producto. El hermano cambia la **semántica** del cuerpo (editar con dinero posteado). Aplicar primero el diff chico y crítico deja al grande partiendo de guards ya correctos. Al revés, el hermano tendría que preservar un guard por autor que este change va a borrar.

Si el PO prioriza al hermano, el orden se invierte sin problema. Las reglas son las mismas en cualquier orden:
- quien aplica segundo parte del cuerpo **vivo**, con *preflight* de `md5`;
- re-corre los gates del primero;
- si el núcleo de compra ya está extraído, el guard de producto va **en `_purchase_operation_core`** y no en el wrapper.

### D12 — Ruta `/invitacion/[token]`

- **Ubicación**: `app/invitacion/[token]/page.tsx`, fuera del grupo `(dashboard)`. Se agrega el prefijo `/invitacion/` a `PUBLIC_PREFIXES` de `lib/auth/route-access.ts`.
- **Encabezados**: `Referrer-Policy: no-referrer` sólo para esa ruta (el global es `strict-origin-when-cross-origin`) y `robots: noindex`. El token va en el path, así que no tiene que salir por `Referer` ni indexarse.
- **Anónimo**: tarjeta genérica, sin nombre de negocio (OQ-5): "Tenés una invitación para sumarte a un negocio en ALIADATA. Ingresá o creá tu cuenta con el email al que te llegó." Botones "Ingresar" (`/auth/login?next=/invitacion/<token>`, ya admitido por `safeNext`) y "Crear cuenta". El registro hoy no acepta `next` del cliente (`callbackUrl` lo fija el módulo): se amplía con una allow-list **sólo** para el prefijo `/invitacion/`.
- **Con sesión y la identidad correcta**: `GET /invitations/{token}` → `rpc_invitation_preview(p_token)`. Hace las mismas validaciones que la aceptación (vigencia, estado, email de `auth.users`) y devuelve el snapshot del negocio, el nombre del invitador, las etiquetas de los roles y el vencimiento. Se ofrecen "Aceptar" y "Ahora no" (vuelve al Tablero; no rechaza: la invitación vence sola).
- **Con sesión y otra identidad, o token vencido, revocado o usado**: un único mensaje, "Esta invitación no está disponible para tu usuario: puede haber vencido o ser para otro email", con "Cerrar sesión e ingresar con otro email". Mismo contrato que la aceptación: no revela si el token existe.
- **Ya es miembro** (`P0409`): "Ya sos parte de {negocio}" y botón para cambiar a esa cuenta.
- **Aceptar**: `POST /invitations/{token}/accept` → `refreshSession()` → señal `account:switched` → Tablero con el toast "Te sumaste a {negocio} como {roles}".
- **Qué ve el invitado al entrar**: el Tablero del negocio, el selector con sus dos cuentas y el menú recortado por su rol (`useOrgRole` sobre la cuenta activa). Un `viewer` ve todo en lectura, como ya define la spec `org-roles`.

### D13 — Reenviar rota el token, revocar es un estado, y hay topes (OQ-8)

- **Reenviar**: `rpc_send_invitation_email(id, nombre, p_renew => true)`. Rota el token (`gen_random_bytes(32)`), renueva el vencimiento a 7 días y encola el email. Los links de los emails anteriores dejan de funcionar.
- **Revocar**: `rpc_revoke_invitation(id)`, con la autoridad de owner o admin, pasa a `status = 'revoked'`, valor nuevo del `CHECK`. La aceptación y la vista previa responden con el error genérico.
- **Listar**: `rpc_list_account_invitations(p_account_id)`, owner o admin. Devuelve las pendientes y las vencidas o revocadas de los últimos 30 días, sin el token. Hace falta porque la policy deja ver invitaciones sólo al dueño.
- **Topes recomendados**: a lo sumo 1 envío por invitación cada 10 minutos (`invitation_cooldown`) y a lo sumo 20 emails de invitación por cuenta por día (`invitation_daily_cap`), contados sobre `email_logs`. El cupo de `max_users` ya limita los miembros; esto limita el email hacia terceros.
  - Código: `P0439` → HTTP 429 en `backend/core/errors.py`. Es el primer libre por encima de los usados (medido sobre `supabase/migrations`). **No** `P0429`, que ya es la señal interna de rollback de `rpc_import_expenses`. Se re-confirma en el apply.

### D14 — Se retira el overload de 2 argumentos de `rpc_invite_member`

La invitación rápida de `TeamSection` pasa al flujo de FastAPI con el conjunto de roles. Ese era el candidato registrado por `v3-rbac-multirole`: hoy resuelve a `viewer` sin que nadie lo elija. Con todos los callers migrados (`grep` de `frontend/`, `backend/` y `supabase/functions/`, más `pg_proc.prosrc` de prod), `DROP FUNCTION public.rpc_invite_member(text, uuid)`.

De paso, `rpc_invite_member` y `rpc_accept_invitation` pasan su "Not authenticated" de `P0001` a `P0401` (candidato `membership-rpcs-not-authenticated-p0401`).

### D15 — Gates

- **`test_multiusuario_cuenta_activa.sql`** (tanda A), ejecutando como `authenticated` con `request.jwt.claims` armado a mano:
  - un usuario de una sola cuenta ve exactamente su cuenta en `current_account_ids()`, con claim y sin claim: control de no regresión para los 41;
  - el usuario de dos cuentas ve una sola fila, que sigue la preferencia;
  - `rpc_set_active_account` cambia la cuenta; con una cuenta ajena, `P0404`;
  - el claim gana sobre la preferencia;
  - con un claim de una membresía borrada, cero filas;
  - el hook emite `account_id`, roles y plan de la cuenta activa;
  - la RLS (`SET LOCAL ROLE authenticated`) muestra sólo las ventas de la cuenta activa;
  - `get_dashboard_financials` no suma la otra cuenta;
  - R3j y R3l reproducidos: el POS y la venta de servicio quedan en la cuenta activa;
  - `rpc_import_products` en dry run ya no responde `cuenta_ambigua`;
  - `resolve_active_account` no es ejecutable por `authenticated`.
- **Gate estructural** (barrido por convención, molde del gate de ACLs): ninguna función de `public`, salvo `resolve_active_account`, `rpc_my_accounts`, `rpc_set_active_account`, `current_account_ids` y las de membresía (`rpc_invite_member`, `rpc_accept_invitation`, `rpc_list_account_members` y familia), puede contener `account_members … user_id = … LIMIT 1` sin `account_id = <parámetro>`. Que no nazca un quinto criterio.
- **`test_multiusuario_operaciones.sql`** (tanda B), con la matriz de D9 ejecutada de punta a punta:
  - vendedor y administrador venden productos del dueño;
  - cajero y depósito no compran (`P0403`); un observador no crea, no edita ni borra (`P0401`);
  - el dueño edita y borra lo del vendedor; el vendedor no edita lo del dueño (`P0403`) y sí lo propio;
  - **controles negativos de tenencia**: un producto de otra cuenta da `P0404`, con el mismo texto que un id inexistente; un documento de otra cuenta, `P0404`; el usuario de dos cuentas con un producto de la cuenta **no activa**, `P0404`;
  - un mutante: sin el filtro de cuenta en el `SELECT` del producto, el gate falla.
- **`test_multiusuario_invitaciones.sql`** (tanda C):
  - el envío encola un `org_invite` con el destinatario de la fila; un no-autoridad recibe `P0403`;
  - el reenvío rota el token y el viejo falla; revocar hace fallar la aceptación;
  - la vista previa con otra identidad devuelve el mismo error que un token inexistente;
  - la aceptación fija la cuenta activa;
  - se cumplen el enfriamiento y el tope diario;
  - el overload de 2 argumentos ya no existe.
- **Gates existentes que cambian a propósito**: `test_custom_access_token_hook_account_roles.sql` (el claim `account_id` y la resolución por preferencia), `test_accept_invitation_binding.sql` (la cuenta activa tras aceptar) y `test_invite_member_roles_and_plan_gate.sql` (el overload retirado).
- **Se re-corren sin tocar** los gates que introspectan o ejecutan las ocho funciones de la tanda B: `test_idempotency`, `test_confirm_core_integrity`, `test_edicion_preserva_contexto`, `test_ventas_unidades_conversion`, `test_stock_movements_edicion`, `test_function_acl_gate`, `test_purchase_cash_optin`, `test_compras_proveedor_cuenta_corriente`, etc. La lista exacta se arma con `grep` en el apply.
- Cada migración se reaplica al final de la cadena de `KPI_Validation.yml`.

## Risks / Trade-offs

- **[`current_account_ids()` está en el camino de todo]** Un error en la redefinición rompe la lectura de las 64 tablas para todos los usuarios. → Mitigaciones:
  - control de no regresión del gate para el usuario de una sola cuenta, con y sin claim;
  - humo en el stack local con un build de producción y un usuario de una cuenta antes del merge;
  - el rollback es redefinir la función anterior, en una línea, guardada en `evidence/`;
  - la verificación post-merge mide `current_account_ids()` como el PO, en prod.
- **[Costo por consulta]** La función pasa de una búsqueda indexada a leer el claim, validar la membresía y, sin claim, leer `profiles`. Se evalúa una vez por sentencia (`InitPlan` de `IN (SELECT …)`). → `EXPLAIN` antes y después sobre `/ventas` y el Tablero en el stack local. Sin regresión medible: es una lectura más por índice.
- **[Claims mínimos de FastAPI]** Si el apply olvida empujar `app_metadata.account_id` en `get_db_conn`, SQL cae a la preferencia mientras FastAPI autoriza con los claims del token: dos fuentes. → Test de `get_db_conn` que verifica el JSON empujado, y el gate de la tanda A con claims mínimos (sin `account_id`) que verifica la caída a la preferencia.
- **[Salto entre dispositivos]** Con la preferencia por usuario, cambiar de cuenta en el teléfono hace que la PC cambie de cuenta en su próxima renovación (≤15 min). → D6 convierte ese salto en un `409` y una resincronización visible, nunca en una escritura en la cuenta equivocada. Si molesta en la práctica, la alternativa por sesión de D2 es un change acotado.
- **[Escrituras directas por supabase-js sin `X-Account-Id`]** Siete RPCs del navegador no pasan por FastAPI. → Todas llevan entidad (producto o sucursal), que D1 ata a la cuenta activa. Residuo documentado.
- **[Tres changes hermanos sobre las mismas funciones]** → D11: orden recomendado, *preflight* de `md5` del cuerpo vivo en cada tanda y re-corrida de los gates de los demás.
- **[Restricción nueva para roles funcionales]** Con la matriz de D9, un `stock` o un `accountant` que hoy podría cargar una compra deja de poder. Hoy no hay ninguno: 0 miembros no-dueños. → Es la definición del catálogo ("Compras: registra compras a proveedores"). OQ-3 permite elegir `is_account_writer` si el PO prefiere no restringir.
- **[Notificaciones de otras cuentas]** Dejan de verse hasta cambiar de cuenta (D1). → Aceptado. Candidato: un indicador por cuenta en el selector.
- **[Phishing por `email_logs`]** El email de invitación nuevo hace más creíble un email falso de invitación insertado por la policy abierta. → OQ-7: hotfix propio **antes** de la tanda C.

## Migration Plan

1. **Firma del PO** sobre OQ-1 a OQ-9. Nada se aplica antes.
2. **Tanda A** (independiente de los hermanos):
   1. *preflight* de `md5` de las funciones del patrón B, del hook y de `current_account_ids()`;
   2. migración más gate;
   3. backend (deps, auth, database, guards, cors), Edge Functions y frontend (auth-context, selector, `X-Account-Id`, bus de sesión);
   4. humo local con dos cuentas;
   5. merge y verificación post-merge en prod: `MAX(version)`, ACLs, que `current_account_ids()` de un usuario real devuelva su cuenta, y `auth_logs` con el hook sin degradación.

   Rollback: restaurar los cuerpos previos desde `evidence/` y quitar la columna (sin datos de valor; la preferencia es descartable).
3. **Tanda B** (después de los hermanos que correspondan, D11):
   1. *preflight* de las ocho funciones contra el vivo;
   2. migración más gate;
   3. capacidades en FastAPI y en el frontend;
   4. humo local R3a-R3l en verde.

   Rollback: los cuerpos previos desde `evidence/`.
4. **Hotfix de `email_logs`** (OQ-7), si el PO elige la opción recomendada.
5. **Tanda C**:
   1. migración más gate;
   2. FastAPI, `send-email` (redeploy de la Edge Function) y frontend;
   3. humo local con Inbucket: email recibido, link, registro, aceptación y Tablero del negocio;
   4. **demo real del PO** con un segundo usuario propio. Es su familiar: hoy comparten un usuario desde dos dispositivos.
6. **Acción del PO, fuera del repo**: activar `Enforce single session per user` cuando cada persona tenga su usuario (candidato `single-session-per-user`).

## Open Questions

Las nueve se firman antes de cualquier apply. Cada una lleva su opción recomendada y por qué.

- **OQ-1 — ¿Dónde se persiste la cuenta activa?**
  - (a) **Por usuario**, en `profiles.active_account_id`. **Recomendada**: es la más simple, sigue a la persona, y D6 hace seguro el salto entre dispositivos.
  - (b) Por sesión, en una tabla nueva por `session_id`.
  - (c) No se persiste: siempre la más antigua, y se elige en cada login.
- **OQ-2 — ¿El invitado conserva su cuenta personal?**
  - (a) **Sí**: la aceptación activa el negocio y el selector muestra las dos. **Recomendada** (D7): no toca `handle_new_user`, no deja usuarios sin cuenta durante la verificación de email, y el invitado tiene su prueba propia.
  - (b) No se crea la cuenta personal si el registro viene de una invitación.
  - (c) Como (a), más una acción "eliminar mi cuenta personal vacía", que sería un change propio.
- **OQ-3 — ¿Qué rol hace falta para dar de alta?**
  - (a) Sólo `is_account_writer`: los 7 roles escritores hacen todo.
  - (b) **Capacidad por dominio** (`CAN_SELL` para la venta, `CAN_PURCHASE` para la compra), en la base y en FastAPI. **Recomendada**: es lo que dice el catálogo de roles que el PO firmó en `v3-rbac-multirole`, y es el patrón de stock, presupuestos y remitos.

  Sub-pregunta: ¿la compra suma también `stock`, como `CAN_CONVERT_PURCHASE_DELIVERY_NOTE`? Recomendado **no**: el depósito recibe mercadería por remito (`CAN_RECEIVE_PURCHASE`), y la compra con factura es de compras.
- **OQ-4 — ¿Quién edita o borra un documento ajeno?**
  - (a) Cualquiera con la capacidad del dominio.
  - (b) **Owner y admin, cualquiera; el resto, sólo los propios**. **Recomendada**: conserva para el empleado la regla de hoy (cada uno corrige lo suyo) y le da al dueño la que hoy le falta.
  - (c) Sólo owner y admin, incluso los propios.
- **OQ-5 — ¿Qué ve un anónimo que abre el link?**
  - (a) **Un mensaje genérico, sin nombre del negocio**. **Recomendada**: el link puede reenviarse o filtrarse, y el nombre del negocio y del invitador no aportan hasta que la identidad coincide.
  - (b) El nombre del negocio y del invitador a cualquiera con el link.
- **OQ-6 — ¿Se conserva "Copiar link" además del email?**
  - (a) **Sí, como opción secundaria**. **Recomendada**: en Argentina la invitación se comparte por WhatsApp, y la aceptación sigue ligada al email, así que reenviar el link no le da acceso a otro.
  - (b) Sólo email.
- **OQ-7 — Hallazgo lateral: `email_logs` admite `INSERT` de cualquier autenticado** (`email_logs_backend_insert WITH CHECK (true)`, `INSERT` a nivel tabla para `authenticated`, trigger `on_email_log_insert` → `send-email`). Cualquiera puede hacer que ALIADATA mande un email con asunto libre a cualquier dirección. Las plantillas no escapan, y `meeting_notice` toma el link de la metadata. Verificado por construcción (`relacl`, policy, default `status = 'pending'`); **no ejecutado**.
  - (a) **Hotfix propio, antes de la tanda C**: migrar el único caller de navegador (`frontend/app/api/billing/cancel/route.ts`, el email `plan_downgraded`) al servidor, cerrar la policy y escapar las plantillas. **Recomendada**: es explotable hoy, sin multiusuario, y no conviene atarlo al calendario de este change.
  - (b) Incluirlo en la tanda C.
  - (c) Dejarlo como candidato.
- **OQ-8 — Topes del email de invitación.**
  - (a) **1 envío por invitación cada 10 minutos y 20 por cuenta por día**. **Recomendada**: la invitación es el único email que la app manda a una dirección que elige un usuario.
  - (b) Sin topes.
  - (c) Otros valores.
- **OQ-9 — ¿Orden de apply respecto de `edicion-operaciones-con-dinero`?**
  - (a) **Multiusuario tanda B primero** (D11). **Recomendada**: el guard de autorización es el diff chico y crítico, y el hermano parte de guards correctos.
  - (b) El hermano primero: multiusuario B parte de su cuerpo vivo.

  En cualquiera de las dos, la tanda A va primera y la C después de la B.

## Candidatos que deja

- `pos-capacidad-venta`: que el POS exija `CAN_SELL` en vez de `is_account_writer`.
- `cuotas-ia-por-cuenta`: que las cuotas de IA y exportación se cuenten por cuenta y no por usuario.
- `rbac-rls-grano-fino`: ya registrado; sigue vigente.
- `notificaciones-otras-cuentas`: un indicador en el selector.
- Migrar `_stock_assert_can_adjust`, `_quote_assert_can_write` y `_delivery_note_assert_role_dir` al helper `_account_assert_capability`.
- Retirar `rpc_safe_delete_product` (dos overloads, sin llamadores).
- Retirar las policies legacy por `company_users` en `product_variants` y `suppliers`.
- `responsive-shell` desactualizada: no lista Presupuestos ni Remitos, que el menú ya tiene.
- Una acción para salir de una cuenta y otra para eliminar la cuenta personal vacía.
- Activar `single-session-per-user` (acción del PO).
