## Why

`ventas-sucursal-por-defecto` (archivado el 2026-10-10) asignó a su sucursal 887 ventas históricas y completó la sucursal de 335 movimientos de stock de venta, pero sólo donde se podía demostrar de qué sucursal había salido el stock con una regla muy estrecha (OQ-5 (c): «la sucursal asignada a la venta ya existía y era la única de la cuenta cuando se escribió el movimiento»). En producción quedaron **516 movimientos `type = 'sale'`, `reference_type = 'sale'` sin sucursal** (medido el 2026-10-10, sólo lectura). El PO pidió el mismo día «arrancar» la decisión sobre esos 516.

La regla anterior ataba el origen del movimiento a la sucursal que la migración le había **asignado a la venta** (en general, la principal de hoy). Pero el stock salió de la sucursal que era la principal **cuando se registró la venta**, y eso el sistema lo puede reconstruir para la mayoría de los casos sin depender de la venta: la cuenta no tenía sucursales todavía (el stock vivía en `products.stock` y C-21 lo materializó en la sucursal más antigua), tenía una sola, o tenía varias y su historia de altas y bajas está registrada. Los 443 movimientos que referencian una venta viva se reparten así:

| Caso | Movimientos | Cuentas | Qué sucursales existían cuando se registró el movimiento | Origen |
|---|---|---|---|---|
| 1 | 47 | 5 | Ninguna (anteriores a la creación de su única sucursal) | La única sucursal, que sigue operativa |
| 2 | 207 | 1 (la del incidente del 22-08) | Una sola: la original, hoy **desactivada** | La original |
| 3 | 63 | 2 | Ninguna | La más antigua de la cuenta (donde C-21 materializó el stock legacy): 9 operativa, 54 la original desactivada |
| 4 | 126 | 2 | Dos o más | La principal operativa **en ese momento**: 11 seguras (dos sucursales siempre activas); 115 de la cuenta del incidente, que dependen de cuándo se dio de baja la original |

Los otros **73 no tienen venta viva**: son movimientos de ventas borradas o editadas (con su contramovimiento de cierre) y los huérfanos históricos que `stock-movements-edicion` dejó sin tocar por decisión del PO.

Hay además un efecto que obliga a decidir junto con el dato: si un movimiento queda registrado en la sucursal original, que está **desactivada**, borrar esa venta hoy devolvería el stock **a esa sucursal**, que no se ve ni se vende. Es la misma clase del incidente del 22-08 y el candidato OQ-8 que dejó abierto `ventas-sucursal-por-defecto`.

## What Changes

- **Se completa la sucursal de origen de los movimientos de stock de venta que quedaron sin sucursal**, en una migración de **datos** (sin funciones), idempotente y que informa sus propios conteos. Alcance: sólo `branch_id`; sólo movimientos `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL` de una **venta viva**. El origen es la sucursal de la que salió el stock cuando se registró el movimiento, reconstruida así (gana la primera que aplica):
  - **sin sucursales todavía** (caso 1 y 3): la sucursal más antigua de la cuenta, donde C-21 materializó el stock legacy;
  - **una sola sucursal** (caso 2): esa, aunque hoy esté desactivada o cerrada;
  - **dos o más** (caso 4): la que `c26_default_branch` habría devuelto en ese instante, sólo si el estado de cada sucursal en ese instante está **registrado** (el ciclo de vida de sucursales queda en `audit_logs` desde `sucursal-guard-vaciado-auditoria`, 2026-08-25). Lo que no se puede fechar queda sin sucursal y se cuenta.
  - Veto: si la caja o el banco de esa misma operación registraron **otra** sucursal, el movimiento no se toca y se cuenta como contradicción.

  La sucursal de la **venta** no cambia: en la cuenta del incidente la venta seguirá en la principal de hoy y su movimiento en la original (discrepancia contada, como ya pasaba en `ventas-sucursal-por-defecto`).
