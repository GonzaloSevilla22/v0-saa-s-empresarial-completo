## Why

La cuenta corriente de proveedores existe entera desde C-30 (2026-06-20) y **nunca se usó**. Están las tablas (`supplier_accounts`, `supplier_account_movements`, `payments_made`), las RPCs, el backend de 3 capas, la pantalla `/proveedores/[id]/cuenta` con saldo, historial y "Registrar pago", y desde `pagos-cableados-restantes` (2026-08-20) hasta el helper compartido `_pay_register_party_charge` con su pata `supplier` **ya escrita y ejercitada por tests**. Lo único que falta es lo que la conecta con la realidad:

1. **No hay proveedores**: 0 filas en `suppliers` en producción. No hay ABM — la tabla no tiene endpoint de alta en el backend Python (`SupplierRepository` existe pero **solo lo consumen sus propios tests**), ni pantalla, ni entrada de sidebar. La única forma de crear un proveedor hoy es un INSERT directo contra la tabla.
2. **La compra no sabe a quién se le compró**: `purchases.supplier_id` existe y es nullable, y `rpc_create_purchase_operation` **ni siquiera lo recibe** — las 38 compras de producción tienen `supplier_id NULL` al 100%. El form de compra no tiene selector de proveedor.
3. **La compra a crédito no carga nada**: `rpc_create_purchase_operation` ya deriva el `kind` real de la forma de pago desde `pagos-cableados-restantes` (D7/OQ-E), pero el cargo real quedó explícitamente afuera de ese change — *"0 proveedores en prod hoy, sin selector en el form"*.

El resultado es una asimetría que hoy está escrita en las specs y no en el código: `payment-method` declara que *"en el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (**cliente en venta, proveedor en compra**) y postear el cargo en la cuenta corriente correspondiente"*. La pata cliente se cumplió en `pagos-cableados-restantes`; la pata proveedor es un requirement sin implementación. Y `supplier-account` sigue arrastrando la decisión opuesta de C-30 (OQ-3 opción B: *"el flujo de compras de stock no toca la cta cte"*), tomada cuando el catálogo de formas de pago todavía no existía.

Para el microemprendedor, esto significa que la pregunta más común de su operación diaria — *"¿cuánto le debo al proveedor?"* — no tiene respuesta en la app, aunque toda la maquinaria para responderla esté construida y pagada.

## What Changes

### 1. ABM de proveedores (el maestro que falta)

- **Endpoints REST** `/suppliers` (list / get / create / update / delete) en el backend Python de 3 capas, molde exacto de `clients`: router → service (`require_role`) → `SupplierRepository` (**el que ya existe**, extendido con `create`/`update`/`count_by_org`; no se crea un repositorio nuevo).
- **Identidad fiscal del proveedor** (RN-96 — `FiscalIdentity` es Value Object compartido entre Customer y Supplier): `suppliers` suma `tax_id`, `iva_condition`, `legal_name`, `email`, `phone`, exactamente las mismas columnas y el mismo `Literal` de condición IVA que `clients`. Aditivo, todo nullable.
- **Baja = soft delete**: `SupplierRepository.soft_delete("suppliers", ...)` — `suppliers` ya está en `SOFT_DELETE_TABLES` y ya tiene `deleted_at`/`deleted_by` desde `v3-soft-delete-policy`. Cero código nuevo de borrado.
- **Límite por plan reutilizado, no reimplementado**: el trigger `trg_guard_supplier_plan_limit` (ERRCODE `P0B10`, `billing-pro-trial`) ya enforcea 20/100/300/1000 en cada INSERT. Lo único que falta es que ese error llegue al usuario: hoy `P0B10` **no está mapeado** en `backend/core/errors.py` y saldría como 500 genérico. Se mapea a 403.

### 2. Superficie de proveedores (pantalla + navegación)

- Nueva ruta **`/proveedores`**: listado con búsqueda, alta/edición en diálogo, baja, export CSV y banner de límite de plan — molde de `/clientes`, con los mismos componentes base.
- Nueva entrada de sidebar **"Proveedores"** en el grupo **Catálogo**, debajo de "Clientes" (ícono `Truck`).
- **`/proveedores/[id]/cuenta` deja de ser inalcanzable**: se llega desde una acción de fila del listado. De paso, su botón "volver" —que hoy apunta a `/compras`— pasa a apuntar a `/proveedores`.

### 3. La compra sabe a quién se le compró

