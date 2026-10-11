# Design — `stock-movimientos-sucursal-origen`

> Governance: **ALTA**. Modifica en masa el ledger de stock de producción (`stock_movements.branch_id`) y reescribe `rpc_reverse_stock_movement`, la función que repone o descuenta stock en todo borrado de venta y de compra. Ninguna línea de SQL se escribe antes del checkpoint 0 (cuerpo vivo de producción y clasificación de sólo lectura) y del OK textual del PO sobre OQ-A, OQ-B y OQ-D. La migración de datos la mergea el PO.

## Context

### Lo que dejó `ventas-sucursal-por-defecto`

- La migración de datos `20261075000002` (L284-307) completó `stock_movements.branch_id` sólo en los movimientos `'sale'` nulos de las ventas que **ella misma asignó**, y sólo si la sucursal **asignada a la venta** ya existía y era la única de la cuenta cuando se escribió el movimiento (OQ-5 (c), firmada el 2026-10-09). El gate (`supabase/tests/test_ventas_sucursal_por_defecto.sql`, parte B, caso `mP_late`) fija que un movimiento con otra sucursal existente queda nulo.
- La spec `inventory-single-ledger` tiene el requirement «Única excepción auditada al carácter append-only: la sucursal nula de los movimientos de venta de origen demostrable» (L342-382). RN-21 (`knowledge-base/05_reglas_de_negocio.md`, L120-128) lo resume y dice: **«No se reabre: toda corrección futura sigue siendo un movimiento nuevo»**. Este change la reabre a pedido del PO, y por eso la extiende en lugar de crear otra (D8).
- La regla anterior tenía un defecto de planteo: ataba el origen del movimiento a la sucursal asignada a la **venta**, que en general es la principal **de hoy**. El stock salió de la principal **del día de la venta**. En la cuenta del incidente del 22-08 las dos difieren para casi todas sus ventas viejas, y por eso quedaron sin completar movimientos cuyo origen sí se puede reconstruir.

### Medición en producción (2026-10-10, sólo lectura, la hizo el orquestador; no se repite acá)

516 movimientos `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL`:

| Grupo | Movimientos | Cuentas | Fechas | Sucursales existentes al registrarse | Origen |
|---|---|---|---|---|---|
| Caso 1 | 47 | 5 de una sola sucursal | 2026-03-07 → 05-27 | Ninguna | Su única sucursal (operativa, igual a la de la venta) |
| Caso 2 | 207 | 1 (B, incidente) | 2026-06-09 → 08-21 | Una: la original, hoy desactivada | La original |
| Caso 3 | 63 | 2 | 2026-03-25 → 06-06 | Ninguna | La más antigua: 9 operativa (igual a la de la venta), 54 la original de B |
| Caso 4 | 126 | 2 (A y B) | 2026-07-22 → 10-01 | Dos o más | La principal operativa de ese momento: A (11) Casa Central; B (115) la original antes de su baja del 22-08, la nueva después |
| Sin venta viva | 73 | — | — | — | Ventas borradas o editadas y huérfanos históricos |

Cuenta A: 2 sucursales, ambas activas desde el 2026-06-22. Cuenta B: 3 sucursales, 1 activa; el 22-08 la usuaria creó «Showroom» y «Casa» y desactivó «Principal» desde la papelera con 518 productos adentro; el 24-08 se transfirió a mano todo el stock a Showroom (`CHANGES.md` L1135).

### Cómo resolvió el sistema, en cada época, la sucursal de una venta sin sucursal (verificado en los archivos)

- **Antes de C-21**: la venta descontaba `products.stock`, que era de la cuenta y no de una sucursal.
- **C-21** (`20260620000001`, L79-84 y L106-159): creó «Casa Central» en las cuentas sin sucursal y **materializó `products.stock` en la sucursal de menor `created_at`** de cada cuenta, sin filtrar por actividad y **sin escribir ningún movimiento**.
- **C-21 hotfix** (`20260622000001`, L74-82): `c21_apply_branch_stock_delta` sin sucursal descuenta de la más antigua de la cuenta (sin filtro) o crea «Casa Central» en la misma transacción.
- **C-26** (`20260625000001`, L135): `c26_default_branch` = la más antigua con `is_active AND status = 'active'`, y si no hay ninguna, la más antigua a secas. Desde ahí la usan el alta, la edición y la reversa de un movimiento sin sucursal. C-26 agregó `status` y completó `opened_at = created_at` (L67).

Conclusión: para cualquier instante T, la sucursal de la que salió el stock de una venta sin sucursal se puede expresar con una sola regla que vale en todas las épocas (D2).

### El ciclo de vida de las sucursales: qué quedó registrado

- **Bajas** (`is_active = false`): `rpc_deactivate_branch` escribe `deactivated_at`/`deactivated_by` desde `20261014000001` (`sucursal-guard-vaciado-auditoria`, mergeado el 2026-08-25 13:59 -03, `043017a`; verificado en producción el mismo día, `CHANGES.md` L1140). Las bajas anteriores, como la de «Principal» del 22-08, no tienen fecha.
- **Todo cambio de una sucursal queda en `audit_logs`** desde esa misma migración: `trg_audit_branch_lifecycle` (`20261014000001` L502-576, `AFTER INSERT OR UPDATE`) registra `branch.created`, `branch.deactivated`, `branch.reactivated`, `branch.closed`, `branch.opened` y `branch.updated`, con `is_active_before/after` y `status_before/after` en `metadata` y `created_at = now()`.
- **Reactivación**: no hay RPC, pero desde el 2026-08-25 `PATCH /branches/{id}` acepta `is_active` (`backend/schemas/branches.py` L14-25, `BranchRepository.update` genérico); queda registrada por el disparador. Antes de esa fecha no existía ningún camino de la aplicación para reactivar; sólo un `UPDATE` directo por PostgREST que ninguna pantalla hacía.
- **Cierre/apertura**: `rpc_close_branch` escribe `closed_at`; `rpc_open_branch` pone `status = 'active'` y `opened_at = now()` y **no limpia `closed_at`**. Sólo queda el último ciclo.

