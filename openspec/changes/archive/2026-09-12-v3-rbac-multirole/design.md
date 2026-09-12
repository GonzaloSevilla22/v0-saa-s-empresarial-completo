> **Numeración de migraciones (orquestador, 2026-09-11)**: `20261046000001` la tomó el fix `importador-gate-plan` (en vuelo el mismo día), así que la Parte A reserva **`20261047000001`**; la task de checkpoint la reconfirma contra `MAX(version)` de prod antes de escribir SQL (precedente: `cuenta-corriente-party-guard`, renumerada tres veces).

## Context

### Estado medido de prod (2026-09-11, read-only, agregados sin PII)

| Hecho | Valor |
|---|---|
| `supabase_migrations.schema_migrations` | `MAX(version) = 20261045000001`, 294 filas |
| `account_members` | 39 filas — **39 `owner`, 0 `admin`, 0 `member`** |
| Cuentas por cantidad de miembros | 39 cuentas con exactamente 1 miembro; **0 con 2+** |
| Invitaciones pendientes vigentes | **0** |
| `account_member_roles` (pivot) | no existe (`to_regclass` → NULL) |
| `document_status_transitions` | 19 filas; `allowed_role` de tipo **`text`** (singular), **0/19 pobladas** |
| `plan_limits.max_users` | `gratis` 1 · `inicial` 2 · `avanzado` 5 · `pro` 10 |
| Policies que invocan `is_account_writer` | **48**, sobre **20 tablas** |

### Estado medido del código (grep, no memoria)

- `require_role(auth, [...])` — **64 llamadas en `backend/services/*.py`, las 64 con la lista `["user","admin"]`** (ronda 1 adversarial de la Parte B, minor 5: el conteo original de "59" quedó viejo — `grep -rn --include=*.py 'require_role(auth, \["user", "admin"\])' backend | grep -v __pycache__ | grep -v '/tests/'` da 65 líneas, de las cuales 1 es un comentario de docstring en `customer_accounts.py:5`, no una llamada real). Es el rol de **plataforma** (`profiles.role`), un espacio de nombres distinto del rol de tenant (declarado normativo en `authz-token-claims`). **Ninguna de las 64 entra en el alcance de este change** — el explore las contaba dentro de "65+4 call sites" a migrar; la medición las saca del alcance.
- `require_account_role(conn, auth, [...])` — **15 llamadas en 4 services** (`cost_centers`, `payment_methods`, `product_categories`, `account_charges`), todas contra `["owner","admin"]`. Ésta sí es la superficie de migración del backend.
- `current_account_ids()` — resuelve **tenencia** (`SELECT account_id FROM account_members WHERE user_id = auth.uid()`); **no lee `role`**. El explore la listaba junto a `is_account_writer` como "a migrar al pivot": no corresponde, y no se toca.
- `is_account_writer(account_id)` — única función de RLS que lee `role`; `SECURITY DEFINER`, `STABLE`, `role IN ('owner','admin')`.
- **El navegador no escribe ninguna de las 20 tablas gateadas por `is_account_writer`**: los únicos `insert`/`update`/`delete`/`upsert` directos contra PostgREST desde el frontend son sobre `analytics_events`, `courses`, `invoice_documents`, `post_likes`, `posts` y `replies` (comunidad y analítica). El camino de escritura de las tablas de dinero es FastAPI.
- `frontend/lib/types.ts:43` — `OrgRole = "owner" | "admin" | "member"`, consumido junto con `accountRole`/`useOrgRole` en ~40 archivos.
- `/organizacion/roles` existe en prod (247 líneas), enlazada desde `/organizacion/invitar` y desde `/configuracion` (`components/settings/TeamSection.tsx:156`).

### Prerequisitos y sign-off

Los tres bloqueantes de la auditoría 2026-07-07 están **cerrados, archivados y verificados en prod**: `v31-fix-auth-shape-500` (H-06), `v31-authz-token-hook` (H-07 — el hook emite `role`/`account_role`/`plan` desde el 2026-08-01) y `v31-tenancy-pool-rls` + `v31-tenancy-role-assertion` (H-05 — el backend adopta `authenticated` por transacción, la RLS se evalúa de verdad). El **sign-off del PO** es del **2026-09-11**, con las 7 preguntas del explore respondidas; las respuestas se registran abajo como decisiones firmadas (D0), no como preguntas abiertas.

**Governance por parte**: A = **HIGH** (aditiva, pero vive en la tabla que termina gobernando dinero real: proponer y esperar revisión antes de escribir) · B = **CRÍTICO** sin matices (cambia RLS y guards que hoy protegen ventas/compras/gastos/cuentas corrientes/caja de 39 cuentas reales) · C = **MEDIO** (UI de administración, con decisiones de negocio a surfacear).

---

## Goals / Non-Goals

**Goals:**

1. Que una membresía pueda tener **varios roles a la vez**, con **quién** lo asignó, **cuándo** y **hasta cuándo** (V3 §5).
2. Que el enforcement de esos roles sea **real** en los tres planos que hoy existen: el guard del backend, la RLS, y la máquina de estados de documentos (RN-A4, `allowed_role`, inerte desde el 2026-07-03).
3. Que una cuenta **nunca** pueda quedar sin `owner` activo, por ningún camino.
4. Que el vencimiento de un rol corte el acceso **sin intervención humana** y deje rastro auditable.
5. Que las ~40 pantallas que hoy leen `accountRole`/`isWriter` **no se rompan** ni cambien de comportamiento para los 39 `owner` reales.
6. Que cada parte sea reversible por separado y verificable en prod por separado.

**Non-Goals (declarados, no olvidados):**