- `rpc_create_purchase_operation` suma `p_supplier_id uuid DEFAULT NULL` (parámetro trailing, aditivo) y persiste `purchases.supplier_id` en **las dos ramas** del INSERT (línea con producto y línea sin producto).
- El **form de compra** suma un selector "Proveedor" con alta inline ("Nuevo proveedor"), molde del selector de cliente del form de venta.
- El **listado de compras** muestra el proveedor imputado como badge (`supplier_id`/`supplier_name` expuestos en `PurchaseItemOut`, hoy explícitamente omitidos *"sin selector en el form hoy (D2/OQ-1)"*).
- La **edición** reimputa el proveedor por contrato **tri-estado** (`model_fields_set`, nunca `is None`), mismo patrón que `payment_method_id` y `branch_id` — cierra la OQ-1 que `edicion-preserva-contexto` dejó abierta.

### 4. La compra a crédito carga la cuenta corriente del proveedor

- Cuando el `kind` derivado de la forma de pago imputada es `credit`, `rpc_create_purchase_operation` postea el cargo por el total vía **`_pay_register_party_charge(..., 'supplier', ...)`** — el helper compartido que ya existe, ya despacha por tipo de parte y ya emite `SupplierAccountCharged`. **Cero lógica nueva de cuenta corriente.**
- El disparo usa el **`v_kind` crudo**, nunca el `COALESCE(v_kind, 'credit')` del payload del evento: sin esa distinción, toda compra sin forma de pago imputada (el 100% de las 38 históricas y cualquier alta futura que no elija método) empezaría a cargar cuenta corriente en silencio.
- **La compra a crédito exige proveedor**: `credit_requires_supplier` con `ERRCODE = 'P0400'` —mismo código y misma forma que `credit_requires_client` del lado venta—, validado **antes** de tocar stock. No hay deuda sin acreedor.
- **BREAKING (comportamiento de dominio)**: `supplier-account` deroga la decisión OQ-3/opción B de C-30. El escenario vigente *"el flujo de compras de stock no toca la cta cte"* se retira: a partir de este change, la compra imputada a `kind = 'credit'` **sí** postea automáticamente. La compra sin forma de pago imputada sigue sin postear nada (compatible hacia atrás con el histórico).

### 5. Lo que ya está construido y este change apenas activa

Tres piezas entran en el camino real **sin una línea de código nueva**, y este change las cubre con tests porque hasta hoy nunca se ejercitaron:

- **Inmutabilidad**: el guard `P0423` de `rpc_atomic_update_purchase_operation` ya bloquea la edición de una compra con `supplier_account_movements` posteados (escrito por `pagos-cableados-restantes` D6 *"cuando exista, vía el helper compartido"*). El `is_payment_locked` del listado ya lo deriva.
- **Compensación por borrado**: `rpc_delete_purchase_operation` ya revierte el cargo del proveedor vía `_pay_reverse_party_charge` con guard `P0425` de saldo negativo (`delete-guard-ledgers`).
- **Contabilidad**: `PurchaseCreated` ya transporta el `kind` real y `_journal_post_from_event` ya acredita `2100 Proveedores` para `credit`. **El journal no se toca.**

## Capabilities

### New Capabilities
- `supplier-directory`: el proveedor como maestro operable — persistencia con identidad fiscal compartida (RN-96), endpoints REST de CRUD en el backend Python, límite por plan delegado en el trigger existente, soft delete, y la superficie completa (`/proveedores` con entrada de sidebar, acceso a la cuenta corriente, y el selector con alta inline en el form de compra).

### Modified Capabilities
- `supplier-account`: se deroga la integración manual (OQ-3 opción B de C-30). La compra imputada a una forma de pago de `kind = 'credit'` postea el cargo automáticamente en la misma transacción; la compra sin forma de pago sigue sin postear.
- `party-account-charge`: la pata `supplier` del helper compartido deja de ser una capacidad latente y pasa a tener un camino de producción — el alta de compra a crédito.
- `payment-method`: la imputación de compra acepta proveedor; el requirement de "efectos según el camino" gana los escenarios de compra que hoy solo estaban escritos para venta.
- `operation-edit-context`: `supplier_id` pasa de "preservado a ciegas porque el form no lo expone" a **reimputable por contrato tri-estado**, igual que `branch_id` y `payment_method_id`.
- `data-api-endpoints`: endpoints REST de proveedores (CRUD por dominio, 3 capas, Pydantic v2).

## Impact