### La reversa de stock

- `rpc_reverse_stock_movement` (cuerpo vivo de `20261074000001` L575; `md5(replace(prosrc, E'\r', ''))` local `3af74d58ee4bc40691d066d8d4860d7a`; `EXECUTE` sólo para `postgres` y `service_role`):
  - busca los movimientos con `account_id = cuenta actual` (un movimiento con `account_id` nulo **nunca** se revierte);
  - aplica `_stock_apply_delta(cuenta, producto, -delta, v_movement.branch_id, TRUE)`;
  - escribe el contramovimiento con `branch_id = v_movement.branch_id` (un nulo queda nulo, aunque el stock haya entrado en la principal) y `metadata = {reverses_movement_id}`.
- `_stock_apply_delta` (`20261074000001` L161): con sucursal explícita, la busca por `id` y cuenta y sólo rechaza `status = 'closed'` (`P0422 branch_closed`); **no mira `is_active`**: el stock entra en una sucursal desactivada sin error. Sin sucursal, resuelve `c26_default_branch`. Devuelve la sucursal efectivamente usada (`branch_id`).
- La invocan `rpc_delete_sale_operation` (toma las filas de `sales` con `FOR UPDATE` en orden ascendente de `id` antes de compensar) y `rpc_delete_purchase_operation`.
- La **edición** no usa la sucursal del movimiento: `rpc_atomic_update_sale_operation` devuelve el stock a `v_old_sale.branch_id` vía `op_stock_movement` (que resuelve `COALESCE(p_branch_id, c26_default_branch)`) y del movimiento sólo lee `quantity_delta` y `unit_cost_snapshot`.
- Hoy, borrar una venta con movimiento nulo repone en la principal vigente. Si el movimiento pasa a decir «la original desactivada», borrarla repondría **ahí**, en una sucursal que no se ve: la clase del incidente del 22-08. El bloque (9b) de `test_ventas_sucursal_por_defecto.sql` (L792-819) fija a propósito ese comportamiento para venta nueva (OQ-8 (a) de `ventas-sucursal-por-defecto`) y pide que el arreglo lo cambie a conciencia.

### Quién lee `stock_movements.branch_id`

- **Frontend**: el único lector es `components/stock/stock-movements-panel.tsx` (consulta en L332), que **no muestra ni filtra** la sucursal. El diálogo de borrado (`lib/delete-compensation.ts`) no nombra la sucursal a la que vuelve el stock.
- **Backend**: `StockRepository.list_movements` devuelve `sm.*`; ninguna lógica usa la columna.
- **SQL** (`pg_proc` local): `rpc_reverse_stock_movement` (la sucursal), `rpc_atomic_update_*_operation` (cantidad y costo), `fn_product_base_unit_guard` (existencia). Ninguna vista.
- Por lo tanto, el único efecto funcional de completar la columna es **dónde repone el borrado**.

### La tabla

`stock_movements` no tiene disparadores; las policies `stock_movements_no_update`/`no_delete` (`qual = false`) cierran la escritura a los roles de la aplicación (la migración corre como dueño); la FK `branch_id → branches` es `ON DELETE SET NULL` y las sucursales no se borran; `stock_movements_manual_needs_reason` sólo alcanza a los tipos manuales. Índices sobre `(account_id, branch_id)` y `reference_id`.

### CI

`KPI_Validation.yml` (L1291-1340) termina la cadena de reaplicación con `20261075000001`/`000002`. Ninguna migración reaplicada en la cadena redefine `rpc_reverse_stock_movement` ni `_stock_apply_delta` (verificado sobre los archivos de la cadena).

## Goals / Non-Goals

**Goals:**

1. Todo movimiento de stock de venta sin sucursal, de una venta viva, cuyo origen se pueda reconstruir sin suponer nada que el sistema no haya registrado, queda con la sucursal de la que salió el stock. Una sola regla para todas las épocas (D2), con «ante la duda, nulo».
2. Ningún borrado de venta o compra vuelve a poner stock en una sucursal desactivada (D6), incluidos los movimientos que este change completa con la sucursal original de la cuenta del incidente.
3. La excepción a RN-21 se extiende con los mismos límites (sólo `branch_id`, auditada por id, reversible) y queda **cerrada**: lo que no se complete acá queda nulo para siempre (D8).
4. Cero efectos laterales: no se tocan `branch_stock`, `sales`, caja, banco, cuentas corrientes, asientos, eventos ni notificaciones.

**Non-Goals:**

- Cambiar la sucursal de ninguna **venta** (la decidió `ventas-sucursal-por-defecto`, OQ-4 (a)). La discrepancia venta ≠ movimiento se cuenta.
- Los movimientos de **compras** sin sucursal: las compras históricas conservan su sucursal vacía («una atribución inventada sería peor que la ausencia», spec `purchase-operation`).
- Los **73 movimientos sin venta viva** (OQ-C).
- Registrar como movimiento la materialización de C-21: el ledger por sucursal no se reconstruye desde cero para el período legacy, y este change no lo pretende (D1).
- «Facturar venta manual» sobre una venta cuya sucursal no opera (la otra mitad de OQ-8).
- La reversa de un movimiento sin sucursal: sigue cayendo en la principal vigente y su contramovimiento sigue nulo, como hoy.
- Movimientos con `account_id` nulo, que la reversa no encuentra: se miden en el checkpoint y, si existen, quedan como candidato propio.
- Backend y frontend.

## Decisions

### D1 — El origen es la sucursal de la que salió el stock cuando se registró el movimiento, no la sucursal asignada a la venta

El movimiento `'sale'` registra una salida de stock. Su sucursal tiene que ser la que el servidor resolvió **en esa transacción**: la principal de ese momento. La venta, en cambio, quedó en la principal de hoy por una decisión de atribución (OQ-4 de `ventas-sucursal-por-defecto`). Son dos hechos distintos y pueden diferir.