- **Maker-checker / `requires_second_approval`** (M-SEC-13). Sign-off del PO 6.4 = (b): se difiere por completo a `v4-seguridad-04`/`05`, que ya existe como change propio "construido explícitamente encima de `v3-rbac-multirole`" y va a necesitar su propia migración (tabla de aprobaciones, no una columna). **No se agrega la columna.**
- **Gating de roles por plan.** Sign-off 6.2 = (b): todos los roles en todos los planes. El gating comercial es sólo por **cantidad de usuarios** (`plan_limits.max_users`, ya existente).
- **Acortar el TTL del JWT** (opción (c) de 6.5). Es una decisión de plataforma que afecta a todos los claims y a todos los usuarios; no se decide desde este change.
- **RLS de grano fino por dominio** (que `cashier` no pueda escribir `products` vía PostgREST). Ver D12 — residuo con nombre propio, justificado y acotado.
- **Selector de cuenta activa** (claim `account_id` elegible por el usuario). Ver D20 y OQ-1.
- **Retirar `account_members.role`.** Sobrevive como espejo; su retiro es un change de limpieza posterior, igual que `products.category` TEXT lo fue respecto de `category_id`.
- **Paso 3 de `v31-tenancy-pool-rls`** (rol de login sin `BYPASSRLS`). Residuo de un change ya archivado; se menciona sólo porque es contexto de R4.
- **Migrar los 64 `require_role(auth, ["user","admin"])`** (conteo corregido, ronda 1 adversarial minor 5 — ver arriba). Son rol de plataforma; tocarlos sería mezclar dos espacios de nombres que `authz-token-claims` declara separados.

---

## Decisions

### D0 — Las 7 respuestas del PO (sign-off 2026-09-11) son decisiones firmadas

| # | Pregunta del explore | Respuesta firmada | Dónde se materializa |
|---|---|---|---|
| 6.1 | ¿Avanzar pese a 0 cuentas con 2+ miembros? | **(a) las tres partes** (A + B + C) | Partición A/B/C de este design |
| 6.2 | Gating por plan de roles funcionales | **(b) todos los roles en todos los planes**; gating comercial sólo por `max_users` | D17, D18 |
| 6.3 | ¿Extender o reemplazar `/organizacion/roles`? | **(a) extender en el lugar**, misma ruta y navegación | Parte C, D19 |
| 6.4 | `requires_second_approval` ahora o diferido | **(b) diferido** a `v4-seguridad-04`/`05` | Non-Goals |
| 6.5 | Staleness del claim de rol | **(a) aceptar** como riesgo conocido, documentado | D9, R3 |
| 6.6 | Orden de ejecución | **A → B → C**; A puede aplicarse apenas se mergee este propose | Migration Plan |
| 6.7 | Catálogo cerrado de roles | **aprobado tal cual** (8 roles) | D1, D2 |

### D1 — El catálogo de roles es una tabla global de solo lectura, no un CHECK

`account_role_catalog(code, label, description, sort_order, is_writer)`, sembrada por migración, con `SELECT` para `authenticated` y `INSERT`/`UPDATE`/`DELETE` revocados — el mismo molde que `document_status_transitions` usa desde `v3-document-status-history` para "catálogo global de solo lectura para la UI".

*Por qué*: (1) la UI necesita etiqueta y descripción en castellano para 8 roles — hoy `ROLE_LABELS` vive hardcodeado en `page.tsx`, y con 8 roles y dos pantallas eso se duplica; (2) `is_writer` como dato permite que `is_account_writer` derive el conjunto de escritores del catálogo en vez de hardcodear una lista, así que agregar un rol futuro no obliga a reescribir una función de RLS; (3) el pivot puede referenciarlo por FK, lo que deja la cerrazón del catálogo garantizada por integridad referencial y no por una lista repetida en cada CHECK.

*Alternativas descartadas*: **CHECK constraint** (obliga a un `ALTER TABLE` por cada rol nuevo y deja etiquetas/orden sin lugar canónico); **catálogo por tenant** (el V3 §5 ratifica explícitamente catálogo **cerrado y global**, sin RBAC dinámico — la decisión §5.1 del V2 sigue firme).

### D2 — Los códigos de rol se almacenan en **minúscula**

`owner`, `admin`, `seller`, `cashier`, `stock`, `purchases`, `accountant`, `viewer` — no `OWNER`/`ADMIN`/… como en el diagrama de clases del V3 §5.

*Por qué*: `owner` y `admin` quedan **idénticos** a lo que ya existe en `account_members.role`, en el claim `account_role`, en el cuerpo de `is_account_writer`, en `rpc_my_account_role` y en el tipo `OrgRole` del frontend. El único valor legacy que necesita traducción es `member` → `viewer` (ambos significan "solo lectura"). Con mayúsculas, **cada frontera** entre el hook, el guard, la RLS, el frontend y la matriz FSM sería un lugar donde normalizar — y un lugar donde olvidarse de hacerlo. Un `IN`/`= ANY` que falla por capitalización no da error: concede o deniega en silencio. El diagrama del V3 es convención de presentación; la etiqueta visible vive en `account_role_catalog.label`.

### D3 — El pivot es la fuente de verdad desde la Parte A; `account_members.role` es un espejo por trigger

El trigger sobre `account_member_roles` recalcula `account_members.role` con precedencia: **`owner` activo → `owner`; si no, `admin` activo → `admin`; si no → `member`**. Los tres RPCs de membresía existentes (`rpc_change_member_role`, `rpc_remove_member`, `rpc_accept_invitation`) se reescriben para escribir **a través del pivot**, conservando firma, contrato `{ok}|{error}` y el orden exacto de sus validaciones.

*Por qué*: es la única forma de tener **un solo camino de escritura**. Con dos (el RPC legacy escribiendo la columna y las RPCs nuevas escribiendo el pivot) las dos fuentes divergen en silencio — el riesgo R5, y el mismo patrón que este proyecto ya pagó con `products.category` TEXT vs `category_id` hasta canonizarlo con un espejo por trigger.