**DB** — una migración idempotente, `supabase/migrations/20261009000001_compras_proveedor_cuenta_corriente.sql` (MAX local = `20261007000001` (`cuentas-billetera-tipo`, #447); `20261008000001` reservado por `cuenta-corriente-party-guard` (#450); **el MAX vivo en prod se verifica antes de nombrar el archivo**, como en toda la saga):
- `public.suppliers`: `+ tax_id text`, `+ iva_condition text` (CHECK contra el mismo vocabulario que `clients`), `+ legal_name text`, `+ email text`, `+ phone text`. Índice de listado sobre `(account_id) WHERE deleted_at IS NULL`. `company_id` pasa a nullable (`DROP NOT NULL`, guardado y drift-tolerant, mismo patrón que `20260702000002`/`20260804000006`) — hallazgo del apply de fase B: seguía siendo `NOT NULL` legacy con FK a `companies(id)` desde antes de `v20-tenancy-cleanup`, y ningún INSERT lo había ejercitado hasta el ABM de proveedores de este change. Sin este fix, `SupplierRepository.create()` fallaba con `23502` en cuentas sin mapeo `company_users`/`account_members`.
- `rpc_create_purchase_operation`: firma 8 → **9 args** (`+ p_supplier_id`). ⇒ `DROP FUNCTION IF EXISTS` con la firma exacta vieja + `CREATE OR REPLACE` partiendo del **`pg_get_functiondef` de la función VIVA**, + `REVOKE ALL FROM PUBLIC` + `REVOKE EXECUTE FROM anon` + `GRANT EXECUTE TO authenticated` reafirmados en el mismo archivo (gotcha `ALTER DEFAULT PRIVILEGES`, gate `test_function_acl_gate.sql`).
- `rpc_atomic_update_purchase_operation`: firma 8 → **12 args** (`+ p_supplier_id`, `+ p_supplier_provided`, `+ p_cost_center_id`, `+ p_cost_center_provided` — la OQ-5 se implementó por su opción recomendada A), mismo tratamiento.
- Gates SQL RED→GREEN dentro de la migración (patrón de la saga).
- `.github/workflows/KPI_Validation.yml`: la migración se agrega como **último eslabón de la cadena de reapply** del paso "Verify G1/G4 migrations are idempotent on reapply" — cambia dos firmas, así que el reapply de `20261002000001` y anteriores crearía overloads fantasma (mecanismo 42725 ya documentado cinco veces en ese paso).

**Backend** (3 capas, JWT-passthrough, sin `service_role`):
- Nuevos: `backend/routers/suppliers.py`, `backend/services/suppliers.py`, `backend/schemas/suppliers.py`.
- Extendido: `backend/repositories/supplier_repository.py` (`create`, `update`, `count_by_org`).
- `backend/schemas/purchases.py`: `supplier_id` en `PurchaseOperationIn` y en `PurchaseOperationUpdateIn` (tri-estado); `supplier_id` + `supplier_name` en `PurchaseItemOut`.
- `backend/repositories/purchase_repository.py` + `backend/services/purchases.py` + `backend/routers/purchases.py`: passthrough del proveedor y `supplier_provided` por `model_fields_set`; `LEFT JOIN suppliers` en el listado para el badge.
- `backend/core/errors.py`: mapeo de `P0B10` → 403 (**gap real preexistente**, hoy 500) con su test.
- `backend/main.py`: registro del router nuevo.

**Frontend**:
- Nueva ruta `frontend/app/(dashboard)/proveedores/page.tsx`.
- `frontend/components/app-sidebar.tsx`: entrada "Proveedores" en el grupo Catálogo.
- Nuevos: `frontend/components/forms/supplier-form.tsx`, `frontend/hooks/data/use-suppliers.ts`; `Supplier` en `frontend/lib/types.ts`; `suppliers` en `frontend/lib/query-keys.ts`.
- `frontend/components/forms/purchase-form.tsx`: selector de proveedor + alta inline + bloque de cuenta corriente (saldo actual / proyectado) cuando el `kind` es `credit`; guard de UI "elegí un proveedor".
- `frontend/components/compras/purchase-operations-list.tsx`: badge de proveedor.
- `frontend/lib/group-operations.ts`: `supplierId`/`supplierName` en `PurchaseOperation`.
- `frontend/app/(dashboard)/proveedores/[id]/cuenta/page.tsx`: "volver" a `/proveedores` (hoy `/compras`).

**Fuera de alcance** (declarado, no olvidado):
- **Backfill de las compras históricas sin proveedor** — no se hace (OQ-2): exigiría inventar a quién se le compró y postearía cargos con fecha de hoy sobre cuentas corrientes que no existen.
- **Detalle de proveedor** `/proveedores/[id]` con historial de compras (espejo de `/clientes/[id]`) — OQ-6; el read-model de compras por proveedor no existe todavía.
- **`purchase_orders`** / recepción de mercadería: la compra sigue siendo un documento plano.
- **Emparejamiento cliente↔proveedor por CUIT** (`counterpartRef` de DEC-18): fuera de alcance.
- **Asiento contable**: no se toca ninguna rama de `_journal_post_from_event`.

**No se tocan**: `_pay_register_party_charge`, `_pay_reverse_party_charge`, los helpers `c30_*`, `rpc_delete_purchase_operation`, `rpc_register_supplier_charge`, `rpc_register_payment_made`, ni ninguna RPC de venta / caja / banco.
