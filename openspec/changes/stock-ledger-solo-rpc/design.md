## Context

> **Governance: ALTA** (ledger de stock + revocación de privilegios, con un tramo cross-tenant). Sign-off del PO 2026-10-08 sobre las cinco decisiones del candidato; este design decide el *cómo* y deja abiertas sólo las preguntas que esas cinco no cubren.

### Lo que está medido contra producción

Todo en **sólo lectura** (`mcp__supabase__execute_sql`, proyecto `gxdhpxvdjjkmxhdkkwyb`). Las cifras de 2026-10-03 vienen de la ficha del candidato en `CHANGES.md`; las de 2026-10-08 se re-midieron para este propose.

**Privilegios y policies vivas (re-leídas 2026-10-08):**

| Tabla | `relacl` | RLS | Policies |
|---|---|---|---|
| `branch_stock` | `authenticated=arwdDxtm`, `anon=rxtm` | on, no forced | `branch_stock_member_select` (SELECT, `account_id IN current_account_ids()`), `branch_stock_writer_insert` (INSERT, `WITH CHECK is_account_writer(account_id)`), `branch_stock_writer_update` (UPDATE, USING + CHECK `is_account_writer`) |
| `stock_movements` | `authenticated=arwdDxtm`, `anon=rxtm` | on, no forced | `stock_movements_account_insert` (INSERT, `WITH CHECK account_id IN current_account_ids()` — cualquier miembro, `viewer` incluido), `stock_movements_account_select` (SELECT), `stock_movements_no_update` / `stock_movements_no_delete` (`USING false`) |

`branch_stock` no tiene policy de `DELETE` (la RLS lo deniega), pero `authenticated` conserva el privilegio de `TRUNCATE` sobre las dos tablas, y **la RLS no se aplica a `TRUNCATE`**: hoy la única barrera es que PostgREST no lo expone.

**Escritores de las dos tablas (re-barrido 2026-10-08 sobre `pg_get_functiondef` de todo `public`):**

| Función | `SECURITY` | `EXECUTE` para `authenticated` | Escribe |
|---|---|---|---|
| `rpc_apply_product_stock_delta` | DEFINER | **sí** | `stock_movements` (+ saldo vía `c21`) |
| `rpc_stock_adjustment` | DEFINER | **sí** | `stock_movements` (+ saldo vía `c21`) |
| `rpc_adjust_branch_stock` | DEFINER | **sí** | las dos |
| `rpc_transfer_stock` | DEFINER | **sí** | las dos |
| `rpc_reverse_stock_movement` | DEFINER | **sí** | `stock_movements` (+ saldo vía `rpc_apply_product_stock_delta`) |
| `rpc_set_product_min_stock` | DEFINER | sí | `branch_stock` (sólo `min_stock`) |
| `rpc_create_sale_operation(_v2)`, `rpc_create_purchase_operation`, `_c29_confirm_order_core` | DEFINER | sí | `stock_movements` (+ saldo) |
| `op_stock_movement`, `rpc_bulk_upsert_products`, `rpc_create_purchase_operation_v2` | DEFINER | no | ídem |
| `c21_apply_branch_stock_delta`, `_delivery_note_apply_stock`, `_delivery_note_reverse_held` | **INVOKER** | no | sólo invocados desde DEFINER |

Ninguna función trigger escribe estas tablas. **Callers SQL** de las RPCs que se tocan: `rpc_apply_product_stock_delta` ← sólo `rpc_reverse_stock_movement`; `rpc_reverse_stock_movement` ← sólo `rpc_delete_sale_operation` y `rpc_delete_purchase_operation`; `rpc_stock_adjustment`, `rpc_adjust_branch_stock` y `rpc_transfer_stock` ← ninguna función SQL.

**Callers de aplicación:** `backend/repositories/product_repository.py:21` (`rpc_apply_product_stock_delta` desde `POST`/`PUT /products`, con `(…, 'Stock inicial'|'Ajuste manual de stock', TRUE, FALSE)`); `backend/repositories/stock_repository.py:78` (`adjust_with_event`, **sin callers**, el único `p_log_movement = FALSE` del repo); `backend/repositories/stock_repository.py:54` (`rpc_transfer_stock` desde `POST /stock/transfer`); `frontend/components/stock/stock-adjustment-modal.tsx:243` y `stock-import-adjustment-dialog.tsx:224` (`rpc_stock_adjustment`); `frontend/hooks/data/use-branch-stock.ts:192` (`rpc_adjust_branch_stock`) y `:219` (`rpc_transfer_stock`). `use-branch-stock.ts` **no** escribe las tablas directo (sólo `select` en L88/L135).

**Tráfico (2026-09-20 → 10-03):** 0 escrituras directas a las dos tablas, 0 llamadas directas a `rpc_apply_product_stock_delta`/`rpc_reverse_stock_movement`/`rpc_adjust_branch_stock`/`rpc_transfer_stock`; el navegador sólo llama a `rpc_stock_adjustment` (7 veces, coinciden día por día con filas del ledger).

**Datos del ledger (2026-10-08):**

| `type` | `reference_type` | sin motivo | con motivo |
|---|---|---|---|
| `adjustment` | NULL | **12** | 1.794 |
| `physical_count` | NULL | **6** | 22 |
| `initial` | `initial` | 43 | 0 |
| `transfer_in` / `transfer_out` | `transfer` | 518 / 518 | 0 |
| `loss`, `damage`, `expiry`, `return` | — | 0 | 0 |

Ningún `transfer_in`/`transfer_out` manual (todos llevan `reference_type = 'transfer'`, es decir, salen de `rpc_transfer_stock`). Productos por control de stock: 4.932 `tracked`, 653 `variant_only` (0 `untracked`); **5 filas de saldo ≠ 0 sobre padres `variant_only`** y 2 movimientos manuales sobre ellos (RN-20 ya violado por el camino de FastAPI, que no lo valida).

**Exposición:** 41 cuentas, 0 multiusuario, 17 con stock, 1 con más de una sucursal activa. Daño histórico 0. `MAX(version)` en prod = `20261072000001` (319 migraciones), igual al último archivo del repo.

### Cuerpos vivos de partida

Los cinco cuerpos que se reescriben, con su md5 de `pg_get_functiondef` (2026-10-08), están en el **Anexo A**. La regla del proyecto rige: la reescritura parte del cuerpo **vivo**, y el apply vuelve a capturar y comparar los md5 antes de escribir SQL (comparando por líneas sin CR: un md5 local distinto puede ser sólo CRLF del checkout).

### Constraints que el diseño respeta