*Y por qué eso sigue siendo "aditivo"*: para todo lector actual (`is_account_writer`, el hook, `rpc_my_account_role`, `useOrgRole`, el fallback a DB de `require_account_role`) el valor observable de `account_members.role` es **exactamente el mismo** antes y después. La Parte A no habilita ningún camino para asignar un rol funcional —no agrega superficie de asignación—, así que el espejo nunca tiene que representar un `seller` mientras A esté sola en prod.

*Restricción de orden que esto impone y que hay que respetar*: **ningún rol funcional puede asignarse hasta que B haya migrado `is_account_writer` al pivot**, porque el espejo mapearía un `seller` a `member` y la RLS lo dejaría sin escritura. La superficie de asignación (C) llega después de B, así que el orden firmado A→B→C ya lo garantiza — pero queda escrito para que sea una restricción y no una coincidencia.

*Alternativas descartadas*: **(a) legacy como fuente de verdad en A, invertir en B** — el pivot no podría alojar roles funcionales ni `expires_at` hasta B, dejando a C sin nada real que escribir, y concentra el riesgo en un único momento de inversión; **(b) sincronización bidireccional** — trampa de recursión, y no define quién gana ante conflicto; **(c) dropear `account_members.role` en A** — rompe de un saque los 5 lectores citados arriba, que es precisamente lo que la partición existe para evitar.

### D4 — "Rol activo" se resuelve por función `STABLE`, nunca por índice parcial

Activo ≡ `expires_at IS NULL OR expires_at > now()`. Un índice parcial con `now()` en el predicado **no es válido en Postgres** (predicado no inmutable) — ya lo señalaba el análisis de julio y sigue siendo cierto. Se expone `member_active_roles(p_member_id) RETURNS text[]` (`STABLE`) y `account_user_active_roles(p_account_id, p_user_id)`; los índices son B-tree comunes sobre `(member_id)` y sobre `(expires_at) WHERE expires_at IS NOT NULL` (este último para el barrido, y su predicado **sí** es inmutable).

### D5 — `owner` no admite `expires_at`

CHECK: `role <> 'owner' OR expires_at IS NULL`. Un `owner` con vencimiento es la forma más directa de que una cuenta se quede sin dueño **por el paso del tiempo**, sin ninguna acción humana que auditar ni ningún guard que se dispare. Prohibirlo en el DDL es más barato que cualquier salvaguarda posterior.

### D6 — El invariante "la cuenta nunca queda sin `owner` activo" es un constraint trigger **DEFERRABLE INITIALLY DEFERRED**

Se verifica **al final de la transacción**, no en cada fila: si la cuenta todavía tiene al menos un miembro y no tiene ningún `owner` activo → `P0405`.

*Por qué diferido y no `BEFORE`*: un `BEFORE DELETE` por fila rompe dos cosas legítimas. (1) Reasignar el `owner` (quitar el rol a A y dárselo a B en la misma transacción) pasa por un estado intermedio sin owner que un chequeo por fila rechazaría. (2) `account_member_roles.member_id` referencia `account_members(id)` con `ON DELETE CASCADE`; al expulsar al último miembro de una cuenta, el CASCADE borraría su fila `owner` y un chequeo por fila lo bloquearía — el mismo tipo de colisión con los `DELETE` de limpieza que `sucursal-guard-vaciado-auditoria` encontró en 15 gates SQL preexistentes. Con la verificación diferida, una cuenta que se queda **sin miembros** satisface el invariante de forma vacua (no hay a quién exigirle el rol), y una cuenta que conserva miembros debe conservar un `owner`.

*Gotcha a registrar en tasks*: `session_replication_role = replica` (41 wraps sobre 20 archivos de gates) desactiva los triggers, incluidos los constraint triggers. El gate que ejercita este invariante **no** puede correr bajo `replica`.

*Por qué en la tabla y no sólo en el RPC*: punto de paso obligado — cubre los caminos presentes y los futuros. Mismo principio que el guard de `branches` (`P0428`) y que el choke point de `c30_get_or_create_*`.

### D7 — Auditoría en `audit_logs`, sin notificaciones

Shape canónico de prod: `(account_id, user_id, action, entity_type, entity_id, metadata, created_at)`, con `entity_type = 'account_member_role'` y acciones `role.assigned`, `role.revoked`, `role.expired`. `metadata` lleva el rol, el `member_id`, el `expires_at` y —en revocación— quién revocó. Molde exacto de `trg_audit_branch_lifecycle` y de `rpc_update_charge_due_date`.

**Sin notificaciones**: `audit_logs` no lo lee la interfaz, y la decisión de `sucursal-guard-vaciado-auditoria` (G2) ya fijó ese criterio para el ciclo de vida de una entidad de configuración. Avisar a un miembro que le cambiaron el rol es una función de producto, no de auditoría; queda fuera.

### D8 — Claim nuevo `account_roles` (array); `account_role` (singular) se conserva como derivado

No es una decisión de este change: es una **restricción heredada** del requirement *"Contrato de evolución hacia múltiples roles por miembro"* de `authz-token-claims` (D2 de `v31-authz-token-hook`). El hook emite `account_roles` con los roles **activos** (filtrando vencidos en el momento de la emisión) y `account_role` con el de mayor precedencia según D3. **La forma del claim singular no se redefine para transportar un conjunto.**

*Tamaño*: 8 códigos cortos en el peor caso ≈ 80 bytes sobre `app_metadata` — irrelevante frente a cualquier límite de cabecera.

*Blindaje*: el hook conserva su `EXCEPTION WHEN OTHERS` con `RAISE WARNING` (nunca romper el login) — la emisión del claim nuevo entra **dentro** del mismo bloque protegido, no fuera.

### D9 — La ventana de staleness se acepta, y se acepta por una razón concreta

El guard prioriza el claim sobre la DB, así que un cambio de rol no se refleja hasta que el token se refresca (R3). Sign-off 6.5 = (a).

