# Design — v21-branch-as-root (C-26)

## Context

Post-C-21, `branch_stock` es el único ledger de inventario y cada cuenta tiene su branch default ("Casa Central"/"Principal", la más antigua). Pero `Branch` sigue siendo una entidad pasiva:

- `branches`: `id, account_id, name, address, is_active, created_at` — sin estado operacional.
- Transferencias: `rpc_transfer_stock` inserta dos `stock_movements` (`transfer_out`/`transfer_in`) **sin id común** — no hay forma fiable de reconstruir "la transferencia" como hecho.
- `branch_stock.quantity` sin CHECK: C-21 decidió gate de venta **global** (Σ branch_stock) para no bloquear ventas multi-sucursal sin tooling; el costo es que una branch puede quedar negativa transitoria.
- Los RPCs de venta validan `is_active = TRUE` para `p_branch_id`; no existe el concepto "sucursal cerrada operacionalmente".

**Estado de prod (2026-06-12, verificado)**: 26 cuentas × 1 branch activa; 0 cuentas multi-branch; 0 transferencias históricas; 0 ventas con `branch_id` (de 142); 0 filas negativas en `branch_stock`. → Los invariantes nuevos no afectan ningún dato ni flujo existente.

**Stakeholders**: C-27 (punto de venta AFIP por branch), C-28 (Cashbox por branch), C-29 (documentos con branch) dependen de este change. Governance ALTO: PO revisa proposal + design y resuelve las OQs antes del apply.

## Goals / Non-Goals

**Goals**
1. `Branch` con lifecycle operacional: `status ('active'|'closed')` + `open()`/`close()` con timestamps.
2. Invariante `onHand >= 0` en `branch_stock` (CHECK) + gate per-branch para operaciones con `branch_id` explícito (OQ-A).
3. `StockTransfer` como entidad con identidad (`stock_transfers`) e historial; `stock_movements.transfer_id` vincula las dos patas.
4. Operar contra branch cerrada → error claro (`P0422 branch_closed`).
5. Backend y UI mínimos para operar el lifecycle y ver el historial de transferencias.

**Non-Goals**
- `branch_id` NOT NULL en documentos operativos (DEC-19 pleno): se difiere a C-29 (`quickSale()` es quien creará documentos con branch obligatoria). Hoy 142/142 ventas tienen `branch_id` NULL — forzar NOT NULL acá agrega backfill y riesgo sin consumidor.
- `Warehouse`/`StorageLocation` como subdivisión de Branch (explícitamente V2-futuro, modelo §3.2).
- `reserved` en `BranchStock` (campo diseñado pero no activado — modelo §3.4, Reservation pospuesta).
- Multi-step transfers (draft/in-transit/received): `stock_transfers.status` nace con un solo valor `'completed'` (transferencia atómica). El enum existe para habilitar in-transit en el futuro sin migrar.
- Tocar el flujo de caja o numeración fiscal (C-27/C-28).

## Decisions

### D1 — `status` operacional separado de `is_active`
`is_active` = existencia (soft-delete, ya usado por selectores e historial). `status` = ¿puede operar hoy? Una branch puede estar `closed` temporalmente (refacción, temporada) y reabrirse; desactivarla es retirarla. Alternativa considerada: reutilizar `is_active` con un tercer estado — rechazada: rompe la semántica booleana existente en RLS/selectores y mezcla dos ciclos de vida distintos.

### D2 — Gate per-branch SOLO cuando la operación lleva `branch_id` explícito (OQ-A)
- Venta/ajuste **sin** `branch_id` → descuenta de la default branch con gate global (Σ) como hoy. En cuentas mono-branch (el 100% actual), Σ ≡ stock de la default → comportamiento idéntico.
- Venta **con** `branch_id` → gate contra `branch_stock` de ESA branch (`quantity >= qty`), error `P0409 insufficient_branch_stock` si no alcanza. Restaura la semántica original de C-08 que la reescritura de C-12 pisó.
- El CHECK `quantity >= 0` es la red de seguridad física del invariante (DEC-19/modelo §5: `onHand >= 0`).
- `c21_apply_branch_stock_delta` (helper) se mantiene como única vía de escritura; con el CHECK, cualquier path que intente dejar negativo falla en DB.
- **Excepción**: `rpc_apply_product_stock_delta` con `p_allow_negative=TRUE` (reversa de compras borradas) podría violar el CHECK → se le quita el flag y la reversa hace floor a 0 con un `stock_movement` de ajuste por la diferencia (trazabilidad en vez de negativo silencioso). Ver OQ-C.
- Alternativa rechazada: mantener gate global puro (C-21) — contradice DEC-19 y deja el invariante sin enforcement justo cuando aparece el tooling (transferencias de primer nivel) que era el prerequisito para imponerlo.

### D3 — `stock_transfers` como tabla + `transfer_id` en movements (no "movement pareado")
Tabla propia con identidad: habilita historial por sucursal, futuro estado in-transit, y es el agregado que el dominio V2 nombra. Los dos `stock_movements` llevan `transfer_id` FK → la trazabilidad fina sigue en el ledger de movimientos (sin duplicar cantidades). Alternativa rechazada: solo agregar `operation_group_id` común a los dos movements — no da identidad ni estado a la transferencia, y el historial habría que reconstruirlo con heurísticas.

### D4 — `close()` bloqueado si la branch tiene stock (OQ-B)
`rpc_close_branch` falla con `P0409 branch_has_stock` si `Σ branch_stock de la branch > 0`. Fuerza transferencia previa → el stock nunca queda "congelado" en una branch cerrada y el invariante de C-28 (caja por branch activa) nace limpio. La UI ofrece el atajo "Transferir todo a …" antes de cerrar. Alternativa rechazada: permitir cierre con stock — crea una tercera categoría de stock (existente pero inoperable) que todos los reportes tendrían que conocer.