- **Extensión de la única excepción auditada a RN-21**, no una excepción nueva: misma columna, misma clase de movimientos, misma auditoría por id y reversible. Cierra la excepción para siempre: lo que quede sin sucursal (no fechable, contradicción, sin venta viva) queda así.
- **La reversa de stock deja de reponer en una sucursal desactivada** (si el PO acepta OQ-D (a)). En `rpc_reverse_stock_movement`, cuando la sucursal del movimiento original está desactivada (`is_active = false`), la reversa se aplica en la sucursal principal operativa y el contramovimiento registra **esa** sucursal (con la de origen en `metadata`). Una sucursal **cerrada** sigue rechazando como hoy (`P0422 branch_closed`, se reabre); un movimiento sin sucursal sigue cayendo en la principal vigente. Alcanza a ventas y a compras (misma función). Es una migración de funciones aparte, que va **antes** que la de datos. **BREAKING (comportamiento)**: borrar una venta o compra cuyo movimiento está en una sucursal desactivada deja de reponer o descontar en esa sucursal; resuelve la mitad «reversa» de OQ-8 de `ventas-sucursal-por-defecto` para toda venta y compra.
- **Los 73 movimientos sin venta viva no se tocan** (recomendación de OQ-C).
- **Gates.** Nace `supabase/tests/test_stock_movimientos_sucursal_origen.sql`, que ejecuta la reversa y la migración de datos (dos veces) sobre fixtures con historia de sucursales armada a mano, más mutaciones. El bloque (9b) de `test_ventas_sucursal_por_defecto.sql`, que fija **a propósito** el comportamiento actual de OQ-8, cambia a conciencia. Las dos migraciones nuevas se reaplican al final de la cadena de `KPI_Validation.yml`.

Fuera de alcance (quedan como candidatos u Open Questions):

- la sucursal de las **ventas** (la decidió `ventas-sucursal-por-defecto`, OQ-4);
- los movimientos de **compras** sin sucursal (las compras históricas conservan su sucursal vacía por decisión firmada en `caja-compras-cobranzas`);
- «Facturar venta manual» sobre una venta cuya sucursal no opera (la otra mitad de OQ-8);
- movimientos con `account_id` nulo, que hoy la reversa no encuentra (se miden en el checkpoint; si existen, candidato propio);
- el retiro de `products.stock` histórico o un movimiento «inicial» que registre la materialización de C-21.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `inventory-single-ledger`:
  - «Única excepción auditada al carácter append-only: la sucursal nula de los movimientos de venta de origen demostrable»: pasa a cubrir también la migración de datos de este change, con la reconstrucción del origen por la historia de sucursales de la cuenta (y no por la sucursal asignada a la venta), el veto por caja y banco, y el cierre definitivo de la excepción.
  - «Reversa de stock al eliminar venta o compra, independiente de la ruta de creación»: la reversa de un movimiento registrado en una sucursal desactivada se aplica en la principal operativa y el contramovimiento registra la sucursal donde efectivamente entró o salió el stock.

## Impact

- **Base de datos**:
  - `supabase/migrations/20261077000001_reversa_stock_sucursal_desactivada.sql`: reescribe `rpc_reverse_stock_movement` desde su cuerpo vivo detrás de un preflight de `md5` (partida local `3af74d58ee4bc40691d066d8d4860d7a`, a confirmar contra producción). Misma firma, mismo `COMMENT` ampliado, ACLs intactas (sin `EXECUTE` para `anon`/`authenticated`).
  - `supabase/migrations/20261077000002_stock_movimientos_sucursal_origen.sql`: sólo datos. Una fila de `audit_logs` por cuenta con los ids.
  - Numeración: la última en `main` es `20261075000002`. `20261076…` queda para el hermano `compras-gastos-sucursal-por-defecto` (en propose en paralelo, todavía sin número reservado); `remitos-venta`/`remitos-compra` sólo usan `20261070000001`/`20261071000001`.
- **Gates y CI**: gate nuevo; bloque (9b) de `test_ventas_sucursal_por_defecto.sql`; `KPI_Validation.yml` (paso nuevo y reaplicación). Se vuelven a correr `test_stock_ledger_solo_rpc`, `test_stock_movements_edicion`, `test_remito_a_venta`, `test_delete_guard_ledgers` y `test_function_acl_gate`.
- **Base de conocimiento**: RN-21 (`knowledge-base/05_reglas_de_negocio.md`), que hoy dice que la excepción «no se reabre».
- **Backend y frontend**: sin cambios.
- **Superficie frontend: no tiene.** Ninguna pantalla muestra ni filtra la sucursal de un movimiento de stock (el único lector del cliente, `components/stock/stock-movements-panel.tsx`, no la renderiza) y el diálogo de borrado no nombra la sucursal a la que vuelve el stock. El resultado se informa con los `NOTICE` de la migración, su auditoría y la verificación posterior en producción.
- **Governance: ALTA.** Modifica en masa el ledger de stock en producción y reescribe la función que repone stock en todo borrado de venta y compra. Ninguna de las dos migraciones se escribe sin el OK textual del PO sobre OQ-A, OQ-B y OQ-D, y la migración de datos la mergea el PO.