Lo que hace aceptable el riesgo no es la costumbre, es una **asimetría medible**: el caso urgente real —*sacar a alguien de la cuenta*— **no depende del claim**. `rpc_remove_member` borra la fila de `account_members`, y tanto `current_account_ids()` como todas las policies de RLS se evalúan contra la base en **cada query**; un token con claims viejos deja de ver y de escribir los datos de la cuenta de inmediato. Lo que queda diferido hasta el refresh es el caso menos urgente: *bajarle el grano de permiso a alguien que sigue siendo del equipo*. El barrido de D16 deja además rastro auditable de cada vencimiento, de modo que la ventana es observable y no silenciosa.

### D10 — Los guards comparan conjuntos de roles; las capacidades son constantes nombradas, no una tabla nueva

`require_account_role(conn, auth, allowed)` conserva su firma y su semántica ("el actor tiene **alguno** de los roles permitidos"), pero pasa a evaluar el **conjunto** de roles del actor. Los conjuntos permitidos dejan de escribirse como literales en cada service y se declaran una sola vez en `backend/core/rbac.py` con nombre de capacidad: `CAN_CONFIGURE`, `CAN_SELL`, `CAN_CASH`, `CAN_STOCK`, `CAN_PURCHASE`, `CAN_ACCOUNT`.

*Por qué no una tabla `account_role_capabilities`*: sería infraestructura nueva introducida en el mismo change que introduce el pivot, para una política que hoy tiene 6 entradas y cambia con la frecuencia de una decisión de producto. La Regla de Tres no está alcanzada. Las constantes nombradas ya eliminan la dispersión, que era el problema real.

*Y una aclaración que evita inventar un invariante falso*: la matriz FSM de la base (D15) y las constantes de capacidad **no son dos codificaciones de la misma política**. La FSM gobierna *cambios de estado de un documento*; las capacidades gobiernan *acceso a un endpoint*. Se solapan pero no son redundantes, así que no se escribe un gate que pretenda igualarlas. La tabla normativa única de la que ambas derivan es §D15 de este documento.

### D11 — `is_account_writer` conserva firma y sus 48 policies; sólo cambia el cuerpo

La función pasa a resolver `EXISTS (rol activo del usuario en la cuenta cuyo `is_writer` del catálogo sea `true`)`. Las **48 policies sobre 20 tablas no se tocan**, ni sus nombres ni sus predicados. `current_account_ids()` **no se toca** en absoluto (resuelve tenencia, no rol).

*Por qué*: reescribir el cuerpo de una función es una unidad revisable; reescribir 48 policies en el change más riesgoso multiplica el radio de impacto sin cambiar el resultado para ningún rol existente. Y derivar el conjunto de escritores del catálogo (`is_writer`) en vez de hardcodearlo hace que el día que se agregue un rol no haya que volver a tocar RLS.

*Rendimiento, medido en la ronda 1 adversarial (minor 2)*: la primera versión de este cuerpo delegaba en `account_user_active_roles(account_id, user_id)` — que a su vez llama `member_active_roles(member_id)` — para resolver el `member_id` de `(account_id, auth.uid())`: DOS saltos SECURITY DEFINER anidados por invocación, contra UNO solo del cuerpo viejo de prod (`EXISTS ... account_members WHERE role IN ('owner','admin')`). Medido en local (`EXPLAIN ANALYZE`, tabla temporal de 5.000 filas, `qual = is_account_writer(account_id)` — misma forma que las 48 policies reales —, `request.jwt.claims` de un owner real, 2 corridas): cuerpo VIEJO ~93-95 ms/5.000 filas (~0,019 ms/fila); cuerpo de DOS saltos ~2.320-2.436 ms (~0,46-0,49 ms/fila, **~24-26× más lento**). Mismo contraste con un bucle de 10.000 llamadas directas: ~3,3× (el overhead fijo del bucle PL/pgSQL domina y comprime la diferencia relativa, pero la dirección es la misma). El cuerpo FINAL de esta migración resuelve `account_members` en la MISMA consulta (un solo salto, vía `member_active_roles` directo, sin pasar por `account_user_active_roles`) — mide ~753-764 ms (~0,15 ms/fila, ~8× más lento que el viejo, recupera ~2/3 del overhead agregado) **sin duplicar la definición canónica de "rol activo"**: el predicado de vencimiento (`expires_at`) sigue viviendo EXCLUSIVAMENTE en `member_active_roles` (D4). Impacto real acotado (sin cambiar el análisis de arriba: la mayoría de las escrituras van por RPCs SECURITY DEFINER como `postgres`, donde la RLS no se evalúa) — el peor caso medido (recategorización en lote de productos, `product_repository.py`, tope 500/tanda) pasa de ~+330 ms/tanda (cuerpo de dos saltos) a ~+65 ms/tanda (cuerpo final). Detalle completo, incluida la metodología, en `CHANGES.md` y en el comentario de la sección 1 de `20261048000001_v3_rbac_multirole_parte_b.sql`.