- En la cuenta B, completar los 207 movimientos del caso 2 con la principal de hoy registraría salidas de stock de una sucursal creada dos meses después.
- Completarlos con la original deja venta y movimiento en sucursales distintas (se cuenta como `discrepancia_venta`), pero el historial dice la verdad: el stock salió de la original y el 24-08 se transfirió a la nueva.

Lo que **no** se promete: que el ledger por `(producto, sucursal)` se reconstruya desde cero. C-21 materializó el stock legacy sin movimiento y las compras viejas siguen sin sucursal. El valor es que cada movimiento diga de dónde salió el stock, para lo que se construya encima (historial por sucursal, valuación por sucursal), y que el borrado reponga en un lugar explícito y explicable (D6).

- *Alternativa — la sucursal asignada a la venta* (la regla de `ventas-sucursal-por-defecto`, sin la condición de origen demostrable). **Rechazada**: es la opción (a) de OQ-5 que el PO ya rechazó, por falsear el ledger.
- *Alternativa — completar con la principal de hoy*. **Rechazada** por lo mismo, y porque en la cuenta B produciría saldos intermedios negativos al reconstruir la historia de la sucursal nueva.

### D2 — Una sola regla de reconstrucción, tres casos y «ante la duda, nulo»

Para cada movimiento M (venta viva V, cuenta C, instante T = `M.created_at`), sea S(T) el conjunto de sucursales de C con `created_at <= T`:

| Regla | Condición | Origen | Por qué es el origen |
|---|---|---|---|
| `pre_sucursal` | S(T) vacío | La sucursal **más antigua** de C (sin filtro de actividad) | El stock vivía en `products.stock`, y C-21 lo materializó en la sucursal de menor `created_at` (`20260620000001` L106-159). Es la misma convención que el sistema ya aplicó a todo el stock legacy. |
| `unica` | S(T) tiene una sola | Esa sucursal, opere o no hoy | Con una sola sucursal, `c26_default_branch` la devuelve en cualquiera de las dos ramas de su `COALESCE`, y antes de C-26 era «la más antigua». No pudo salir de otra. |
| `reconstruida` | S(T) tiene dos o más | La que `c26_default_branch` habría devuelto en T: la primera de S(T) por `created_at` que **operaba** en T; si ninguna operaba, la más antigua de S(T) | Es la definición literal de la función, evaluada sobre el estado de T (D3). Antes de C-26 la regla era «la más antigua» sin filtro; coincide cuando la más antigua operaba, y si no se sabe, D3 devuelve «desconocido». |

`reconstruida` sólo escribe si el estado en T es **conocido** (D3) para todas las sucursales que la regla recorre hasta elegir (las anteriores tienen que constar como no operativas, y la elegida como operativa). Si alguna es desconocida, el movimiento queda nulo (`no_fechable`). Un movimiento con `created_at` nulo también queda nulo.

Mapeo con la medición: casos 1 y 3 → `pre_sucursal` (110); caso 2 → `unica` (207); caso 4 → `reconstruida` (hasta 126).

- *Alternativa — tres migraciones o tres reglas con fechas fijas por cuenta*. **Rechazada**: la regla es general, corre igual en CI, en el stack local y en producción, y no lleva ningún id ni fecha de cuentas reales.
- *Alternativa — separar la época anterior a C-26 con una fecha de corte*. **Rechazada por innecesaria**: D3 hace que la regla de C-26 y la de antes coincidan o den «desconocido», nunca un valor distinto.

### D3 — El estado de una sucursal en un instante: lo registrado, y antes de eso sólo lo que no pudo cambiar sin dejar rastro

`operativa(b, T)` vale **sí**, **no** o **desconocido** (`is_active AND status = 'active'`, como `c26_default_branch`). Se usa una constante del sistema, **X = `2026-08-26 00:00:00-03`**: desde X todo cambio de una sucursal está en `audit_logs`. Es el fin del día en que se desplegó `20261014000001`; uno más temprano que el despliegue real haría insegura la regla, así que el checkpoint 0.2 lo confirma contra la corrida de despliegue de `043017a` y contra producción.

- **Rebobinado**: se parte del estado actual de b y se deshacen, del más nuevo al más viejo, los eventos de ciclo de vida de b registrados **después de T** (tomando su `is_active_before` y `status_before`). Si dos eventos de b comparten instante y dejan estados distintos, el estado es desconocido.
- **T ≥ X**: el rebobinado es exacto, porque desde X todo cambio quedó registrado.
- **T < X**: el rebobinado sólo es exacto si nada cambió sin registrarse entre T y X, así que a su resultado se le aplica una inferencia conservadora, que sólo afirma lo que no pudo cambiar sin dejar rastro:
  - **activa** → activa en T: antes de que se registraran los cambios no había ningún camino de la aplicación para reactivar una sucursal (Context), y una reactivación posterior ya la deshizo el rebobinado;
  - **inactiva** → **desconocido**: la baja pudo ocurrir antes de que se registrara su fecha;
  - **abierta** y `closed_at IS NULL` → abierta en T (`rpc_close_branch` siempre escribe `closed_at` y nada lo limpia: nunca se cerró);
  - cualquier otro caso → desconocido.

  Por eso un X más tardío que el real sólo agranda la franja donde se aplica la inferencia (más nulos, nunca un valor distinto).

Con la medición: en A las dos sucursales operan desde siempre, así que sus 11 movimientos son conocidos. En B, «Principal» está inactiva sin fecha: para T ≥ X consta como no operativa y la principal de T sale de Showroom y Casa; para T entre la creación de Showroom (22-08) y X es desconocido y esos movimientos quedan nulos. El checkpoint 0.3 da el número exacto.