- **Nunca `DROP FUNCTION`** sobre una RPC con callers: resetea la ACL a `EXECUTE` para `PUBLIC`. Todas las reescrituras son `CREATE OR REPLACE` con la misma firma (que además no admite quitar `DEFAULT`s: las firmas con defaults se conservan tal cual), con el `REVOKE`/`GRANT` re-afirmado en el mismo archivo.
- **Toda función nueva tiene un gate que la ejecuta**, no sólo que verifica que existe.
- **Al endurecer un contrato, migran todos los callers en el mismo PR.**
- **Reutilización antes que repetición**: el guard de rol calca `_quote_assert_can_write`; la aritmética de saldo reutiliza el cuerpo vivo de `rpc_apply_product_stock_delta`; el espejo de capacidad del frontend sigue `lib/rbac-capabilities.ts`; los errores van al mapa canónico `lib/operation-errors.ts`.
- **`remitos-venta` y `remitos-compra` están en curso en otra sesión**: tocan `_delivery_note_*` (no se tocan acá) y son dueños de `test_remitos_venta.sql`/`test_remitos_compra.sql`, cuyo bloque (f) este change modifica (riesgo R3).

## Goals / Non-Goals

**Goals:**

- Que ningún rol de aplicación pueda escribir `stock_movements` ni `branch_stock` sino a través de una función `SECURITY DEFINER` que ya validó al usuario (tanda A).
- Que el ajuste manual de stock tenga **un solo núcleo**, con rol `owner`/`admin`/`stock` y motivo exigidos **en la base**, tenencia por `products.account_id` y sello de cuenta, sucursal y autor (tanda B).
- Que cambiar un saldo **sin** dejar movimiento deje de ser alcanzable desde `authenticated` (tanda B).
- Que la superficie existente muestre el ajuste sólo a quien puede y siempre pida el motivo (tanda B).

**Non-Goals:**

- **Importador de productos → ledger** (decisión firmada 5): `rpc_bulk_upsert_products` sigue fijando la cantidad absoluta sin movimiento.
- Tipos `initial` y `return` sin escritor vivo: no se tocan ni se retiran del `CHECK` de tipos.
- `v_products_with_stock`: ya es `security_invoker = true`.
- Rol de las **transferencias** (OQ-3): siguen con `is_account_writer`.
- Corregir los 5 saldos de padres `variant_only` ni el `ON DELETE CASCADE` de `stock_movements.user_id` (hallazgos laterales, §"Hallazgos laterales").
- Gating por rol de cuenta del resto del CRUD de productos (`POST`/`PUT /products` siguen con el guard de **plataforma** para nombre, precio, etc.): sólo el stock gana guard de cuenta.
- Rutas, entradas de menú o pantallas nuevas.

## Decisions

### D1 — Dos tandas, un change (decisión firmada 3)

**Tanda A** (`20261073000001`) sólo revoca y borra policies: no reescribe ninguna función, no toca callers, y por lo medido no rompe ningún camino de producción. Es chica a propósito para que su revisión sea de privilegios y nada más. **Tanda B** (`20261074000001`) reescribe las RPCs, migra backend y frontend y suma las specs.

**Lo que la tanda A deja abierto, declarado:** el ajuste **sin rol** por `rpc_apply_product_stock_delta`, `rpc_stock_adjustment` y `rpc_adjust_branch_stock`, incluido el cambio de saldo sin movimiento por `p_log_movement = false`. Con la forja y la reversa pública cerradas, lo que queda ya no fabrica stock por encadenamiento, pero sigue permitiendo a cualquier escritor mover un saldo sin el rol firmado. Ese intervalo tiene población cero hoy (0 cuentas multiusuario).

*Alternativa descartada:* un solo PR con todo. Mezcla una revisión de privilegios (que tiene que ser rápida y obvia) con la reescritura de cinco RPCs y dos superficies.

### D2 — Tanda A: cierre por privilegio **y** por policy; se conservan las `qual = false`

```sql
DROP POLICY IF EXISTS stock_movements_account_insert ON public.stock_movements;
DROP POLICY IF EXISTS branch_stock_writer_insert     ON public.branch_stock;
DROP POLICY IF EXISTS branch_stock_writer_update     ON public.branch_stock;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.stock_movements FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.branch_stock    FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_reverse_stock_movement(uuid, text, text) FROM PUBLIC, anon, authenticated;
```

- **Las dos capas, no una.** El `REVOKE` es la barrera (y la única para `TRUNCATE`, que la RLS no cubre). El `DROP POLICY` es la segunda red: si una migración futura hace un `GRANT` amplio sobre el esquema, sin policy permisiva de escritura la RLS sigue denegando `INSERT`/`UPDATE`/`DELETE`.
- **`stock_movements_no_update` / `_no_delete` se conservan.** Tras el `REVOKE` son redundantes, y ante un re-`GRANT` también lo serían (sin policy permisiva la RLS ya deniega). Se quedan porque cuestan cero, RN-21 las cita como su mecanismo, y el gate asserta la forma exacta de la tabla de policies (dos de lectura + dos `qual = false`), así que borrarlas sería un cambio de spec y no una limpieza.
- **`anon` se incluye** aunque hoy no tenga esos privilegios: idempotente, y es el molde de `presupuestos-modulo` (`quotes`) — el `REVOKE` documenta la intención para ambos roles.
- **`rpc_reverse_stock_movement` pasa a interna sin tocar su cuerpo.** Sus dos callers son `SECURITY DEFINER` (corren como `postgres`, que conserva `EXECUTE`); dentro de ellos `auth.uid()` sigue resolviendo desde el JWT de la request.
- **Las acciones referenciales no se rompen**: `ON DELETE CASCADE`/`SET NULL` desde `products`, `branches` y `auth.users` corren como dueño de la tabla. Se verifica igual en el stack local (borrar un producto con historial bajo `SET LOCAL ROLE authenticated`).

*Alternativas descartadas:* (a) sólo `DROP POLICY` — deja `TRUNCATE` y depende de que nadie re-otorgue; (b) borrar también las `qual = false` — ver arriba; (c) `REVOKE ALL` — quitaría `SELECT`, que el panel de historial y `/stock` usan.

### D3 — Tanda A: gate nuevo con matriz de evasión que distingue la capa

`supabase/tests/test_stock_ledger_solo_rpc.sql`, molde `test_accounts_privilege_columns.sql`: el `42501` lo comparten la capa de privilegio y la RLS, así que cada negativo exige **sqlstate `42501` y texto que empiece con `permission denied`**, y no el de RLS (`new row violates row-level security policy`). Bloques:

- **(a) metadata**: `has_table_privilege` falso para `anon`/`authenticated` × `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` × las dos tablas.
- **(b) policies**: la tabla de policies es exactamente {`branch_stock_member_select`, `stock_movements_account_select`, `stock_movements_no_update` (`qual = false`), `stock_movements_no_delete` (`qual = false`)}; ninguna otra policy de escritura.
- **(c) ACL**: `rpc_reverse_stock_movement` sin `EXECUTE` para `anon`/`authenticated`; un solo overload.
- **(d) matriz de evasión**, bajo `SET LOCAL ROLE authenticated` con claims de un **owner** (el rol más privilegiado: si él no puede, nadie puede) y repetida con un `viewer` y un `seller`: `INSERT` en `stock_movements` (la forja `reference_type='sale'`), `INSERT` en `branch_stock` (incluida la **ocupación cross-tenant** `(A, producto de B, sucursal de B)`), `UPDATE` de `branch_stock`, `UPDATE … RETURNING`, `INSERT … ON CONFLICT (product_id, branch_id) DO UPDATE`, `DELETE` y `TRUNCATE` de las dos, y `SELECT rpc_reverse_stock_movement(...)`. Cada intento ⇒ `42501` *permission denied*; huella de las dos tablas idéntica antes y después.
- **(e) control positivo** bajo el mismo rol: `rpc_stock_adjustment` escribe; alta y borrado de una venta y de una compra (borrado ⇒ reversa interna, incluido el piso en cero de una compra ya vendida); `rpc_transfer_stock`; borrado de un producto con historial; las policies de lectura siguen devolviendo filas propias y no ajenas.

**RED antes de GREEN**: el gate se corre contra la base en HEAD (sin la migración) y tiene que fallar en (a), (b), (c) y en la forja de (d).

### D4 — Tanda B: tres piezas internas y tres envoltorios con su firma

| Pieza | Tipo | `EXECUTE` | Responsabilidad |
|---|---|---|---|
| `_stock_assert_can_adjust(p_account_id)` | `STABLE`, INVOKER | nadie de la app | `is_account_writer` (`P0401`) + rol activo ∩ `{owner, admin, stock}` (`P0403 insufficient_role`). Calco de `_quote_assert_can_write`. |
| `_stock_apply_delta(p_account_id, p_product_id, p_delta, p_branch_id, p_allow_negative)` | INVOKER | nadie de la app | La **aritmética del saldo**: lock del producto (filtrado por cuenta), validación de sucursal (`P0404`/`P0422`), resolución de la default operativa, piso en cero trazable (`floor_on_purchase_delete`) o `P0409`, `c21_apply_branch_stock_delta`. **Nunca** escribe el movimiento principal: lo escribe quien la llama. Cuerpo = el vivo de `rpc_apply_product_stock_delta` sin el `IF p_log_movement`. |
| `_stock_manual_adjustment(p_product_id, p_branch_id, p_type, p_delta, p_target_quantity, p_target_scope, p_reason, p_notes, p_reference_id)` | INVOKER | nadie de la app | El **núcleo** de ajuste manual (D5-D8): tenencia, rol, motivo, tipo, RN-20, cálculo del delta bajo lock, `_stock_apply_delta`, inserción del único movimiento sellado. Devuelve `jsonb` con `movement_id`, `product_id`, `product_name`, `branch_id`, `quantity_before`, `quantity_after`, `quantity_delta`, `type`. |

**Envoltorios públicos** (`SECURITY DEFINER`, `CREATE OR REPLACE`, misma firma, misma forma de respuesta, ACL re-afirmada):

| RPC | Delegación | Respuesta conservada |
|---|---|---|
| `rpc_stock_adjustment(p_product_id, p_quantity_delta, p_type, p_reason, p_notes, p_reference_id, p_target_quantity)` | núcleo con `p_branch_id = NULL` (default operativa), `p_target_quantity` sólo si `p_type = 'physical_count'`, alcance `'total'` | `movement_id`, `product_id`, `product_name`, `quantity_before`, `quantity_after`, `quantity_delta`, `type` |
| `rpc_adjust_branch_stock(p_product_id, p_branch_id, p_new_quantity, p_reason)` | núcleo con tipo `adjustment`, objetivo `p_new_quantity`, alcance `'branch'` | `product_id`, `branch_id`, `old_quantity`, `new_quantity` |
| `rpc_apply_product_stock_delta(p_product_id, p_delta, p_branch_id, p_reason, p_log_movement, p_allow_negative)` | rechaza `p_log_movement IS DISTINCT FROM TRUE` o `p_allow_negative IS DISTINCT FROM FALSE` con `P0400 stock_internal_flags_not_allowed`; si no, núcleo con tipo `adjustment` y `p_delta` | `product_id`, `branch_id`, `quantity_before`, `quantity_after`, `quantity_delta`, `floored` (siempre `false`) |

`rpc_reverse_stock_movement` se reescribe (misma firma, sigue interna) para llamar a `_stock_apply_delta(v_account_id, producto, -delta, sucursal, TRUE)` en lugar de la RPC pública. **Tiene que ir en la misma migración** que el envoltorio: si no, la reversa de venta/compra choca con el `P0400` de los flags y el borrado de operaciones se rompe.

**Por qué INVOKER las tres internas:** corren con los privilegios de quien las invoca, que siempre es una función `SECURITY DEFINER` (`postgres`). Si alguien les re-otorgara `EXECUTE` por error, invocadas directamente por `authenticated` igual fallarían al escribir, porque la tanda A le quitó la escritura sobre las tablas. Es la misma propiedad que ya tienen `c21_apply_branch_stock_delta` y `_delivery_note_*`. `auth.uid()` sigue resolviendo (lee el claim de la request, no el rol).

*Alternativas descartadas:* (a) una sola función con flags (lo que es hoy `rpc_apply_product_stock_delta`) — los flags son exactamente la superficie que hay que cerrar; (b) `DROP` de las tres RPCs y una RPC pública nueva — resetea ACLs y obliga a migrar backend y frontend en el mismo paso que el endurecimiento, contra la decisión firmada de conservar la firma; (c) que el núcleo llame directo a `c21_apply_branch_stock_delta` — duplicaría la validación de sucursal y el chequeo de negativos que `_stock_apply_delta` ya tiene.

### D5 — Rol exigido en la base: `{owner, admin, stock}`, literal atado por test

El guard calca `_quote_assert_can_write` (`presupuestos-modulo`): `is_account_writer` primero (`P0401 unauthorized`, distingue `viewer`), y después `account_user_active_roles(cuenta, auth.uid()) && ARRAY['owner','admin','stock']` (`P0403 insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)`). Roles **activos** (no vencidos), sobre el pivot de `v3-rbac-multirole`.

El conjunto vive como literal en la migración y está **atado por test** en tres puntas: `CAN_STOCK` de `backend/core/rbac.py`, el espejo nuevo `CAN_STOCK` de `frontend/lib/rbac-capabilities.ts`, y el `ARRAY[...]` de `_stock_assert_can_adjust` en la migración (el test del frontend lee los dos archivos, como ya hace con `CAN_QUOTE`).

*Alternativa descartada:* sembrar el permiso en `document_status_transitions` (como los remitos). Un ajuste manual no es una transición de estado de un documento: no hay FSM que catalogar.

### D6 — Motivo: `P0400` en el núcleo + `CHECK NOT VALID` de segunda capa