### D5 — RPCs SQL como única superficie de escritura (patrón vigente)
`rpc_open_branch`/`rpc_close_branch`/`rpc_transfer_stock` SECURITY DEFINER con guard `is_account_writer` (owner/admin), ERRCODEs de 5 chars (P04xx — convención post-20260624000001). El backend Python las invoca vía repositories (JWT-passthrough); sin lógica de negocio en routers (regla dura del proyecto).

### D6 — Validación de branch cerrada centralizada
Las RPCs operativas que aceptan/usan branch (`rpc_create_sale_operation(_v2)`, `rpc_adjust_branch_stock`, `rpc_transfer_stock`, `rpc_apply_product_stock_delta` con branch explícita) validan `status = 'active'` además de `is_active`. La default branch de una cuenta nunca puede cerrarse si es la única activa (guard en `rpc_close_branch`: debe quedar ≥ 1 branch operativa por cuenta) — evita dejar una cuenta sin destino de stock.

## Risks / Trade-offs

- [El CHECK `quantity >= 0` rompe algún path de escritura no auditado] → Mitigación: auditoría pre-migración de todos los writers de `branch_stock` (helper, rpc_adjust_branch_stock, rpc_transfer_stock, importador — todos pasan por upserts conocidos post-C-21) + gate en la migración (0 filas negativas) + smoke transaccional post-push.
- [La reversa de compras con floor a 0 (D2/OQ-C) altera la paridad con el comportamiento previo] → Mitigación: deja `stock_movement` de ajuste explícito con reason `'floor_on_purchase_delete'`; ocurre solo si se vendió el stock comprado antes de borrar la compra (caso raro, hoy 0 deletes con reversa registrados).
- [Cuentas nuevas sin branch: el lazy-create del helper crea la default con `status` default 'active' — si la columna naciera NULL] → Mitigación: `status NOT NULL DEFAULT 'active'` + backfill en la misma migración.
- [UI: el PO espera ver el lifecycle pero el plan free/avanzado no tiene módulo branches] → El lifecycle vive en `/sucursales` (PRO). La default branch de cuentas no-PRO queda 'active' invisible — sin cambio de UX para ellas.

## Migration Plan

1. **Migración A (única, no destructiva)**: ALTER branches (status/opened_at/closed_at + backfill) → CREATE stock_transfers + RLS + índices → ALTER stock_movements ADD transfer_id → gate 0 negativos + ALTER branch_stock ADD CHECK → CREATE rpc_open/close_branch → reescritura de rpc_transfer_stock y validaciones/gates en RPCs operativas. `npx supabase db push`.
2. Backend (TDD) + frontend → PR → merge → Render/Vercel deploy.
3. Smoke transaccional en prod (venta con branch explícita: gate per-branch; transfer con transfer_id; close con stock bloquea; venta en branch cerrada falla).
4. **Rollback**: DROP CHECK, DROP rpc_open/close_branch, restaurar rpc_transfer_stock previa (pg_proc snapshot en la migración como comentario), DROP stock_transfers + columna transfer_id. Sin pérdida de datos (las columnas nuevas de branches son aditivas).

## Open Questions (resolver con el PO antes del apply)

- **OQ-A — Gate per-branch + CHECK `onHand >= 0`**: ¿confirmás reemplazar la política transitoria de C-21 (gate global, negativos permitidos) por el invariante per-branch para operaciones con branch explícita? Impacto hoy: nulo (0 cuentas multi-branch). Impacto futuro: vender desde sucursal B exige stock EN B (transferir antes de vender). **Recomendación: sí** — es DEC-19, y este change trae el tooling (transferencias con historial + UI) que era el prerequisito.
- **OQ-B — Cierre con stock**: ¿bloquear `close()` si la branch tiene stock (recomendado, D4) o permitir cierre con stock congelado?
- **OQ-C — Reversa de compras borradas vs CHECK**: si al borrar una compra la reversa dejaría la branch negativa, ¿floor a 0 con movement de ajuste explícito (recomendado) o rechazar el borrado de la compra (`P0409`)?

## Resolved Decisions (PO, 2026-06-12 — "dale con lo recomendado")

- **OQ-A = SÍ**: gate per-branch para operaciones con `branch_id` explícito + `CHECK (quantity >= 0)` en `branch_stock`. Refinamiento de implementación: las operaciones **sin** `branch_id` validan contra la **default branch operativa** (no contra Σ pura) — en mono-branch es idéntico (Σ ≡ default); en multi-branch es lo coherente con el invariante (evita que el gate global pase y el CHECK reviente con error críptico). Se introduce `c26_default_branch(account_id)`: la branch más antigua con `status='active' AND is_active`, con fallback a la más antigua a secas; `c21_apply_branch_stock_delta` la usa para resolver el destino.
- **OQ-B = SÍ**: `rpc_close_branch` bloquea con stock (`P0409 branch_has_stock`) y si es la última operativa (`P0409 last_active_branch`).
- **OQ-C = SÍ**: floor a 0 con `stock_movement` trazable (`reason='floor_on_purchase_delete'`, notes con solicitado vs aplicado). Nota de implementación: la firma de `rpc_apply_product_stock_delta` **se conserva** (evita ventana de incompatibilidad DB/backend en el deploy); `p_allow_negative` cambia de semántica: `TRUE` = floor a 0 trazable (ya no permite negativos — el CHECK los prohíbe), `FALSE` = error `P0409` si no alcanza. El backend no requiere cambios de firma.