*Re-verificado en la ronda 2 adversarial (nit 3)*: una pasada intermedia de esa ronda había reportado, para el cuerpo MERGIDO, ~79,1/84,2 ms/5.000 filas (~1,3× el viejo) y concluido que la cifra de arriba (~753-764 ms, ~8×) era la cota pesimista de una base con más volumen. Re-medido con el MISMO protocolo pero en una sesión aislada, con el orden de las tres corridas intercambiado (mergido medido ANTES que viejo/dos-saltos, para descartar un artefacto de caché de sesión) y **5 corridas** en vez de 2 para el cuerpo mergido: viejo ~69-73 ms/5.000 filas (~0,014 ms/fila); dos-saltos (reconstrucción fiel al cuerpo pre-ronda-1) ~1.221-1.251 ms (~0,245 ms/fila, ~17-18×); **mergido (llamando directo a la función LIVE, no una reconstrucción) ~728-815 ms (~0,15 ms/fila, ~11× el viejo)**. Esto CONFIRMA el orden de magnitud ya documentado (~8-11×), no el ~1,3× de la pasada intermedia, que no reprodujo bajo este protocolo (control de orden incluido). Segunda metodología, independiente (bucle de 10.000 llamadas directas, sin tabla temporal, 2 corridas): viejo ~153 ms; dos-saltos ~2.556-2.697 ms (~17×); mergido ~2.424-2.489 ms (~16×) — misma conclusión por un camino que no pasa por el planner de `EXPLAIN`. El número exacto depende del volumen de `account_members`/`account_member_roles` de la base medida (acá: 14 miembros, 16 asignaciones de rol) y puede variar entre entornos — pero el orden de magnitud (~8-17× el viejo, muy por debajo del ~24-26× del cuerpo de dos saltos) es estable entre las tres mediciones independientes hechas hasta ahora (ronda 1, esta verificación, y la parte de OLD/dos-saltos de la pasada intermedia, que sí coincidió). Números y protocolo completo en `CHANGES.md` y en el comentario de la sección 1 de `20261048000001_v3_rbac_multirole_parte_b.sql`.

### D12 — La separación fina por dominio **no** baja a la RLS en este change

Después de B, la RLS distingue **escritor / no escritor** (un `viewer` no escribe nada), y la separación fina entre `cashier`, `stock`, `purchases` y `accountant` la hace cumplir el **backend**.

*Riesgo residual, declarado y no disimulado*: un usuario autenticado con rol `cashier` que arme una llamada directa a PostgREST podría escribir en `products`, porque la policy sólo pregunta `is_account_writer`. Se acepta por tres razones acotadas: (1) **medido** — el navegador de esta aplicación no escribe ninguna de esas 20 tablas por PostgREST; el camino real es FastAPI, donde el guard fino sí aplica; (2) la separación que hoy **no existe en absoluto** y que sí queda cubierta es la de solo-lectura (`viewer`), que es la de mayor valor inmediato; (3) migrar 48 policies a helpers por dominio dentro del mismo corte que introduce el pivot es exactamente la clase de big-bang que rompe el POS un sábado.

*Queda como candidato con nombre*: **`rbac-rls-grano-fino`** — helpers `is_account_writer_for(account_id, domain)` y migración de las 48 policies, en su propio change.

### D13 — `document_status_transitions.allowed_role` pasa de `text` a `text[]`

`ALTER COLUMN allowed_role TYPE text[] USING (CASE WHEN allowed_role IS NULL THEN NULL ELSE ARRAY[allowed_role] END)`. Con 0/19 filas pobladas el `USING` es un no-op sobre datos reales.

*Consecuencia que hay que declarar en vez de disimular*: la spec `document-status-history` afirma hoy —requirement *"Dimensión de rol estructurada para RBAC futuro"*— que *"basta un `UPDATE` de datos (sin `ALTER TABLE`)"* para restringir una transición. Esa promesa se escribió bajo el supuesto de **un** rol por transición; la matriz real necesita conjuntos (`quote draft→sent` corresponde a `seller` **y** `admin` **y** `owner`). El delta **MODIFICA** ese requirement con su `Reason` explícito, en lugar de fingir que se cumple.

*Alternativa descartada*: tabla puente `document_status_transition_roles`. Dejaría `allowed_role` viva e inerte como una segunda dimensión muerta al lado de la real — precisamente el problema que este change viene a cerrar.

### D14 — `record_status_transition` valida el rol del actor, con dos exenciones explícitas

Dentro del helper, después de validar la transición y el motivo:

- `p_performed_by IS NULL` → **contexto de sistema**, exento. Es el caso del relay CAE y del cron de expiración de presupuestos, donde `auth.uid()` es NULL. Mismo principio con el que `python-backend` exime al contexto de servicio de los guards de usuario.
- `allowed_role IS NULL` → **sin restricción de rol**. Es lo que mantiene inertes las filas de sistema (`fiscal_document.*`, `quote → expired`) aunque el actor venga no nulo.
- En cualquier otro caso: los roles activos del actor en `p_account_id` deben intersecar `allowed_role`, o `P0403` (ya mapeado a 403 en `backend/core/errors.py`).

*Verificado sobre los llamadores reales*: los 10 `PERFORM record_status_transition(...)` pasan `auth.uid()`, `v_uid` o `v_performed_by`. Con las 39 cuentas actuales al 100% `owner`, todas las filas de la matriz los admiten, así que el apply de B **no cambia el resultado de ninguna operación existente**. Una task de checkpoint reconfirma caller por caller antes de escribir SQL.

**BREAKING de dominio declarado**: desde el apply de B, una transición ejecutada por un rol insuficiente se rechaza. Es el objetivo del change, no un efecto colateral.

*Refinamiento de la ronda 1 adversarial (minor 3)*: "no hay fila en la matriz" y "la fila existe con `allowed_role` NULL" son dos casos DISTINTOS que la implementación original confundía (ambos dejaban la variable de rol permitido en NULL y caían en la misma rama sin distinguirse). Hoy "sin fila" sólo alcanza a transiciones de CREACIÓN no catalogadas (`from_status IS NULL`) — para `from_status` no nulo, `is_valid_transition` (RN-A4) ya aborta con `P0409` antes de llegar al chequeo de rol. Criterio CONSERVADOR de esta ronda (D17/11.7: con las 39 cuentas 100% owner, ninguna transición real cambia de resultado): **NO se rechaza** una creación no catalogada — la exención de facto se mantiene, ahora explícita en el código (`v_row_found`) y vigilada por un gate de cobertura que enumera los pares `(document_type, from_status, to_status)` de los 12 llamadores vivos y asserta que están todos catalogados. **Endurecer esto a `P0409` (rechazar una creación no catalogada) queda como candidato de la Parte C o posterior** — no se hace en esta ronda para no introducir un comportamiento nuevo sin sign-off explícito del PO fuera del alcance firmado de la Parte B.