- *Alternativa — usar sólo `deactivated_at`*. **Rechazada**: no cubre cierres, reaperturas ni reactivaciones, que sí están en `audit_logs`.
- *Alternativa — fechar la baja de «Principal» con evidencia indirecta* (las transferencias del 24-08, el primer error de stock). **Rechazada**: sería una fecha específica de una cuenta escrita en una migración general, inferida y no registrada. Lo que no se puede fechar queda nulo (OQ-B).
- *Alternativa — suponer que una sucursal inactiva en X ya lo estaba desde siempre*. **Rechazada**: es justo el caso de B entre el 22-08 y X, y daría una sucursal equivocada.

### D4 — Veto por caja y banco de la misma operación

Para la operación de V (`COALESCE(operation_id, id)`, y la orden de venta que la referencia, si la hay: son las mismas claves que usa `rpc_delete_sale_operation` para compensar) se miran los movimientos de caja de tipo `sale` (`cash_movements.reference_id`, sucursal de la caja de su sesión) y los bancarios (`bank_movements.source_doc_type = 'sale'`, `source_doc_ref`, `branch_id`). Por construcción registran la sucursal que el alta resolvió (el opt-in de caja exige la sesión de esa sucursal; el banco se escribe con `v_gate_branch`). Si alguno registra una sucursal **distinta** del origen calculado, el movimiento no se toca y se cuenta (`contradiccion`).

La evidencia sólo **veta**, nunca decide: así un supuesto equivocado sobre su historia sólo puede producir nulos, nunca un valor falso.

### D5 — Alcance y exclusiones

- Movimientos con `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL` y `reference_id` = una fila **viva** de `sales` con `account_id` no nulo; `stock_movements.account_id` nulo o igual al de la venta. Sólo se escribe `branch_id`, y sólo con una sucursal de la cuenta de la venta.
- No se tocan: los movimientos con sucursal, los de otros tipos (`sale_return`, `purchase`, transferencias, ajustes), los **73** sin venta viva (OQ-C), los de ventas sin cuenta (se cuentan como `sin_cuenta`) y los de cuentas sin sucursales (`sin_sucursal`).
- Movimientos con `account_id` nulo: se completan si cumplen el resto, pero la reversa de hoy no los encuentra. El checkpoint los cuenta; si hay, es un defecto preexistente y queda como candidato (completar `account_id` sería otra columna y otra excepción).

### D6 — La reversa no repone en una sucursal desactivada (OQ-D)

En `rpc_reverse_stock_movement`, antes de aplicar el delta:

- si el movimiento original tiene sucursal y esa sucursal está **desactivada** (`is_active = false`), la reversa se aplica con sucursal nula, o sea en `c26_default_branch` (la principal operativa vigente), y el contramovimiento registra **la sucursal efectivamente usada** (la que devuelve `_stock_apply_delta`) y suma a `metadata` `fallback_from_branch_id` (la original) y `fallback_reason = 'branch_inactive'`;
- en cualquier otro caso, sin cambios: sucursal operativa → ahí; **cerrada** → `P0422 branch_closed` (una sucursal cerrada se reabre; es el contrato de C-26 y de `ventas-sucursal-por-defecto`, candidato (i) de #606); sin sucursal → principal vigente y contramovimiento nulo.

Alcanza a ventas y a compras (es la misma función). Para una compra, quitar el stock de la principal es más fiel que hoy: la sucursal desactivada se vació antes de su baja (guard de `sucursal-guard-vaciado-auditoria`), así que hoy el descuento cae en un saldo cero y termina en un ajuste `floor_on_purchase_delete` que no quita nada de ningún lado.

Por qué en este change: completar 261 movimientos (como mínimo) con la sucursal original desactivada de B haría que borrar esas ventas, que hoy repone en la principal, repusiera en una sucursal invisible. Con el fallback, borrar y editar esas ventas devuelven el stock al mismo lugar (la principal de hoy, que es también la sucursal de la venta). Y resuelve la mitad «reversa» de OQ-8 para toda venta y compra.

Reglas de la reescritura (molde de `20261075000001`):

- se parte del `pg_get_functiondef` vivo de producción (checkpoint 0.1);
- preflight `DO` con `md5(replace(prosrc, E'\r', ''))`: `v_expected` (partida, local `3af74d58…`, confirmado en producción) y `v_rewritten` (medido en el stack local); si el vivo no es ninguno de los dos, `RAISE EXCEPTION` sin tocar nada; si ya es el reescrito, `NOTICE 'stock-movimientos-sucursal-origen: … ya es el cuerpo de esta migración (reaplicación)'`;
- `CREATE OR REPLACE` con la misma firma (sin `DROP`, sin overload);
- `COMMENT` vivo completo más una frase sobre el fallback;
- `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` re-emitido (ACL viva: sólo `postgres` y `service_role`);
- el diff contra el cuerpo vivo se limita a la resolución de la sucursal, el `branch_id` y la `metadata` del contramovimiento, y un comentario de cabecera.

- *Alternativa — rechazar el borrado* (OQ-8 (c) de ventas). **Rechazada**: no hay camino de la interfaz para reactivar una sucursal, y esas ventas quedarían imposibles de borrar.
- *Alternativa — el fallback también para sucursales cerradas*. **Rechazada**: cambia un contrato vigente y reversible (se reabre la sucursal) sin que este change lo necesite.
- *Alternativa — ponerlo en `_stock_apply_delta`*. **Rechazada**: ese helper también lo usa el núcleo de ajuste manual, que tiene su propia validación de sucursal; el cambio de contrato es de la reversa.
- *Alternativa — completar sólo los movimientos cuyo origen opera hoy* (OQ-D (b)). Posible, pero deja sin sucursal justo la cuenta que motiva el pedido.

### D7 — Mecánica de la migración de datos

- **Archivo propio, sólo datos**: `20261077000002_stock_movimientos_sucursal_origen.sql`, sin DDL, funciones ni ACLs; corre después de `20261077000001` (la reversa ya protegida). El PO la mergea.
- **Locks**: las filas de `sales` referenciadas se toman con `FOR UPDATE` en orden ascendente de `id` (regla dura del proyecto; la misma que el borrado y la edición) antes de escribir `stock_movements`. Así, un borrado concurrente o espera al backfill (y después ve el movimiento completado, con el fallback de D6) o lo gana y la venta ya no está viva (el backfill no toca su movimiento). Sin `LOCK TABLE`.
- **Por `JOIN` sobre tablas temporales con clave** (lección de `ventas-sucursal-por-defecto`: subconsultas correlacionadas por fila tardaron 6 min contra 24 s): candidatos; sucursales de las cuentas involucradas; estado de cada sucursal en X y eventos posteriores; evidencia de caja y banco; resultado por movimiento.
- **Auditoría**: una fila de `audit_logs` por cuenta con al menos un movimiento completado: `action = 'stock_movements_branch_backfill'`, `entity_type = 'account'`, `entity_id = account_id`, `user_id = NULL`, `metadata = {change, movement_ids[], movement_ids_por_regla{pre_sucursal[], unica[], reconstruida[]}, no_fechable, contradiccion, discrepancia_venta, destino_desactivado, destino_cerrado, branch_ids[]}`.
- **`NOTICE`** (nunca aborta por datos): movimientos completados y cuentas; por regla; nulos que quedan por motivo (`no_fechable`, `contradiccion`, `sin_cuenta`, `sin_sucursal`); `discrepancia_venta`; destinos hoy desactivados y cerrados; movimientos `'sale'` nulos **sin venta viva** (no se tocan; en producción, 73).
- **Idempotencia**: `WHERE branch_id IS NULL`; una segunda corrida sólo encuentra los que quedaron nulos por diseño y no escribe nada; con cero escritos no hay fila de auditoría. El gate la corre dos veces y la cadena de CI exige `0 movimientos completados` sobre la base reconvergida.
- **Sin efectos laterales**: `stock_movements` no tiene disparadores; no se escribe `branch_stock` ni ninguna otra tabla salvo `audit_logs`.
- **Reversión exacta** (sólo con decisión del PO):

  ```sql
  UPDATE public.stock_movements SET branch_id = NULL
  WHERE id IN (SELECT jsonb_array_elements_text(metadata->'movement_ids')::uuid
               FROM public.audit_logs WHERE action = 'stock_movements_branch_backfill');
  ```

### D8 — Se extiende la excepción a RN-21, no se crea otra, y queda cerrada

Mismo dato (`branch_id` nulo), misma clase de movimientos (`'sale'` de ventas vivas), misma forma (sólo esa columna, auditada por id, reversible). Lo que cambia es **cómo se demuestra el origen**: la regla de `ventas-sucursal-por-defecto` (D6 de aquel change) era un caso particular de `unica`/`pre_sucursal` con la sucursal de la venta. El requirement se reescribe para cubrir las dos migraciones y declarar el cierre: después de este change no hay una tercera; los nulos que quedan (no fechables, contradicciones, sin venta viva) quedan así, y toda corrección futura es un movimiento nuevo. RN-21 en la base de conocimiento se actualiza en el mismo PR.

### D9 — Gates, mutaciones y CI

Gate nuevo `supabase/tests/test_stock_movimientos_sucursal_origen.sql` (patrón del proyecto: fallos acumulados en `text[]`, anchors sintéticos vía `handle_new_user`, `created_at` explícitos y asertados, limpieza completa, todo en una transacción):

- **Parte A (reversa)**:
  - (0) introspección: `md5` vivo = `v_rewritten`, una sola firma, `SECURITY DEFINER`, `COMMENT`, sin `EXECUTE` para `anon`/`authenticated`/`PUBLIC`;
  - venta con movimiento en sucursal desactivada → borrar repone en la principal operativa, el contramovimiento registra la principal y `metadata` trae `reverses_movement_id`, `fallback_from_branch_id` y `fallback_reason`; la desactivada queda en 0;
  - lo mismo para una compra (descuenta de la principal, con piso trazable si no alcanza);
  - sucursal **cerrada** → `P0422 branch_closed`, sin cambios en saldo ni ledger;
  - sucursal operativa y movimiento nulo → sin cambios respecto de hoy.
- **Parte B (datos, `\i` dos veces)**, con historia de sucursales armada a mano (sucursales con `created_at` explícitos; eventos de `audit_logs` insertados con `created_at` explícitos; bajas anteriores a X hechas sin disparador, con `session_replication_role = replica`, para simular las que no dejaron rastro):
  - `pre_sucursal` con la más antigua desactivada → la más antigua;
  - `unica` con la única desactivada → esa;
  - `reconstruida` T ≥ X con la más antigua dada de baja **después** de T (evento en `audit_logs`) → la más antigua;
  - `reconstruida` T ≥ X con la más antigua dada de baja antes de T → la siguiente operativa;
  - una reactivación registrada después de T se deshace al rebobinar (en T no operaba);
  - `reconstruida` T < X con la más antigua inactiva en X → nulo (`no_fechable`);
  - `reconstruida` T < X con todas activas en X y nunca cerradas → la más antigua;
  - `reconstruida` con una cerrada (`closed_at` no nulo) antes de la elegida y T < X → nulo;
  - veto por caja y por banco → nulo (`contradiccion`);
  - movimiento sin venta viva, con sucursal, de otro tipo, de venta sin cuenta, de cuenta sin sucursales → intactos;
  - ninguna otra columna cambia (hash de las demás columnas de los movimientos del fixture);
  - auditoría por cuenta con ids y contadores; segunda corrida sin cambios y sin auditoría; `branch_stock`, `sales`, caja, banco, eventos y notificaciones de las cuentas del fixture sin cambios;
  - `rpc_delete_sale_operation` **ejecutada** sobre una venta cuyo movimiento quedó en una sucursal desactivada → repone en la principal (D6 y D7 juntas).
- **Mutaciones** (en el stack local, dentro de una transacción con `ROLLBACK`, cada una con su mensaje propio en el gate): reversa sin fallback; fallback también para cerradas; contramovimiento con la sucursal original; `pre_sucursal` con la más antigua **operativa**; `unica` salteando la no operativa; `reconstruida` tratando la inactiva-en-X como inactiva desde siempre; `reconstruida` con el estado actual en vez del rebobinado de `audit_logs`; `reconstruida` con T < X sin la inferencia conservadora; sin veto; tocando movimientos sin venta viva; escribiendo otra columna; con la sucursal de la venta en vez del origen (la regla vieja).
- **Gate existente que cambia a propósito**: el bloque (9b) de `test_ventas_sucursal_por_defecto.sql` pasa de «el stock vuelve a la sucursal desactivada (caracterización de OQ-8 (a))» a «vuelve a la principal operativa y el contramovimiento la registra».
- **Gates que se corren sin cambios**: `test_stock_ledger_solo_rpc` (el bloque (l1) usa una sucursal activa), `test_stock_movements_edicion`, `test_remito_a_venta`, `test_delete_guard_ledgers`, `test_function_acl_gate` y la parte B de `test_ventas_sucursal_por_defecto` (su (9c) usa un movimiento nulo).
- **CI**: paso propio para el gate nuevo y reaplicación de `20261077000001` (dos pasadas: la segunda exige el `NOTICE` de reaplicación y el `schema_snapshot` idéntico) y de `20261077000002` (exige `0 movimientos completados`) al final de la cadena, después de `20261075000002`.

### D10 — Sin superficie frontend; backend sin cambios

Declarado: ninguna pantalla muestra ni filtra la sucursal de un movimiento de stock, y el diálogo de borrado no nombra la sucursal (Context). El cambio de la reversa no altera ninguna respuesta de la API (el borrado sigue devolviendo lo mismo). El resultado se le informa al PO con los `NOTICE`, la auditoría y la verificación posterior.

### Numeración

La última migración en `main` es `20261075000002`. `remitos-venta` y `remitos-compra` sólo usan `20261070000001`/`20261071000001`. El hermano `compras-gastos-sucursal-por-defecto` está en propose en paralelo y todavía no reservó número: se le deja `20261076…`. Este change reserva **`20261077000001`** (función) y **`20261077000002`** (datos). Si el PO elige OQ-D (b) o (c), sólo existe la de datos y conserva `20261077000002`.

## Risks / Trade-offs

- **[Supuesto de D3: nadie reactivó una sucursal antes de X]** Si una sucursal inactiva se reactivó por un `UPDATE` directo antes de X, se la trataría como activa en un instante en que no lo estaba. → No había pantalla ni RPC que lo hiciera; el veto de D4 atrapa la contradicción cuando la venta tuvo caja o banco; el checkpoint 0.3 revisa las cuentas con más de una sucursal (hoy dos).
- **[X mal fijado]** Un X anterior al despliegue real dejaría sin registrar cambios que la regla da por registrados. → X es el fin del día del despliegue, y el checkpoint 0.2 lo confirma contra la corrida de despliegue y contra producción.
- **[La convención de C-21 no es una salida física]** En `pre_sucursal` el stock no salió de ninguna sucursal: salió de `products.stock`, y C-21 lo atribuyó después a la más antigua. → Es la convención que el sistema ya aplicó a todo el stock legacy, se declara así en la spec y en OQ-A, y se cuenta aparte (`movement_ids_por_regla`) por si el PO quiere revertir sólo esa parte.
- **[Discrepancia venta ≠ movimiento]** En B quedan la venta en la principal de hoy y el movimiento en la original (unos 261). → Se cuenta. Con D6, borrar y editar esas ventas devuelven el stock al mismo lugar.
- **[Destino cerrado]** Si un origen está hoy **cerrado** (no desactivado), borrar esa venta pasa a pedir reabrir la sucursal, cuando hoy repone en la principal. → Es el contrato vigente de toda venta con sucursal cerrada; la medición no muestra ninguno, y la migración los cuenta (`destino_cerrado`).
- **[Cambio de comportamiento de la reversa para ventas y compras]** Borrar una operación con movimiento en una sucursal desactivada deja de reponer o descontar ahí. → Es el objetivo (D6); el checkpoint 0.4 mide cuántos movimientos vivos están hoy en sucursales desactivadas.
- **[Borrado concurrente durante la migración]** → Locks de D7.
- **[Movimientos con `account_id` nulo]** La reversa no los encuentra, con o sin sucursal. → Preexistente, medido en el checkpoint, candidato si existe.
- **[Se reabre una regla que decía «no se reabre»]** → El PO lo pidió; el requirement y RN-21 lo dejan escrito y lo cierran de nuevo, esta vez sin otra salida que un movimiento nuevo.

## Migration Plan

1. **Checkpoint 0** (sólo lectura, lo ejecuta o autoriza el PO):
   - 0.1 `pg_get_functiondef`, `md5(replace(prosrc, E'\r', ''))`, `COMMENT` y ACL vivos de `rpc_reverse_stock_movement` y `_stock_apply_delta`; `MAX(version)`; que `20261077000001`/`000002` estén libres.
   - 0.2 X: la corrida de despliegue de `043017a` terminó antes de X; ninguna sucursal tiene `deactivated_at` anterior a X; hay eventos `branch.%` en `audit_logs`; cuántos `branch.reactivated` hubo.
   - 0.3 Clasificación de los 516 con la regla de D2-D4 escrita como `SELECT`: por regla y por cuenta, nulos por motivo, discrepancias, destinos desactivados y cerrados, `account_id` nulo; y los 73 desglosados (cerrados por `*_reversal`, por `*_update`, huérfanos).
   - 0.4 Movimientos vivos de venta y de compra con sucursal hoy desactivada o cerrada (los que alcanza D6).
2. **Sign-off del PO** sobre OQ-A, OQ-B y OQ-D, con los números del checkpoint, registrado textual en este design.
3. **Apply**: gate en rojo, migraciones, gate en verde, mutaciones, CI. La migración de datos la mergea el PO.
4. **Despliegue** (`deploy.yml`): `20261077000001` y después `20261077000002`.
5. **Verificación posterior** (sólo lectura): cuerpo y ACL vivos; los `NOTICE` coinciden con el checkpoint 0.3; movimientos `'sale'` nulos restantes = sin venta viva + no fechables + contradicciones; una fila de auditoría por cuenta afectada.

**Rollback**:

- Datos: el `UPDATE` de D7 por ids de la auditoría.
- Función: una migración nueva que re-declara el cuerpo de partida capturado en 0.1 con su `COMMENT` y su ACL, retira en el mismo PR la reaplicación de `20261077000001` de `KPI_Validation.yml` (sobre una base reconvergida el preflight tomaría la rama de reescritura) y ajusta el bloque (0) del gate. Si los movimientos ya fueron completados con sucursales desactivadas, volver la función atrás reabre el riesgo de D6: se revierten primero los datos.

## Open Questions

| # | Pregunta | Opciones | Recomendación |
|---|---|---|---|
| OQ-A | ¿Completamos la sucursal de los movimientos cuyo origen no depende de saber cuándo se dio de baja una sucursal? Son los de cuando la cuenta todavía **no tenía sucursales** (casos 1 y 3: 110) y los de cuando tenía **una sola** (caso 2: 207). En 261 de ellos la sucursal de origen es la «Principal» de la cuenta del incidente, hoy desactivada. Ojo con los 110 del primer grupo: ese stock no salió de una sucursal sino del stock general de la cuenta, que en junio el sistema pasó entero a la sucursal más antigua; anotarlo ahí es seguir esa misma convención. | (a) Sí, los 317, con su sucursal de origen aunque hoy esté desactivada. (b) Sólo los 56 cuyo origen hoy opera; los 261 de la sucursal desactivada quedan vacíos. (c) Ninguno. | **(a)**, siempre que OQ-D sea (a). Es lo que pediste: que el historial diga de dónde salió el stock. Cada movimiento queda anotado en la auditoría por regla, así que se puede revertir sólo una parte. |
| OQ-B | Los 126 de cuando la cuenta ya tenía **dos o más** sucursales: ¿reconstruimos cuál era la principal en ese momento? En la cuenta A (11) es seguro: sus dos sucursales funcionaron siempre. En la cuenta del incidente (115) depende de saber cuándo se dio de baja «Principal», y esa fecha no quedó guardada; lo que sí quedó guardado es todo cambio de sucursales desde el 26-08. | (a) Reconstruirla con lo registrado: los de la cuenta A y los de la cuenta del incidente desde el 26-08 se completan; los del 22 al 25-08 quedan vacíos. (b) Dejar los 126 vacíos. | **(a)**, si el checkpoint confirma desde cuándo se registran los cambios de sucursales (la fecha del despliegue del 25-08). Si no se puede confirmar, **(b)**. El número exacto de los que quedan vacíos te lo damos antes de escribir la migración. |
| OQ-C | Los 73 movimientos cuya venta ya no existe (ventas borradas o editadas, que tienen su movimiento de cierre, y los huérfanos de antes de agosto que decidiste dejar como están en `stock-movements-edicion`). | (a) Dejarlos como están. (b) Completarlos con la misma regla. | **(a)**. En los de ventas borradas, el movimiento de cierre también está vacío: completar sólo el original los desbalancea por sucursal, y completar los dos amplía la excepción a otro tipo de movimiento. Los huérfanos ya los decidiste. No bloquea. |
| OQ-D | Si un movimiento queda anotado en una sucursal **desactivada**, ¿qué pasa al borrar esa venta (o compra)? Hoy el stock volvería a esa sucursal, que no se ve ni se vende: la misma clase de problema del 22-08. Pasa con los 261 de OQ-A y ya le pasa hoy a toda venta o compra hecha en una sucursal que después se dio de baja. | (a) Arreglarlo en este cambio: la reversa usa la sucursal principal que esté funcionando y lo deja anotado en el movimiento de cierre. Una sucursal **cerrada** (no dada de baja) sigue pidiendo reabrirla, como hoy. Vale para ventas y compras. (b) No arreglarlo acá y elegir OQ-A (b). (c) Completar igual y dejar el problema anotado. | **(a)**. Sin esto, completar los 261 empeora el borrado de esas ventas (hoy devuelve el stock a la principal). Con esto, borrar y editar esas ventas devuelven el stock al mismo lugar, y queda resuelta para siempre la mitad «borrado» de la pregunta OQ-8 del cambio anterior. |

**OQ-A, OQ-B y OQ-D bloquean la escritura de las dos migraciones**; OQ-C no bloquea (se aplica su recomendación salvo que el PO diga otra cosa). El apply arranca con el checkpoint 0 y no escribe SQL hasta registrar acá el OK textual del PO.

### Sign-off del PO

**Resueltas el 2026-10-11 por el PO: todas por la recomendación** (respuesta textual: «vamos con todo lo recomendado»):

- **OQ-A (a)**: se completan los 317 movimientos de cuando la cuenta no tenía sucursales o tenía una sola, con su sucursal de **origen** real aunque hoy esté desactivada.
- **OQ-B (a)**: los 126 de cuando había dos o más sucursales se reconstruyen sólo con el estado registrado; el resto queda nulo.
- **OQ-C (a)**: los 73 movimientos sin venta viva no se tocan.
- **OQ-D (a)**: `rpc_reverse_stock_movement` repone en la principal operativa cuando la sucursal del movimiento está desactivada (contramovimiento con esa sucursal y la original en `metadata`); una sucursal **cerrada** sigue rechazando con `P0422`; un movimiento sin sucursal sigue como hoy.

Checkpoint de producción (2026-10-11, sólo lectura, lo hizo el orquestador): `max(version) = 20261075000002` (323 migraciones); los `md5(replace(prosrc, E'\r', ''))` de `rpc_reverse_stock_movement` (`3af74d58ee4bc40691d066d8d4860d7a`), `_stock_apply_delta` (`b3f6edd5ea68b0904ff2b5e29bce9843`), `c26_default_branch` (`4fb12c57c3417bb98212cddd2e5ac069`) y los demás cuerpos que toca el change son idénticos a los de la base local; la clasificación de los 516 movimientos `'sale'` nulos confirma 47 / 207 / 63 / 126 y 73 sin venta viva (27 de ellos con contramovimiento `sale_return`, 19 también nulos); `stock_movements.account_id` nunca es nulo (0 filas). La constante X queda en `2026-08-26 00:00:00-03`: el primer evento de ciclo de vida de sucursales de toda producción es del 2026-09-01 y el disparador se desplegó el 2026-08-25.

Para la cuenta del incidente la regla de D2/D3 da: movimientos anteriores al alta de la sucursal nueva (`2026-08-22T15:24Z`) → la original (`unica`, y `pre_sucursal` para los anteriores a la original); entre esa alta y X → nulo (`no_fechable`: la baja de la original no tiene fecha); desde X → la principal operativa registrada. Para la cuenta de dos sucursales siempre activas → la más antigua (`reconstruida`).

### Notas de implementación (apply, 2026-10-11)

Desvíos y precisiones del apply contra el texto de arriba. Ninguno cambia una decisión firmada por el PO; todos van hacia «ante la duda, nulo» o precisan un borde que el design dejaba abierto.

- **Desempate por `created_at` (D2/D3).** `c26_default_branch` ordena por `created_at` sin desempate. Si la sucursal que la regla elegiría (la más antigua para `pre_sucursal`, la primera operativa o la más antigua para `reconstruida`) comparte `created_at` con otra sucursal de la cuenta, el origen no es demostrable y el movimiento queda nulo (`no_fechable`). El gate lo fija (B17, mutación M12). Se sumó al delta del requirement y un escenario.
- **Evento en el mismo instante que el movimiento (D3).** Un evento de ciclo de vida de una sucursal con `created_at` exactamente igual al del movimiento (misma transacción) vuelve desconocido su estado en T, igual que dos eventos del mismo instante con estados previos distintos (B18/B19, mutaciones M13/M14).
- **Sólo cuentan los eventos que cambiaron el estado operativo (D3).** Los de `is_active` o `status` distintos entre `before` y `after`; una edición de nombre o dirección (`branch.updated`) no interviene en el rebobinado. Se compara el texto de la `metadata`, sin casts que puedan abortar la migración.
- **Línea de tiempo por intervalos (D7).** El rebobinado «estado previo del primer evento posterior a T» se calcula con intervalos abiertos `(lo, hi)` por sucursal y un `JOIN` por rango (los instantes de los eventos no pertenecen a ningún intervalo), no con una subconsulta por fila: 50.000 movimientos en 5 cuentas con historia, en **10,8 s** (referencia: 24 s del backfill de ventas).
- **Contadores del NOTICE (D7).** `sin_cuenta` agrupa dos casos —la venta no tiene cuenta, o el movimiento declara otra cuenta distinta de la de la venta— y no se escribe nada en ninguno. `destino_desactivado` = el origen escrito está hoy con `is_active = false`; `destino_cerrado` = hoy activo pero con `status = 'closed'` (disjuntos, como los trata D6). El NOTICE final dice `% movimientos completados en % cuentas`, que es lo que exige la cadena de CI (` 0 movimientos completados en 0 cuentas`).
- **Fallback de la reversa sin sucursal operativa (D6).** Si la cuenta no tiene ninguna sucursal operativa, `c26_default_branch` devuelve la más antigua a secas (puede ser la misma desactivada): el stock entra donde ya entraba un movimiento nulo, sin error nuevo, y el contramovimiento conserva la sucursal original y **no** suma `fallback_*` (no hubo respaldo). Sale del cálculo `v_fell_back = (se pidió la principal) AND (la sucursal efectiva ≠ la original)`. Se sumó un escenario al delta y el gate lo fija (A3c).
- **El gate termina en `ROLLBACK` (D9).** La migración de datos es global: también completa los movimientos nulos que haya fuera del fixture. Un `COMMIT` dejaba, en la base local compartida, ese efecto persistente (se vio en la primera corrida: completó un movimiento local ajeno y hubo que revertirlo con el `UPDATE` por ids de la auditoría, lo que de paso probó el procedimiento de reversión). El gate verifica todo lo suyo (aserciones y residuo cero) antes del `ROLLBACK`.
- **Mutaciones (D9, tareas 2.5 y 4.3).** Parte A: M1 sin respaldo, M2 respaldo también para cerradas, M3 contramovimiento con la sucursal original. Parte B: M4 a M11 de la lista, más M12 (sin desempate), M13 (evento del mismo instante ignorado) y M14 (eventos contradictorios tomados). Las 14 las detecta el gate con mensajes propios; el control sin mutar pasa.
- **Réplica de la clasificación de producción.** Con fixtures que reproducen los cuatro casos y los 73 sin venta viva (47 / 207 / 63 / 126 / 73, cuenta del incidente con su historia de sucursales), la migración completa 413 (110 `pre_sucursal`, 207 `unica`, 96 `reconstruida`), deja 30 `no_fechable` (los del 22 al 25-08 de la cuenta del incidente), cuenta 261 discrepancias venta ≠ movimiento (todas con el origen hoy desactivado), no toca los 73 y no cambia ninguna otra columna. Los 30 `no_fechable` de la réplica son una suposición de reparto (cuántos de los 115 de la cuenta del incidente caen entre el alta de Showroom y X); el número real lo da la verificación posterior en producción (grupo 9), y no depende de ninguna suposición: la regla es la misma.