- El núcleo rechaza `NULLIF(btrim(p_reason), '') IS NULL` con `P0400 stock_adjustment_reason_required` (mismo código que RN-A5 para el motivo de una transición destructiva) y persiste el motivo recortado en `stock_movements.reason`. `rpc_adjust_branch_stock` deja de guardarlo en `notes`.
- `CHECK stock_movements_manual_needs_reason (type NOT IN ('adjustment','physical_count','loss','damage','expiry') OR (reason IS NOT NULL AND btrim(reason) <> ''))` **`NOT VALID` y sin `VALIDATE`**: las **18** filas históricas sin motivo (12 `adjustment` + 6 `physical_count`) hacen fallar un `VALIDATE`. Un `NOT VALID` se aplica a toda inserción y a toda actualización futura; las filas viejas quedan como están. El `COMMENT` del constraint lo explica, y el gate asserta `convalidated = false` como estado **esperado** (validarlo después es una decisión, no un descuido).
- El único otro escritor de un tipo manual —el piso en cero de la reversa— ya escribe motivo (`floor_on_purchase_delete`). Ningún otro escritor de `public` usa esos tipos (barrido 2026-10-08).

*Alternativas descartadas:* rellenar las 18 filas con un motivo inventado y validar — reescribe el ledger append-only con un dato falso (el hecho es que no hubo motivo); acotar el `CHECK` por fecha — frágil y opaco.

### D7 — Tenencia por `products.account_id`, sin bloquear filas ajenas

El núcleo bloquea el producto con `SELECT … FROM products WHERE id = p_product_id AND account_id IN (SELECT current_account_ids()) FOR UPDATE`: si no aparece, `P0404 product_not_found` sin distinguir "no existe" de "es de otra cuenta" (precedente de `cuenta-corriente-party-guard`), y **nunca** toma el lock de un producto ajeno. La cuenta del ajuste es la del producto (no `current_account_ids() LIMIT 1`, ambiguo para un usuario de varias cuentas), y contra esa cuenta se evalúan el rol y la sucursal. Se retira el guard legacy `products.user_id = auth.uid()` de `rpc_stock_adjustment`: con un segundo miembro, el que no creó el producto no podía ajustarlo.

`rpc_adjust_branch_stock` (vía el núcleo) y `rpc_transfer_stock` dejan de buscar el producto sólo por `id`.

### D8 — Semántica del movimiento que deja el núcleo