### D15 — Matriz rol × transición (tabla normativa única, 19 filas)

Reconfirma el bosquejo de julio sobre las 19 filas vigentes, incluida la única fila nueva desde entonces (`sales_order confirmed→canceled`).

| `document_type` | `from → to` | `allowed_role` | Razón |
|---|---|---|---|
| `quote` | `NULL → draft` | `seller, admin, owner` | crear presupuesto es tarea de venta |
| `quote` | `draft → sent` | `seller, admin, owner` | enviar al cliente |
| `quote` | `draft → accepted` | `seller, admin, owner` | cierre de venta |
| `quote` | `sent → accepted` | `seller, admin, owner` | cierre de venta |
| `quote` | `draft → expired` | `NULL` (sistema) | expiración automática, sin actor humano |
| `quote` | `sent → expired` | `NULL` (sistema) | idem |
| `quote` | `draft → rejected` | `seller, admin, owner` | registrar rechazo del cliente |
| `quote` | `sent → rejected` | `seller, admin, owner` | idem |
| `sales_order` | `NULL → draft` | `seller, cashier, admin, owner` | el POS lo puede iniciar un cajero |
| `sales_order` | `draft → confirmed` | `seller, cashier, admin, owner` | RN-A4: "`cashier` cobra" — éste es el punto donde cobra |
| `sales_order` | `confirmed → canceled` | `admin, owner` | RN-A4: "**pero no anula**". Anular una venta confirmada revierte caja, cuenta corriente y asiento contable; no es una acción de mostrador |
| `fiscal_document` | `NULL → pending_cae` | `NULL` (sistema) | lo emite el backend, no una persona |
| `fiscal_document` | `pending_cae → authorized` | `NULL` (sistema) | relay/webhook ARCA |
| `fiscal_document` | `pending_cae → rejected` | `NULL` (sistema) | idem |
| `cash_session` | `NULL → open` | `cashier, admin, owner` | abrir caja es tarea de cajero |
| `cash_session` | `open → closed` | `cashier, admin, owner` | el arqueo lo hace quien opera la caja |
| `reconciliation_session` | `NULL → open` | `accountant, admin, owner` | conciliación bancaria es tarea contable |
| `reconciliation_session` | `open → closed` | `accountant, admin, owner` | idem |
| `stock_transfer` | `NULL → completed` | `stock, admin, owner` | RN-A4: "`stock` ajusta con motivo" — las transferencias son su dominio |

*Gap conocido, no bloqueante*: la otra mitad de RN-A4 —"`stock` **no confirma compras**"— no tiene dónde aplicarse todavía: `purchases` no participa de `document_status_transitions` (no está entre los 6 `document_type` sembrados). El enforcement equivalente vive en el guard del backend (`CAN_PURCHASE` sin `stock`), y la fila FSM llegará el día que compras entre al patrón.

*Matriz de capacidades del backend (D10), derivada de la misma tabla*: `CAN_CONFIGURE` = `owner, admin` (catálogos, centros de costo, formas de pago, categorías — las 15 llamadas actuales quedan **exactamente iguales**) · `CAN_SELL` = `owner, admin, seller, cashier` · `CAN_CASH` = `owner, admin, cashier` · `CAN_STOCK` = `owner, admin, stock` · `CAN_PURCHASE` = `owner, admin, purchases` · `CAN_ACCOUNT` = `owner, admin, accountant`.

### D16 — El barrido de vencimientos audita; no borra

`pg_cron` diario que, por cada asignación cuyo `expires_at` ya pasó y que todavía no tiene su entrada `role.expired`, inserta esa entrada en `audit_logs`. **No borra la fila del pivot**: la fila vencida *es* el rastro de que alguien tuvo ese rol hasta esa fecha, y `member_active_roles` ya la excluye por predicado. Dedup por día argentino, mismo patrón que el digest de `cobranzas-vencimientos` (D8).

*El barrido no es el mecanismo de corte.* El corte lo produce el predicado de D4, evaluado en cada emisión de claims y en cada guard. Si el cron se cae, nadie gana permisos de más — sólo se pierde el asiento de auditoría, que el barrido siguiente recupera porque es idempotente.

### D17 — El gate "`admin` requiere plan `pro`" se retira en la Parte C, no en la A

Sign-off 6.2 = (b). El gate vive hoy en tres lugares: `rpc_change_member_role`, `rpc_invite_member` y la UI (`availableRoles` + el aviso azul de `/organizacion/roles`).

*Por qué en C y no en A*: la Parte A tiene que ser **indistinguible** en comportamiento; quitar un gate comercial es un cambio de producto observable. Va junto con la superficie que lo hace visible. En A los tres lugares se conservan byte a byte.

*Efecto colateral a corregir en el mismo PR de C*: `knowledge-base/03_actores_y_roles.md` promete en su tabla comercial "Roles internos: ❌ / ❌ / Básicos / Avanzados" por plan. La decisión del PO la deroga; la KB se corrige ahí, no se deja mintiendo. (`CLAUDE.md`/`AGENTS.md` no se tocan.)

### D18 — `max_users` sigue contando **miembros**, no roles

Un miembro con cuatro roles cuenta **uno**. Es lo que ya hacen `rpc_invite_member` y `rpc_accept_invitation` (`COUNT(*) FROM account_members`), y es lo que la tabla comercial vende ("Usuarios: 1 / 2 / 5 / 10"). No se toca el conteo.

*De paso, en la Parte C*: `rpc_invite_member` y `rpc_accept_invitation` levantan hoy `P0001` para cupo agotado, invitación duplicada y falta de permisos — contra la regla del proyecto (ERRCODEs `P04xx`, nunca `P0001`). Se normalizan **conservando el texto del mensaje**, mismo precedente que `rpc_close_branch` cuando pasó de `P0409` a `P0428`.

### D19 — Frontend: el singular sobrevive, el *fail-open* se preserva literalmente

`OrgRole` pasa a la unión de los 8 códigos. `useOrgRole()` devuelve `{ role, roles, isWriter, isLoading }`: `role` sigue siendo el **derivado singular de mayor precedencia** (lo que consumen las ~40 pantallas), `roles` es el array nuevo y sólo lo consume la pantalla de gestión.

`isWriter` conserva su semántica *fail-OPEN* explícitamente documentada en el hook ("sólo un `member` CONFIRMADO es de solo-lectura; cualquier estado desconocido se trata como escritor para no bloquear falsamente a un owner"). Pasa a `role !== "viewer" && role !== "member"` — **los dos** valores, porque `"member"` puede seguir llegando de una caché de React Query de 5 minutos o de un token viejo. Convertir ese *fail-open* en *fail-closed* por descuido bloquearía a un owner real con un cartel de "Solo lectura" (R8); la barrera verdadera sigue siendo RLS + el guard del backend.

### D20 — El selector de cuenta activa queda fuera

La ficha de `CHANGES.md` le asigna a este change el diseño del selector de cuenta activa explícito (claim `account_id`), por ser "el primer change donde la multi-membresía real existe". Se declara **fuera de alcance**: las 7 respuestas del PO no lo incluyen, hoy **0 usuarios pertenecen a más de una cuenta**, y `v4-plataforma-01` ya lo tiene en su propio scope ("invitación masiva + selector de cuenta activa determinístico"). La resolución determinística que ese selector necesitaría ya existe (`ORDER BY created_at, id`, D4 de `v31-authz-token-hook`), así que no se pierde nada por esperar. Se registra como **OQ-1** para que el PO pueda contradecirlo si lo prefiere acá.

---

## Risks / Trade-offs

**R1 — Una cuenta se queda sin `owner`.** → D5 (un `owner` no puede vencer) + D6 (constraint trigger diferido en el pivot, `P0405`, punto de paso obligado que cubre revocación, expulsión y CASCADE) + el guard preexistente de `rpc_change_member_role` conservado. Gate SQL dedicado con las cuatro formas de intentarlo (revocar el último `owner`, degradarlo, borrar su fila del pivot, y reasignarlo a otro miembro en la misma transacción — esta última **debe pasar**).

**R2 — Un rol vence a mitad de una operación multi-request.** Una venta en el POS puede empezar con `cashier` válido y terminar después del vencimiento. → Se evalúa **al entrar** a cada request, no dentro de la operación; la ventana es de un request. Documentado como aceptable, mismo criterio que ya rige para `expires_at` de invitaciones. Lo contrario —re-evaluar en cada paso— haría fallar operaciones a mitad de camino, que es peor que dejarlas terminar.

**R3 — Claims viejos ganan sobre la DB hasta el refresh.** → D9: aceptado (sign-off 6.5 = (a)), con la asimetría que lo hace defendible (expulsar es inmediato porque no pasa por el claim; degradar espera al refresh) y con rastro auditable de cada vencimiento (D16).

**R4 — RLS y guards divergiendo durante la migración.** Desde `v31-tenancy-pool-rls` la RLS es real para el backend, así que dos fuentes de verdad distintas producirían 403 falsos o —peor— autorizaciones que deberían ser bloqueos. → `is_account_writer` (RLS) y `require_account_role` (guard) migran **en la misma migración y el mismo PR** (Parte B), nunca en cortes separados. El gate de la Parte B ejercita las dos capas sobre el mismo usuario.

**R5 — Doble fuente de verdad legacy/pivot.** → D3: un solo camino de escritura, espejo por trigger, y gate que asserta `account_members.role ≡ precedencia(member_active_roles)` para las 39 filas.

**R6 — El fallback a DB de `require_account_role` lee una columna que dejó de ser la verdad.** El fallback actual (`SELECT role FROM account_members … LIMIT 1`) asume rol singular. → Se reescribe **en el mismo PR** que migra el guard (Parte B), leyendo el pivot. Mientras tanto (Parte A sola en prod), el espejo garantiza que la columna sigue dando la respuesta correcta.

**R7 — Cero uso real como superficie de prueba.** 0/39 cuentas con 2+ miembros: todo el enforcement multi-rol se estrena con datos sintéticos. → El humo de la Parte C incluye que el PO **cree una segunda membresía en una cuenta de prueba** (nunca en una cuenta con datos de un cliente real) y ejercite un rol funcional de punta a punta. Hasta que eso ocurra, la evidencia de B es gate SQL + tests, no tráfico real — y así se declara, en vez de llamarlo "verificado en producción".

**R8 — Las ~40 pantallas que leen `accountRole`/`isWriter`.** → D19: el derivado singular sobrevive con la misma forma, y el *fail-open* se preserva contemplando **los dos** valores de solo-lectura (`viewer` y el legacy `member`).

**R9 — Reescribir funciones vivas a partir del archivo equivocado.** Ocho funciones de prod se reescriben (`is_account_writer`, `record_status_transition`, `custom_access_token_hook`, `rpc_change_member_role`, `rpc_remove_member`, `rpc_invite_member`, `rpc_accept_invitation`, `rpc_my_account_role`) y este proyecto ya se quemó con un `pg_get_functiondef` vivo que había divergido del último archivo de migración. → Regla de integridad de función: **cada reescritura parte del cuerpo vivo de prod**, con checkpoint de `md5` medido en la task. *Gotcha ya registrado*: el `md5` local y el de prod difieren por los CRLF del checkout de Windows — comparar por líneas con `\r` removido, no por hash crudo.