- **Antes/después a nivel sucursal**, como todos los demás escritores (`op_stock_movement`, `rpc_transfer_stock`, la aritmética actual de `rpc_apply_product_stock_delta`). `rpc_stock_adjustment` era la excepción: grababa el **total** del producto. Para las 40 cuentas de una sola sucursal no cambia nada; para la única multi-sucursal, el historial pasa a ser coherente con el resto de los movimientos. El gate de #617 (`test_stock_adjustment_account_branch.sql`, que usa una cuenta de dos sucursales) se ajusta en el mismo PR.
- **Objetivo vs. delta.** Con `p_target_quantity`, el delta es `objetivo − saldo` del alcance pedido: `'branch'` (ajuste por sucursal) o `'total'` (el conteo físico del modal de `/stock`, que cuenta el producto entero y aplica la diferencia en la sucursal operativa por defecto — comportamiento actual, intacto). Objetivo negativo ⇒ `P0400`. Con objetivo, un delta 0 se registra igual (deja constancia del conteo); sin objetivo, `p_delta` nulo o 0 ⇒ `P0400`.
- **Negativos**: un solo chequeo, a nivel de la sucursal afectada (`P0409`, desde `_stock_apply_delta`). Reemplaza los dos de `rpc_stock_adjustment` (total `23000` + sucursal `P0409`): si la sucursal no queda negativa, el total tampoco.
- **Tipos**: `adjustment`, `physical_count`, `loss`, `damage`, `expiry`. `loss`/`damage`/`expiry` sólo restan (`P0400` si el delta es positivo). `transfer_in`/`transfer_out` dejan de ser tipos de ajuste manual (OQ-1): la transferencia tiene su propia entidad.
- **RN-20 en todos los caminos**: un padre `variant_only` (o `untracked`) se rechaza (`P0400 stock_adjustment_product_not_adjustable`). Hoy sólo lo validaba `rpc_stock_adjustment`; FastAPI no.
- **`reference_type`** queda `NULL` salvo que venga `p_reference_id` (entonces `'adjustment'`): la convención de las 1.794 filas actuales.
- **Sello**: `account_id` (del producto), `branch_id` (la afectada; si la cuenta no tenía sucursal operativa, la que `c21` crea perezosamente, re-resuelta después de aplicar — cierra el borde declarado de #617), `user_id = performed_by = auth.uid()`.

### D9 — Decisión firmada 2: la edición **deriva al modal**; el alta conserva "Stock inicial"

**Edición.** El formulario de producto deja de editar el stock: muestra "Stock actual: N" en sólo lectura y, a quien tiene `CAN_STOCK`, un botón **Ajustar stock** que abre el `StockAdjustmentModal` existente con el producto preseleccionado (su prop `product` ya existe para la acción por fila de `/stock`). El `PUT` deja de mandar `stock` (`hooks/data/use-products.ts`).

Por qué ésta y no "pedir el motivo en el formulario":

1. **Es lo que ya existe**: el modal tiene motivo, tipo (conteo, pérdida, daño…), notas y preselección. Pedir motivo en el formulario sería una segunda interfaz para lo mismo.
2. **Un solo camino para el ajuste** desde la UI de catálogo, y `PUT /products` deja de ser un camino de ajuste.
3. **Cierra un bug de construcción**: hoy la edición manda **siempre** el valor de stock del formulario, y el backend aplica `objetivo − saldo actual`. Si entre que se abre el formulario y se guarda hay una venta, guardar un cambio de **precio** re-suma en silencio las unidades vendidas como "Ajuste manual de stock". Con la derivación, la edición no manda stock. (Por construcción; se reproduce en el stack local antes de corregirlo — tarea 6.5.)

**Backend `PUT /products/{id}`**: si el cuerpo trae `stock` distinto del saldo actual ⇒ `422` RFC 7807 `stock_adjust_required` (*"El stock se ajusta desde «Ajustar stock», con un motivo."*), **antes** de escribir ningún campo; mismo valor ⇒ se ignora (compatibilidad con pestañas abiertas con el bundle anterior, que siempre mandaban `stock`). `ProductUpdate.stock` se conserva en el schema por esa misma compatibilidad; el repositorio deja de llamar a la RPC en el `update`.

**Alta.** "Stock inicial" sigue sola, sin motivo: el backend la registra con el motivo fijo "Stock inicial" (`rpc_apply_product_stock_delta(…, 'Stock inicial', TRUE, FALSE)`), que satisface el motivo obligatorio. El campo se ofrece sólo con `CAN_STOCK` (OQ-2) y nunca para un padre `variant_only` (RN-20, D8). `POST /products` con stock ≠ 0 exige `require_account_role(conn, auth, CAN_STOCK)` **antes** de contar contra el límite del plan o insertar (403, el producto no se crea). La conexión se inyecta en el service como ya hace `product_categories`.

### D10 — Cómo `rpc_apply_product_stock_delta` sigue sirviendo a su caller del backend

Firma, defaults y ACL intactos (`CREATE OR REPLACE`): el backend la sigue llamando con `$1..$6` y `(…, 'Stock inicial', TRUE, FALSE)`, combinación que el envoltorio acepta. Cualquier otra combinación de flags ⇒ `P0400`. Tras la tanda B su **único** caller es `POST /products` con stock inicial: el `PUT` ya no ajusta (D9) y `StockRepository.adjust_with_event` se retira (código muerto; sus dos tests de `backend/tests/outbox/test_producers.py::TestStockAdjustedProducer` se reemplazan por un candado estructural: ningún archivo de `backend/` llama a la RPC con un flag distinto de `TRUE, FALSE`). El evento `StockAdjusted` no tiene consumidor (sólo aparece como "fuera de alcance" en `test_journal_consumer.py`), así que retirar su único productor no deja a nadie sin datos.

### D11 — Transferencias: producto validado contra la cuenta, rol sin cambios

`rpc_transfer_stock` se reescribe desde su cuerpo vivo con un único cambio funcional: el producto se busca `WHERE id = p_product_id AND account_id = v_account_id` (`P0404`). Conserva `is_account_writer` como guard de rol (OQ-3) y `current_account_ids() LIMIT 1` para la cuenta (lateral). Una transferencia conserva el total, deja entidad, historial de estados, dos movimientos y un evento: no fabrica ni destruye stock.

### D12 — Superficie frontend (G4)

| Pantalla / componente | Cambio |
|---|---|
| `lib/rbac-capabilities.ts` | `CAN_STOCK = ["owner","admin","stock"]`, atado por test a Python y a la migración (D5) |
| `app/(dashboard)/stock/page.tsx` | "Ajustar stock", acción por fila e "Importar ajuste" con `hasCapability(roles, CAN_STOCK, rolesResolved)`; "Transferir" sin cambios |
| `components/stock/stock-adjustment-modal.tsx` | Motivo obligatorio (rótulo "Motivo *", envío deshabilitado con motivo en blanco, mensaje en línea); sin las opciones "Transferencia entrada/salida" (OQ-1); error por fila vía `humanizeOperationError` en vez del `error.message` crudo |
| `components/stock/stock-import-adjustment-dialog.tsx` + `lib/stock-import-parser.ts` | Columna "Motivo" obligatoria: encabezado ausente ⇒ error de archivo; celda vacía ⇒ error bloqueante "Falta el motivo"; los alias de transferencia ⇒ error que deriva a "Transferir stock"; plantilla y ayuda actualizadas |
| `components/branches/BranchStockTable.tsx` + `AdjustStockModal.tsx` | Ajuste visible con `CAN_STOCK` (transferencia sigue con `isWriter`); motivo `.trim().min(1)` |
| `components/forms/product-form.tsx` | Alta: "Stock inicial" sólo con `CAN_STOCK` y producto con stock propio; sin rol, una línea que dice quién lo carga. Edición: "Stock actual" sólo lectura + "Ajustar stock" (D9) |
| `hooks/data/use-products.ts` | El `PUT` no manda `stock` |
| `lib/operation-errors.ts` + `hooks/data/use-branch-stock.ts` | Tokens nuevos (`stock_adjustment_reason_required`, `stock_adjustment_type_invalid`, `stock_adjustment_product_not_adjustable`, `stock_internal_flags_not_allowed`, `stock_adjust_required`) y el texto de `insufficient_role` para el contexto "ajuste de stock" (extiende `OperationErrorContext`, no un segundo mapa); `translateBranchStockError` delega en el mapa canónico lo que no reconoce |

Diseño visual con los tokens y componentes base existentes; verificación en 375 px y desktop, tema claro y oscuro, de: `/stock` con rol `stock` y con rol `seller`, el modal con motivo vacío y con error del servidor, el importador con filas sin motivo, `/sucursales/[id]/stock`, y el formulario de producto en alta (con y sin rol) y en edición.

### D13 — Gates de la tanda B

`test_stock_ledger_solo_rpc.sql` crece con:

- **(f) matriz de rol × envoltorio**: `owner`, `admin`, `stock` ⇒ OK; `seller`, `cashier`, `purchases`, `accountant` ⇒ `P0403`; `viewer` ⇒ `P0401`; rol vencido ⇒ rechazado. Sobre los tres envoltorios, ejecutándolos de verdad.
- **(g) motivo**: nulo, vacío y sólo espacios ⇒ `P0400` en los tres; el `CHECK` rechaza una inserción directa como `postgres` de un tipo manual sin motivo (`23514`); `convalidated = false` asertado.
- **(h) flags**: `p_log_movement = false` y `p_allow_negative = true` ⇒ `P0400`, saldo intacto.
- **(i) tenencia**: producto ajeno ⇒ `P0404` en los tres envoltorios y en `rpc_transfer_stock`, sin filas nuevas; un segundo miembro `admin` ajusta un producto creado por el primero.
- **(j) sello e invariante**: cada ajuste aceptado deja exactamente un movimiento con cuenta, sucursal, autor, motivo y `after = before + delta` a nivel sucursal; visible bajo RLS para su cuenta y no para otra.
- **(k) semántica**: conteo físico total sobre una cuenta de dos sucursales; objetivo por sucursal; `loss` positivo ⇒ `P0400`; `transfer_in` ⇒ `P0400`; padre `variant_only` ⇒ `P0400`; negativo ⇒ `P0409`.
- **(l) reversa** tras la reescritura: borrar venta y compra repone; compra ya vendida ⇒ piso en cero con su ajuste trazable con motivo.
- **(m) ACL**: las tres internas sin `EXECUTE` para `anon`/`authenticated`; los tres envoltorios y `rpc_transfer_stock` con `EXECUTE` para `authenticated` y sin `anon`; un solo overload de cada uno.

Las tres internas y `rpc_reverse_stock_movement` entran a `v_internal_only_fns` de `test_function_acl_gate.sql` (la tanda A ya sumó la reversa). Los gates que usan estas RPCs como **fixture** se corren todos (`test_ventas_unidades_conversion.sql`, `test_branch_stock.sql`, `test_unidades_decisiones_8_9.sql`, `test_stock_movements_edicion.sql`, `test_remito_a_venta.sql`, `test_stock_adjustment_account_branch.sql` y los dos `.sh` de carrera): si uno rompe por rol, motivo, tipo o `variant_only`, se corrige **la fixture**, nunca el núcleo.

## Risks / Trade-offs

- **[R1] Un camino que escribía directo y no se midió** (p. ej. un script de mantenimiento corrido con un JWT de usuario) → la medición cubre código y 14 días de tráfico con control positivo; la verificación post-merge de la tanda A mira 48 h de logs de PostgREST y de Render buscando `42501`/`permission denied` sobre las dos tablas y la reversa. Rollback trivial (un `GRANT` + re-crear policies), documentado en el Migration Plan.
- **[R2] La reescritura de la reversa rompe el borrado de ventas/compras** → va en la misma migración que el envoltorio (D4), y el gate (l) + `test_stock_movements_edicion.sql` la ejecutan; humo del PO borra una venta y una compra de prueba.
- **[R3] Choque con la otra sesión en `test_remitos_venta.sql` / `test_remitos_compra.sql`** → la tanda A sólo toca su bloque (f); el apply rebasa sobre `origin/main` inmediatamente antes de editar, y si un PR de remitos está abierto con cambios en esos archivos, se coordina el orden de merge en lugar de pisarlo. Lo mismo con los números de migración (re-verificar `MAX(version)` de prod y de `origin/main`).
- **[R4] Un gate de fixture rompe por el endurecimiento** → esperado; se corrige la fixture (D13). Riesgo de "corregir" el núcleo para que el gate pase: prohibido por la tarea 9.3.
- **[R5] Las cuentas multi-sucursal ven otro antes/después en el historial de ajustes del modal** (D8) → una sola cuenta; el cambio es hacia la coherencia con el resto de los movimientos; se declara en la nota del PR.
- **[R6] Un usuario con la pestaña abierta antes del deploy** guarda la edición de un producto con un stock viejo → `422` con mensaje claro en lugar de un ajuste fantasma. Trade-off aceptado.
- **[R7] Los 5 saldos de padres `variant_only` quedan sin camino de corrección** desde la UI (RN-20 bloquea el ajuste) → residuo medido, registrado como hallazgo lateral; ya hoy el modal los rechaza.
- **[R8] `CHECK NOT VALID` confunde a un mantenedor futuro** que intente `VALIDATE` → `COMMENT` explícito y el gate asserta `convalidated = false`.

## Migration Plan

**Tanda A** (`20261073000001_stock_ledger_cierre_escritura_directa.sql`, PR propio):

1. Controles por construcción en el stack local, **antes** de escribir SQL (tareas 1.4-1.6): forja + reversa, `PATCH` de `branch_stock` con un `seller` y un valor distinto del actual (discrimina), ocupación cross-tenant de `(product_id, branch_id)`. Logs a `openspec/changes/stock-ledger-solo-rpc/evidence/`.
2. Gate RED contra HEAD → migración → `supabase db reset` completo → gate GREEN + `test_remitos_venta.sql`, `test_remitos_compra.sql`, `test_is_account_writer_pivot.sql`, `test_function_acl_gate.sql` y la batería que siembra stock.
3. Merge ⇒ `supabase db push` del pipeline. **Verificación post-merge** (sólo lectura): `MAX(version)`, `relacl` de las dos tablas, `pg_policies`, `proacl` de la reversa; 48 h de logs sin rechazos inesperados; humo del PO (un ajuste en `/stock`, borrar una venta y una compra de prueba).
4. **Rollback**: migración nueva que re-otorga `INSERT, UPDATE, DELETE, TRUNCATE` a `authenticated`, re-crea las tres policies con su definición viva (en el Anexo B) y re-otorga `EXECUTE` de la reversa. No hay datos que deshacer.

**Tanda B** (`20261074000001_stock_ledger_nucleo_ajuste_manual.sql`, PR propio, después de A en prod):

1. Re-captura y comparación de md5 de los cinco cuerpos (Anexo A); reproducción del ajuste fantasma de la edición y del `viewer` por `PUT /products` en el stack local.
2. Gate RED → migración (internas → envoltorios → reversa → transferencia → `CHECK`, en una transacción) → GREEN; backend y frontend con TDD; batería completa de gates, backend y frontend.
3. Verificación visual (D12). Merge ⇒ deploy. Post-merge: una sola definición viva de cada función, ACLs, `CHECK` presente y `NOT VALID`, 0 movimientos manuales nuevos sin motivo, humo del PO (ajuste con y sin motivo, importador, edición de producto que deriva al modal, alta con stock inicial).
4. **Rollback**: `CREATE OR REPLACE` de los cinco cuerpos del Anexo A (conservan ACL) + `DROP CONSTRAINT` del `CHECK` + `DROP FUNCTION` de las tres internas; revert del PR de backend/frontend.

**KB al archivar** (cuando ya sea cierto en prod): RN-21 (grants revocados + policies de lectura), RN-A5 (el ajuste de stock ya exige motivo), `03_actores_y_roles.md` (`stock_movements` y `branch_stock` "Solo via RPC", ajuste con `owner`/`admin`/`stock`).

## Open Questions

Las cinco decisiones del candidato están firmadas y no se reabren. Quedan tres preguntas que ninguna de ellas cubre; el design y las specs están escritos según la **recomendación** de cada una, así que si el PO no objeta no hace falta tocar nada.

- **OQ-1 — ¿Se quitan "Transferencia entrada/salida" del ajuste manual?** Hoy el modal y el CSV de `/stock` las ofrecen como ajuste: registran un `transfer_in`/`transfer_out` **sin** transferencia (sin origen ni destino, sin entidad, sin historial). Prod: **0** filas así; las 1.036 transferencias reales salen de `rpc_transfer_stock`. **Recomendado: sí** — el núcleo las rechaza y la UI deriva a "Transferir stock". Alternativa: conservarlas como ajuste con motivo (mantiene la ambigüedad en el historial de transferencias).
- **OQ-2 — ¿Quién carga el "Stock inicial" al dar de alta un producto?** Es un ajuste manual (808 de los 1.829), así que por la decisión 1 requiere `owner`/`admin`/`stock`. **Recomendado: exigir `CAN_STOCK`** — el campo no se muestra a otros roles y el backend responde 403 antes de crear nada si igual llega; el producto se crea con stock 0 y lo carga alguien con el rol. Alternativa: permitir el stock inicial a cualquier rol que pueda crear productos (abre una excepción a la decisión 1 justo en el camino por el que entra la mitad de los ajustes).
- **OQ-3 — ¿Las transferencias entre sucursales también pasan a `CAN_STOCK`?** Hoy las hace cualquier escritor (7 roles). **Recomendado: no, por ahora** — una transferencia no crea ni destruye stock, deja entidad, historial y dos movimientos, y la decisión firmada habla de ajustes manuales; el cambio es de una línea si el PO lo quiere. Alternativa: exigir `CAN_STOCK` también (más estricto, consistente con el rol de depósito).

### Hallazgos laterales (se registran, no se corrigen acá)

1. **5 saldos ≠ 0 sobre padres `variant_only`** (y 2 movimientos manuales sobre ellos): RN-20 violado por el camino de FastAPI, que no validaba el tipo de control. Tras este change no se pueden crear más; los existentes quedan.
2. **`stock_movements.user_id` → `auth.users` con `ON DELETE CASCADE`**: borrar un usuario borra sus movimientos del ledger append-only. Por construcción; candidato de integridad.
3. **El resto del CRUD de productos** (`POST`/`PUT /products`) sigue gateado por el rol de **plataforma**: un `viewer` de cuenta puede editar nombre y precio. Fuera de este alcance.
4. **`current_account_ids() LIMIT 1`** en `rpc_transfer_stock` y `rpc_reverse_stock_movement`: ambiguo para un usuario de varias cuentas (el núcleo ya no lo usa).

## Anexo A — Cuerpos vivos de partida (prod, 2026-10-08)

md5 de `pg_get_functiondef(oid)` en prod:

| Función | md5 | `proacl` |
|---|---|---|
| `rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean)` | `6d8dcab9c533aab375ea8622d1b011d5` | `postgres, authenticated, service_role` |
| `rpc_reverse_stock_movement(uuid, text, text)` | `2885cd488052620a1a6309595348d54c` | `postgres, service_role, authenticated` |
| `rpc_adjust_branch_stock(uuid, uuid, numeric, text)` | `9d8fe0a559cca11cf8d4cc38662e87ad` | `postgres, authenticated, service_role` |
| `rpc_stock_adjustment(uuid, numeric, text, text, text, uuid, numeric)` | `2eca2849e6747c775b1a97b7d56ec5b0` | `postgres, authenticated, service_role` (cuerpo del fix #617) |
| `rpc_transfer_stock(uuid, uuid, uuid, numeric)` | `3de807fb783c1efd52104ee110121b68` | `postgres, authenticated, service_role` |
| `c21_apply_branch_stock_delta(uuid, uuid, uuid, numeric)` *(no se reescribe; referencia)* | `8d98227d6d6556e3a2f3f545dae2b231` | `postgres, service_role` |

Los cuerpos de abajo son la transcripción de esa lectura; el apply los vuelve a volcar desde prod (tarea 6.2) y es ese volcado —no esta transcripción— el que se usa como punto de partida.

### A.1 `rpc_apply_product_stock_delta`

```sql
CREATE OR REPLACE FUNCTION public.rpc_apply_product_stock_delta(p_product_id uuid, p_delta numeric, p_branch_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_log_movement boolean DEFAULT true, p_allow_negative boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           uuid;
  v_account_id    uuid;
  v_product       RECORD;
  v_branch        RECORD;
  v_target_branch uuid;
  v_branch_qty    numeric(15,4);
  v_applied       numeric(15,4);
  v_before        numeric(15,4);
  v_after         numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P0400';
  END IF;

  -- Lock de la fila del producto = mutex por producto
  SELECT id, name, account_id INTO v_product
  FROM   public.products
  WHERE  id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  IF v_product.account_id IS DISTINCT FROM v_account_id THEN
    RAISE EXCEPTION 'Permission denied to product: %', p_product_id USING ERRCODE = 'P0403';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch destino resuelta (explícita o default operativa)
  v_target_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  SELECT COALESCE(quantity, 0) INTO v_branch_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = v_target_branch;
  v_branch_qty := COALESCE(v_branch_qty, 0);

  v_applied := p_delta;

  IF p_delta < 0 AND v_branch_qty + p_delta < 0 THEN
    IF p_allow_negative THEN
      -- OQ-C: floor a 0 trazable — se aplica solo lo disponible y se registra
      -- el ajuste explícito (caso típico: reversa de compra ya vendida).
      v_applied := -v_branch_qty;
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reason, notes, performed_by, branch_id
      ) VALUES (
        v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
        v_applied, v_branch_qty, 0,
        'floor_on_purchase_delete',
        format('Reversa solicitada: %s, aplicada: %s (stock ya vendido)', p_delta, v_applied),
        v_uid, v_target_branch
      );
    ELSE
      RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_branch_qty, p_delta
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  v_before := v_branch_qty;
  v_after  := v_branch_qty + v_applied;

  IF v_applied <> 0 THEN
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, v_target_branch, v_applied);
  END IF;

  IF p_log_movement AND v_applied <> 0 THEN
    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reason, performed_by, branch_id
    ) VALUES (
      v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
      v_applied, v_before, v_after,
      p_reason, v_uid, v_target_branch
    );
  END IF;

  RETURN jsonb_build_object(
    'product_id',      p_product_id,
    'branch_id',       v_target_branch,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  v_applied,
    'floored',         (v_applied <> p_delta)
  );
END;
$function$
```

### A.2 `rpc_reverse_stock_movement`

```sql
CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_movement(p_reference_id uuid, p_reference_type text, p_reason text DEFAULT NULL::text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_movement     RECORD;
  v_new_type     text;
  v_new_ref_type text;
  v_delta_result jsonb;
  v_new_row      public.stock_movements;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF p_reference_type NOT IN ('purchase', 'sale') THEN
    RAISE EXCEPTION 'rpc_reverse_stock_movement: p_reference_type debe ser purchase o sale (recibido: %)', p_reference_type
      USING ERRCODE = 'P0400';
  END IF;

  v_new_type     := CASE p_reference_type WHEN 'purchase' THEN 'purchase_return' ELSE 'sale_return' END;
  v_new_ref_type := p_reference_type || '_reversal';

  -- Scope explícito por cuenta (defensa en profundidad — la RPC es SECURITY
  -- DEFINER, no depende de RLS, pero tampoco debe tocar movimientos de otra
  -- cuenta si p_reference_id colisionara).
  FOR v_movement IN
    SELECT *
    FROM public.stock_movements
    WHERE reference_id   = p_reference_id
      AND reference_type = p_reference_type
      AND account_id     = v_account_id
      AND product_id IS NOT NULL
      AND quantity_delta IS NOT NULL
  LOOP
    -- Reutiliza rpc_apply_product_stock_delta para la aritmética de stock
    -- (lock de producto, floor-a-cero trazable si ya se vendió, validación
    -- de sucursal) — p_log_movement=FALSE porque ESTA función es la dueña
    -- del movimiento que se registra (necesita su propio type/reference_type/
    -- metadata, no el genérico 'adjustment' que loguearía el RPC de stock).
    SELECT public.rpc_apply_product_stock_delta(
      v_movement.product_id, -v_movement.quantity_delta, v_movement.branch_id,
      NULL, FALSE, TRUE
    ) INTO v_delta_result;

    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reference_id, reference_type, reason, notes, performed_by, branch_id, metadata
    ) VALUES (
      v_uid, v_account_id, v_movement.product_id, v_movement.product_name, v_new_type,
      (v_delta_result->>'quantity_delta')::numeric,
      (v_delta_result->>'quantity_before')::numeric,
      (v_delta_result->>'quantity_after')::numeric,
      p_reference_id, v_new_ref_type,
      COALESCE(p_reason, format('Reversa de %s', p_reference_type)),
      format('Contramovimiento de %s (movimiento original %s)', p_reference_type, v_movement.id),
      v_uid, v_movement.branch_id,
      jsonb_build_object('reverses_movement_id', v_movement.id)
    )
    RETURNING * INTO v_new_row;

    RETURN NEXT to_jsonb(v_new_row);
  END LOOP;

  RETURN;
END;
$function$
```

### A.3 `rpc_adjust_branch_stock`

```sql
CREATE OR REPLACE FUNCTION public.rpc_adjust_branch_stock(p_product_id uuid, p_branch_id uuid, p_new_quantity numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_old_quantity numeric(15,4);
  v_product_name text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa'
      USING ERRCODE = 'P0403';
  END IF;

  -- Only owner/admin can adjust stock
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can adjust branch stock'
      USING ERRCODE = 'P0401';
  END IF;

  -- Validate new quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RAISE EXCEPTION 'New quantity must be >= 0' USING ERRCODE = 'P0400';
  END IF;

  -- Verify branch belongs to this account and is operative (C-26)
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or unauthorized'
      USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Verify product exists
  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Get current quantity (default 0 if no row exists)
  SELECT quantity INTO v_old_quantity
  FROM   public.branch_stock
  WHERE  product_id = p_product_id
    AND  branch_id  = p_branch_id;

  v_old_quantity := COALESCE(v_old_quantity, 0);

  -- Insert adjustment stock_movement
  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, notes
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'adjustment',
    p_new_quantity - v_old_quantity, v_old_quantity, p_new_quantity,
    'adjustment', v_uid, p_branch_id, p_reason
  );

  -- UPSERT branch_stock
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_branch_id, p_new_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = p_new_quantity;

  RETURN jsonb_build_object(
    'product_id',   p_product_id,
    'branch_id',    p_branch_id,
    'old_quantity', v_old_quantity,
    'new_quantity', p_new_quantity
  );
END;
$function$
```

### A.4 `rpc_transfer_stock`

```sql
CREATE OR REPLACE FUNCTION public.rpc_transfer_stock(p_product_id uuid, p_from_branch_id uuid, p_to_branch_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_from           RECORD;
  v_to             RECORD;
  v_from_qty       numeric(15,4);
  v_to_qty         numeric(15,4);
  v_product_name   text;
  v_transfer_id    uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can transfer stock'
      USING ERRCODE = 'P0401';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
  END IF;

  IF p_from_branch_id = p_to_branch_id THEN
    RAISE EXCEPTION 'same_branch_transfer_not_allowed' USING ERRCODE = 'P0400';
  END IF;

  -- Ambas branches de la cuenta, existentes y OPERATIVAS (C-26)
  SELECT id, status INTO v_from
  FROM   public.branches
  WHERE  id = p_from_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: origin branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_from.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de origen está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT id, status INTO v_to
  FROM   public.branches
  WHERE  id = p_to_branch_id AND account_id = v_account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found: destination branch not found or not active'
      USING ERRCODE = 'P0404';
  END IF;
  IF v_to.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal de destino está cerrada' USING ERRCODE = 'P0422';
  END IF;

  SELECT name INTO v_product_name
  FROM   public.products
  WHERE  id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de las filas de ledger (origen primero, destino si existe)
  SELECT quantity INTO v_from_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_from_branch_id
  FOR UPDATE;

  SELECT quantity INTO v_to_qty
  FROM   public.branch_stock
  WHERE  product_id = p_product_id AND branch_id = p_to_branch_id
  FOR UPDATE;

  v_from_qty := COALESCE(v_from_qty, 0);
  v_to_qty   := COALESCE(v_to_qty, 0);

  IF v_from_qty < p_quantity THEN
    RAISE EXCEPTION 'insufficient_branch_stock: origin has %, requested %',
      v_from_qty, p_quantity
      USING ERRCODE = 'P0409';
  END IF;

  -- C-26 (D3): la transferencia es una entidad con identidad propia
  INSERT INTO public.stock_transfers (
    account_id, product_id, from_branch_id, to_branch_id, quantity, status, created_by
  ) VALUES (
    v_account_id, p_product_id, p_from_branch_id, p_to_branch_id, p_quantity, 'completed', v_uid
  )
  RETURNING id INTO v_transfer_id;

  -- v3-document-status-history (RN-A2): la transferencia nace completed
  PERFORM public.record_status_transition(
    v_account_id, 'stock_transfer', v_transfer_id, NULL, 'completed', v_uid, NULL);

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_out',
    -p_quantity, v_from_qty, v_from_qty - p_quantity,
    'transfer', v_uid, p_from_branch_id, v_transfer_id
  );

  INSERT INTO public.stock_movements (
    user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reference_type, performed_by, branch_id, transfer_id
  ) VALUES (
    v_uid, v_account_id, p_product_id, v_product_name, 'transfer_in',
    p_quantity, v_to_qty, v_to_qty + p_quantity,
    'transfer', v_uid, p_to_branch_id, v_transfer_id
  );

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_from_branch_id, GREATEST(0, v_from_qty - p_quantity))
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity - p_quantity;

  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
  VALUES (v_account_id, p_product_id, p_to_branch_id, p_quantity)
  ON CONFLICT (product_id, branch_id)
    DO UPDATE SET quantity = public.branch_stock.quantity + p_quantity;

  -- v3-notifications-realtime (5.4): productor de TransferDispatched al outbox.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'TransferDispatched', 'StockTransfer', v_transfer_id,
    jsonb_build_object(
      'transfer_id',            v_transfer_id,
      'source_branch_id',       p_from_branch_id,
      'destination_branch_id',  p_to_branch_id
    ),
    now()
  );

  RETURN jsonb_build_object(
    'transfer_id',          v_transfer_id,
    'from_branch_id',       p_from_branch_id,
    'to_branch_id',         p_to_branch_id,
    'product_id',           p_product_id,
    'quantity_transferred', p_quantity
  );
END;
$function$
```

### A.5 `rpc_stock_adjustment` (cuerpo del fix #617, `20261072000001`)

El cuerpo vivo es el que dejó el fix #617 (`supabase/migrations/20261072000001_stock_adjustment_account_branch.sql`, md5 de arriba): el `INSERT` ya sella `account_id`/`branch_id`. No se transcribe acá; el volcado de la tarea 6.2 es la fuente. Puntos que el envoltorio cambia: el guard `products.user_id = v_uid` (D7), los tipos `transfer_in`/`transfer_out` (D8, OQ-1), el antes/después sobre el total del producto (D8), los dos chequeos de negativo (D8), y el motivo opcional (D6).

## Anexo B — Policies vivas que la tanda A borra (para el rollback)

```sql
CREATE POLICY stock_movements_account_insert ON public.stock_movements
  FOR INSERT TO authenticated
  WITH CHECK (account_id IN (SELECT current_account_ids() AS current_account_ids));

CREATE POLICY branch_stock_writer_insert ON public.branch_stock
  FOR INSERT TO authenticated
  WITH CHECK (is_account_writer(account_id));

CREATE POLICY branch_stock_writer_update ON public.branch_stock
  FOR UPDATE TO authenticated
  USING (is_account_writer(account_id))
  WITH CHECK (is_account_writer(account_id));
```