**R10 — `P0405` nuevo y la cadena de reaplicación de `KPI_Validation.yml`.** → `P0405`, `P0406` verificados libres hoy (0 usos en `supabase/` y `backend/`); se mapean en `backend/core/errors.py` en el mismo PR que los introduce, y la migración de cada parte se suma al paso de reaplicación idempotente del workflow.

---

## Migration Plan

Tres migraciones, una por parte. **Números provisorios** — `MAX(version)` en prod al 2026-09-11 es `20261045000001`, así que la próxima libre es `20261047000001`; cada apply **reconfirma el número contra prod** en su task de checkpoint antes de escribir SQL (este proyecto ya renumeró una migración tres veces por PRs concurrentes).

| Parte | Migración provisoria | Contenido | Governance | Reversible |
|---|---|---|---|---|
| **A** | `20261047000001` | `account_role_catalog` + `account_member_roles` + triggers de espejo, invariante y auditoría + backfill idempotente + reescritura de los 3 RPCs de membresía | HIGH | Sí, sin pérdida: se deja de escribir el pivot y `account_members.role` vuelve a ser la única verdad (su valor ya es el correcto) |
| **B** | `20261047000001` | `is_account_writer` (cuerpo) + `custom_access_token_hook` (claim `account_roles`) + `allowed_role → text[]` + matriz de 19 filas + `record_status_transition` + barrido `pg_cron` + guards del backend | **CRÍTICO** | Sí: revertir los cuerpos de función a su definición previa (guardada en el propio PR) devuelve el comportamiento exacto; la matriz se desactiva con un `UPDATE … SET allowed_role = NULL` |
| **C** | `20261048000001` | RPCs de asignación/revocación + retiro del gate `admin`⇒`pro` + normalización de ERRCODEs de invitación + endpoints FastAPI + superficie `/organizacion/roles` y `/organizacion/invitar` | MEDIO | Revert de frontend estándar; las asignaciones múltiples ya hechas quedan en la tabla, inertes hasta re-desplegar |

**Backfill (Parte A)**: `INSERT INTO account_member_roles (member_id, role, assigned_at) SELECT id, 'owner', created_at FROM account_members ON CONFLICT DO NOTHING` — 39 filas, sin ambigüedad (no hay ningún `admin` ni `member` real que preservar). Idempotente, como exige el auto-apply de Supabase. `assigned_by` queda NULL: nadie asignó ese rol, lo trajo el provisioning.

**Auditoría de daño histórico**: **n/a**. Las tres partes son o aditivas o endurecedoras; no hay una clase de dato mal escrito en el pasado que reparar. Lo que sí se mide en cada verificación post-merge es que el endurecimiento **no** haya roto nada (rechazos del guard = 0 esperado, dado que las 39 cuentas son `owner`).

**Verificación en prod por parte** (read-only, agregados, sin PII):

- **A**: `MAX(version)`; `count(*)` del pivot = `count(*)` de `account_members`; **0** filas con `account_members.role` distinto de la precedencia derivada del pivot; los 3 RPCs vivos sin overload duplicado; ACLs sin `EXECUTE` para `anon`.
- **B**: `allowed_role` poblado en **14 de las 19** filas — las 5 restantes quedan NULL **a propósito** (las 3 de `fiscal_document` y las 2 de `quote → expired`, todas transiciones de sistema); el gate asserta el reparto 14/5 exacto contra la matriz de D15, no sólo "alguna poblada"; cuerpo vivo de `is_account_writer` leyendo el pivot; `account_roles` presente en `auth_logs` del hook (nunca vía `raw_app_meta_data`, trampa ya documentada); cron registrado y activo; **0** rechazos `P0403` de transición en los logs (control positivo incluido, para distinguir "no hubo rechazos" de "no hubo tráfico").
- **C**: alta real de un rol funcional en una cuenta de prueba; `audit_logs` con la entrada `role.assigned`; ausencia del gate de plan en el cuerpo vivo de los RPCs.

**Humo del PO por parte**: A no tiene humo (sin superficie); B lo verifica el PO confirmando que su operación diaria sigue funcionando igual (vender, cobrar, cerrar caja); C es el humo real del change — crear una segunda membresía de prueba, asignarle `cashier` con vencimiento, comprobar que puede cobrar y no puede anular, y que al vencer pierde el acceso.

---

## Open Questions

**OQ-1 — ¿El selector de cuenta activa entra acá o se queda en `v4-plataforma-01`?** (no bloqueante)
La ficha de `CHANGES.md` se lo asigna a este change; las 7 respuestas del PO no lo mencionan; hoy 0 usuarios pertenecen a 2+ cuentas y `v4-plataforma-01` ya lo tiene en su scope.
**Recomendación: dejarlo en `v4-plataforma-01`** (D20). Traerlo acá agregaría un claim `account_id` y una UI de cambio de organización a un change que ya toca auth, RLS y FSM, sin ningún usuario que hoy lo necesite.

**OQ-2 — ¿El vencimiento de un rol le avisa a alguien?** (no bloqueante)
D16 sólo audita. Un aviso al `owner` ("el acceso temporal de X venció") sería útil pero es función de producto, y `v3-notifications-realtime` ya provee el canal.
**Recomendación: no en este change.** Se registra como candidato; agregarlo después es un consumer más del outbox, sin migración de datos.

**OQ-3 — ¿`accountant` debería poder cerrar una sesión de caja?** (no bloqueante, afecta 1 fila de D15)
La matriz asigna `cash_session open→closed` a `cashier, admin, owner`. En una PyME el arqueo lo suele revisar quien lleva los números.
**Recomendación: dejarlo como está.** Cerrar caja escribe el arqueo y dispara la compensación; es una operación de mostrador, y `admin`/`owner` cubren el caso del dueño que cierra. Si el PO lo pide, es un `UPDATE` de una fila del catálogo, sin migración de esquema.
