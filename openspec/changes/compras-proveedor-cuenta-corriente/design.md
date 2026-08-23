## Context

### Lo que ya existe (verificado en el código, no supuesto)

| Pieza | Estado hoy | Dónde |
|---|---|---|
| Tablas de cta cte de proveedor | ✅ Completas, **0 filas** | `20260720000001_c30_customer_supplier_accounts.sql` |
| Helpers `c30_get_or_create_supplier_account` / `c30_register_supplier_account_movement` | ✅ Vivos, REVOKE de PUBLIC | idem |
| RPCs `rpc_register_payment_made` / `rpc_register_supplier_charge` | ✅ Vivas, **0 llamadas reales** | idem + `20260804000007` |
| Helper compartido `_pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid)` | ✅ **La rama `supplier` está escrita** y emite `SupplierAccountCharged` — sin ningún llamador con `'supplier'` | `20261001000001_pagos_cableados_restantes.sql:58` |
| Reversión `_pay_reverse_party_charge` | ✅ Con rama `supplier` | `20261005000001_delete_guard_ledgers.sql:96` |
| Compensación por borrado de compra | ✅ `rpc_delete_purchase_operation` ya revierte el cargo del proveedor (guard `P0425`) | `20261005000001:1383` |
| Inmutabilidad de la compra con cargo | ✅ Guard `P0423` sobre `supplier_account_movements` | `20261002000001:2311` |
| Contabilidad de compra a crédito | ✅ `PurchaseCreated` con `kind` real → `2100 Proveedores` | `20261001000001` (D7) + `journal-entry` |
| Backend de cta cte de proveedor (3 capas) | ✅ Router + service + repo + schemas | `backend/routers/supplier_accounts.py` etc. |
| Pantalla `/proveedores/[id]/cuenta` | ✅ Saldo + historial + "Registrar pago" — **inalcanzable** (no hay `/proveedores`, el "volver" apunta a `/compras`) | `frontend/app/(dashboard)/proveedores/[id]/cuenta/page.tsx` |
| Límite de proveedores por plan | ✅ Trigger `trg_guard_supplier_plan_limit`, ERRCODE `P0B10` (20/100/300/1000) | `20260817000001_billing_pro_trial_schema.sql:640` |
| Aviso de excedente de plan | ✅ `_sweep_plan_limit_exceeded` ya barre `suppliers` | idem |
| Soft delete de `suppliers` | ✅ Columnas + allowlist `SOFT_DELETE_TABLES` | `20260811000001` + `backend/repositories/base.py:13` |
| `SupplierRepository` | ⚠️ Existe con `list_by_org` / `get_by_id` — **ningún service ni router lo consume**, solo sus propios tests | `backend/repositories/supplier_repository.py` |
| RLS de `suppliers` por `account_id` | ✅ 4 políticas (`select`/`insert`/`update`/`delete`) | `20260613000004_v20_suppliers_rls.sql` |

### Lo que falta (el agujero real)

- **`public.suppliers` tiene 5 columnas útiles**: `id`, `account_id`, `company_id`, `name`, `created_at` (+ `deleted_at`/`deleted_by`). Sin identidad fiscal, sin contacto. La tabla nunca tuvo un `CREATE TABLE` versionado en `supabase/migrations/` — solo el stub de CI (`20260517000000_ci_compat_stubs.sql:74`); su forma real vino del schema pre-migraciones.
- **Cero superficie**: sin `/proveedores`, sin entrada de sidebar, sin endpoint de alta.
- **`rpc_create_purchase_operation` no recibe proveedor**: firma viva `(text, date, text, jsonb, uuid, uuid, uuid, uuid)` — `p_idempotency_key, p_date, p_description, p_items, p_branch_id, p_cost_center_id, p_payment_method_id, p_bank_account_id`. `purchases.supplier_id` se inserta implícitamente NULL en las dos ramas del INSERT.
- **El cargo a crédito no se postea**: la RPC calcula `v_kind` y lo usa para el banco (crudo) y para el evento (`COALESCE(v_kind,'credit')`), pero no hay bloque `IF v_kind = 'credit'`.

### Inconsistencia encontrada entre KB y código

`knowledge-base/04_modelo_de_datos.md` (H5) y `modelo-dominio-aliadata-v2.md` (§H5) afirman *"`suppliers` sí tiene `tax_id`"*. **Es falso para `public.suppliers`**: la tabla que tiene `cuit`/`address`/`email`/`phone` es `invoice_suppliers`, el directorio del módulo OCR, keyed por `user_id` y sin relación con `suppliers`. La afirmación de la KB describe la tabla equivocada. Este change cierra el gap real en `public.suppliers` y deja la KB alineada.

> **Corrección (apply, 2026-08-23)**: este párrafo estaba equivocado. La task 2.2 (fase A) verificó contra prod, read-only, que `public.suppliers` **ya tenía** `tax_id`/`email`/`phone` — la afirmación original de la KB era correcta, no describía la tabla equivocada. `invoice_suppliers` existe y es en efecto una tabla distinta (OCR, keyed por `user_id`), pero eso no invalidaba lo que decía la KB sobre `suppliers`. Lo que este change agrega de verdad es `iva_condition`+`legal_name` (D2) y `company_id` nullable (hallazgo de fase B, ver nota al final de D2). La KB (`knowledge-base/04_modelo_de_datos.md` H5 + nueva sección `suppliers`, y `modelo-dominio-aliadata-v2.md` H5) quedó corregida en consecuencia por la task 15.1.

### Restricciones

- **Governance MEDIUM**: se toca dinero sobre helpers que ya están en producción (`_pay_register_party_charge`) y sobre la RPC de alta de compra, que es el hot path de un módulo con tráfico real (104 compras en 30 días). Implementación por pasos, con checkpoints explícitos (ver §Migration Plan).
- **Regla de la saga**: toda reescritura de RPC parte del `pg_get_functiondef` de la función **VIVA en prod**, nunca de la copia del último archivo de migración (lección del bloque `credit` de C-30 borrado en silencio, PR #421).
- **Migraciones idempotentes**: Supabase GitHub auto-aplica; el paso "Verify G1/G4 migrations are idempotent on reapply" de `KPI_Validation.yml` las reaplica en cadena.
- **Strict TDD**: RED → GREEN → TRIANGULATE → REFACTOR por task, con safety net de la suite existente antes de tocar archivos.

## Goals / Non-Goals

**Goals:**

1. El microemprendedor puede **dar de alta, editar y dar de baja proveedores** desde una pantalla propia, con la misma identidad fiscal que ya carga para clientes.
2. Al cargar una compra puede **elegir a qué proveedor** se la compró (y crear uno en el acto sin salir del form).
3. Una compra imputada a una forma de pago de `kind = 'credit'` **carga la cuenta corriente del proveedor** en la misma transacción, y ese saldo aparece en la pantalla de cuenta corriente que ya existe, con su historial y su "Registrar pago".
4. Todo eso **reutilizando** lo que ya está construido: el helper de cargo, los helpers C-30, el trigger de límite de plan, el soft delete, la compensación por borrado, el guard de inmutabilidad y el asiento contable. La superficie de código nueva se concentra en el maestro y en su UI.
5. Las tres piezas ya escritas que nunca se ejercitaron (inmutabilidad, compensación, asiento) quedan **cubiertas por tests** en su camino real.

**Non-Goals:**

- **Backfill de las 38 compras históricas** sin proveedor (OQ-2).
- **Detalle de proveedor** `/proveedores/[id]` con historial de compras (OQ-6).
- `purchase_orders`, recepción de mercadería, remitos, o cualquier documento de compra que no sea el plano actual.
- **`counterpartRef`** (emparejar cliente y proveedor con el mismo CUIT, DEC-18).
- **Importación CSV de proveedores** (el equivalente de `ClientImportDialog`).
- Cambios en el journal contable, en caja, en banco, o en cualquier RPC de venta.
- **Opt-in de caja en la compra**: sigue sin existir (recorte explícito de `pagos-cableados-restantes`, OQ-E) y este change no lo introduce.

## Decisions

### D1 — El ABM nace en el backend Python de 3 capas, extendiendo el repositorio que ya existe

`SupplierRepository` ya está escrito, ya filtra por `deleted_at IS NULL` y ya hereda `soft_delete` de `BaseRepository`; lo único que le falta son `create`, `update` y `count_by_org`. Se agregan ahí, y se crean `services/suppliers.py` + `routers/suppliers.py` + `schemas/suppliers.py` calcados de `clients`.

*Alternativa descartada*: alta por Supabase client directo desde el frontend (como es hoy la única vía posible). El comentario de `fn_guard_supplier_plan_limit` lo documenta como una **desviación** conocida (*"suppliers no tiene endpoint de creación en el backend Python — el alta es un INSERT directo vía Supabase client"*), no como el diseño deseado. Con endpoint, la validación de payload (Pydantic v2), el `require_role` y el mapeo RFC 7807 quedan donde el resto del sistema los tiene.

### D2 — Identidad fiscal del proveedor = espejo exacto de `clients`

`suppliers` suma `tax_id`, `iva_condition`, `legal_name`, `email`, `phone` — mismos nombres, mismos tipos, mismo vocabulario de condición IVA (`responsable_inscripto` / `monotributista` / `exento` / `consumidor_final`), y el frontend reutiliza `frontend/lib/cuit-utils.ts` sin duplicar la validación de dígito verificador.

RN-96 lo pide explícitamente (*"`FiscalIdentity` es un Value Object compartido entre Customer y Supplier — misma validación, cero duplicación"*) y DEC-18 lo confirma. Divergir en los nombres de columna haría imposible extraer el VO a tabla común el día que el solapamiento supere el 20% (el trigger de revisión que la propia RN-96 fija).

*Alternativa descartada*: solo `tax_id` + contacto, sin `iva_condition`/`legal_name`. Ahorra dos columnas nullable y rompe la simetría que la regla de negocio pide por escrito. Ver **OQ-3**.

**Hallazgo del apply (fase B)**: además de las cinco columnas nuevas, `suppliers.company_id` seguía siendo `NOT NULL` legacy (FK a `companies(id)`, de antes de `v20-tenancy-cleanup`) — `clients.company_id` ya es nullable desde `20260613000003`, pero nadie había ejercitado un INSERT real en `suppliers` hasta el ABM de este change, así que el gap nunca se manifestó. Se agregó un `ALTER TABLE ... DROP NOT NULL` guardado (drift-tolerant, mismo patrón que `20260702000002`/`20260804000006`) al STEP 1 de la migración, sin tocar el FK ni backfillear. `SupplierRepository.create()` es ahora un mirror exacto de `ClientRepository.create()` — sin `company_id` en el INSERT.

> **Corrección (apply, 2026-08-23, task 15.1)**: el primer párrafo de esta sección dice *"`suppliers` suma `tax_id`, `iva_condition`, `legal_name`, `email`, `phone`"* como si las cinco fueran nuevas. No lo son: la task 2.2 (fase A) verificó contra prod que `tax_id`/`email`/`phone` **ya existían** en `public.suppliers` antes de este change. Lo que efectivamente agrega este change es `iva_condition` + `legal_name` (el CHECK y el VO compartido siguen siendo correctos, RN-96) y, como documenta el párrafo de arriba, `company_id` nullable. Ver `knowledge-base/04_modelo_de_datos.md` §`suppliers` para las columnas finales documentadas.

### D3 — El límite por plan se delega en el trigger; el service NO cuenta

`trg_guard_supplier_plan_limit` ya es, en palabras de su propio `COMMENT`, *"la única capa que ve todos los inserts"*. El service de proveedores **no** replica el conteo: deja que el trigger falle y mapea `P0B10` → **403** en `backend/core/errors.py`, donde hoy no está mapeado y saldría 500.

Esto es deliberadamente **distinto** de `create_client`, que sí pre-cuenta contra `PlanLimitsRepository` antes de insertar. Esa duplicación es la deuda, no el modelo: dos definiciones del mismo límite que pueden divergir. Se registra como deuda menor (fuera de alcance) en vez de propagarla.

El frontend sigue mostrando el banner y deshabilitando "Nuevo proveedor" con `count >= limits.maxSuppliers` — eso es afordancia, no enforcement, y `usePlanLimits` ya expone `maxSuppliers`.

*Alternativa descartada*: espejar `create_client`. Ver **OQ-4**.

### D4 — El proveedor viaja como parámetro trailing de la RPC, no en el JSON de ítems

`p_supplier_id uuid DEFAULT NULL` se agrega **al final** de la firma de `rpc_create_purchase_operation` (8 → 9 args), exactamente como se agregaron `p_cost_center_id`, `p_payment_method_id` y `p_bank_account_id` antes. Es un atributo **de operación**, no de línea: se propaga a todas las filas de `purchases`, igual que el centro de costo y la forma de pago.

Persistir en **las dos ramas** del INSERT (línea con producto y línea sin producto) es un detalle que ya se olvidó una vez en esta RPC — el bloque `ELSE` tiene su propio INSERT con la lista de columnas repetida.

*Alternativa descartada*: `supplier_id` por ítem dentro de `p_items`. No hay caso de uso (una compra es a un proveedor) y multiplicaría por N el cargo de cuenta corriente.

### D5 — El disparo del cargo usa `v_kind` CRUDO, nunca el `COALESCE(..., 'credit')`

Dentro de `rpc_create_purchase_operation` conviven dos lecturas del mismo `v_kind`:

- el **evento** usa `COALESCE(v_kind, 'credit')` — decisión de `pagos-cableados-restantes` (D7) para preservar el asiento histórico de las compras sin forma de pago;
- el **movimiento bancario** usa `v_kind` crudo — decisión de `pos-banco-movimientos` (D5), con el comentario explícito *"v_kind CRUDO (NO el COALESCE...): sin payment_method_id imputado, v_kind es NULL y el helper correctamente no escribe nada"*.

El cargo de cuenta corriente sigue **la segunda**: `IF v_kind = 'credit' THEN ...`. Usar el COALESCE haría que toda compra sin forma de pago imputada —el 100% de las 38 históricas y cualquier alta futura donde el usuario no elija método— cargue una cuenta corriente en silencio. Esa es exactamente la clase de regresión invisible que la saga viene pagando.

**Consecuencia observable a documentar en la UI**: "sin forma de pago" ≠ "a crédito" para la cuenta corriente, aunque sí lo sea para el asiento contable. La divergencia es preexistente y sancionada por la spec `payment-method` (*"Una compra sin forma de pago imputada SHALL propagarse como `credit`"* — solo para el evento contable).

### D6 — La compra a crédito exige proveedor, con el mismo error que la venta a crédito exige cliente

`credit_requires_supplier` con `ERRCODE = 'P0400'` — **no se acuña un ERRCODE nuevo**. El precedente vivo del lado venta es `credit_requires_client ... USING ERRCODE = 'P0400'` (`20261004000001:929`, y antes `20260929000001:195`), ya mapeado a 400 en `_BUSINESS_ERRCODE_STATUS`. Un `P0427` nuevo para el caso simétrico sería una divergencia gratuita.

La validación va **antes** de tocar stock, como en la venta. El frontend además impide llegar a ese estado (bloque de UI "elegí un proveedor", molde del bloque de venta a crédito) — pero el servidor no confía en la UI.

Igual criterio para la pertenencia: `p_supplier_id` que no exista, no pertenezca a `v_account_id` o tenga `deleted_at IS NOT NULL` → `P0404` (ya mapeado a 404), no un código nuevo.

### D7 — La edición reimputa el proveedor por contrato tri-estado

`rpc_atomic_update_purchase_operation` suma `p_supplier_id uuid DEFAULT NULL` + `p_supplier_provided boolean DEFAULT false` (8 → 10 args; **12 en la implementación final**, porque la OQ-5 se resolvió por su opción recomendada y `cost_center_id` entró al mismo contrato — ver OQ-5), y el router lo resuelve con `"supplier_id" in payload.model_fields_set` — **nunca** con `payload.supplier_id is None`. Es el mismo contrato ya usado para `payment_method_id` (D5 de `metodos-pago-operaciones`) y `branch_id` (D3 de `edicion-preserva-contexto`): no informado = preservar, informado con `null` = desimputar, informado con uuid = reimputar.

Esto **cierra la OQ-1 de `edicion-preserva-contexto`**, que dejó `supplier_id` "preservado pero no parámetro" precisamente porque *"el form de edición de compra no tiene selector para ninguno de los dos hoy"*. Ahora lo tiene.

La edición **no** postea ni revierte cargos de cuenta corriente: una compra con cargo posteado ya es inmutable (`P0423`), así que el único caso editable es el de una compra sin cargo — y ahí reimputar el proveedor es solo cambiar una FK. Esta invariante hay que **asertarla con un test**, no asumirla.

*Nota de alcance*: `cost_center_id` sufre exactamente el mismo problema (su `CostCenterSelect` está montado en el form de edición y no tiene parámetro en la RPC — UI que miente, documentada en el archive de `edicion-preserva-contexto`). Ver **OQ-5**.

### D8 — Cero lógica nueva de cuenta corriente: el escritor sigue siendo el helper compartido

El bloque nuevo de la RPC es literalmente:

```
IF v_kind = 'credit' THEN
  PERFORM public._pay_register_party_charge(
    v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id
  );
END IF;
```

Mismo helper, mismo orden de argumentos y mismo punto del flujo (después del loop de ítems, junto al movimiento bancario) que la venta del formulario. La spec `party-account-charge` ya lo exige: *"La incorporación de un camino de compra a crédito NO SHALL requerir un helper nuevo"*. Este change es la prueba de esa afirmación.

`reference_id` y `operation_id` son ambos `v_new_op_id`: en compras no existe el equivalente de `sales_orders`, así que no hay la doble convención de referencia de la venta — el guard `P0423` y `rpc_delete_purchase_operation` ya asumen exactamente eso (*"reference_id del cargo apunta directo a purchases.operation_id, sin la complejidad de doble referencia de la venta"*).

### D9 — Superficie: `/proveedores` cuelga de **Catálogo**, no de Compras

| Capacidad para el usuario | Pantalla / ruta | Cómo se llega |
|---|---|---|
| Alta / edición / baja de proveedores, con límite de plan visible | **`/proveedores`** (nueva) | **Sidebar → grupo Catálogo → "Proveedores"** (ícono `Truck`), inmediatamente debajo de "Clientes" |
| Saldo, historial y registro de pago al proveedor | `/proveedores/[id]/cuenta` (ya existe) | Acción de fila "Cuenta corriente" en `/proveedores`; su botón "volver" pasa de `/compras` a `/proveedores` |
| Imputar el proveedor de una compra | `/compras` → diálogo `PurchaseForm` | Selector "Proveedor" en el header del form, con "Nuevo proveedor" inline |
| Entender el efecto antes de confirmar | mismo form | Bloque de cuenta corriente con saldo actual y proyectado cuando el `kind` es `credit`; aviso "elegí un proveedor" si falta |
| Ver a qué proveedor quedó imputada una compra | `/compras` (listado de operaciones) | Badge de proveedor en la fila |

Va en **Catálogo** (junto a Productos / Stock / Clientes / Sucursales) porque un proveedor es un **maestro**, no una operación — el usuario lo piensa como la contraparte de "Clientes". La alternativa (colgarlo de Operaciones junto a Compras) rompería esa simetría y dejaría "Clientes" solo en Catálogo.

**Estética**: tokens semánticos y componentes base ya existentes (`Button`, `Input`, `Dialog`, `PaginationBar`, `Select`) — el listado es el molde de `/clientes` con menos columnas. Verificación obligatoria en **desktop y mobile** y en **tema claro y oscuro** antes del merge.

### D10 — El selector de proveedor se implementa con las piezas del selector de cliente, no con un componente nuevo

El form de venta ya resuelve el problema idéntico: combobox buscable + "Nuevo cliente" inline que crea y preselecciona. Se replica esa mecánica en `PurchaseForm` con `useSuppliers()`; el hook `use-suppliers.ts` es el calco de `use-clients.ts` (mismo `pythonClient`, mismo patrón de mappers snake_case → camelCase, misma invalidación por `queryKeys`).

*Alternativa descartada*: extraer un `PartySelect` genérico que sirva a clientes y proveedores. Son **dos** usos — la Regla de Tres dice que todavía no. Se anota como candidato si aparece un tercero.

### D11 — El asiento contable no se toca

`PurchaseCreated` ya transporta el `kind` real desde `pagos-cableados-restantes`, y `_journal_post_from_event` ya acredita `2100 Proveedores` cuando ese kind es `credit`. Una compra a crédito con proveedor imputado producirá, sin cambio alguno de código contable, el mismo asiento que produce hoy — solo que ahora además existirá el ledger operativo que lo respalda. Se cubre con un test de no-regresión, no con código.

### D12 — Migración: dos firmas cambian ⇒ DROP+CREATE, REVOKE en el mismo archivo, y reapply final en CI

- `DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid);` (firma exacta vieja) antes del `CREATE OR REPLACE` con 9 args. Idem `rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean)` → **12 args** (`p_supplier_id`/`p_supplier_provided` + `p_cost_center_id`/`p_cost_center_provided`, OQ-5 opción A).
- Tras el `DROP+CREATE`, los ACLs se pierden ⇒ `REVOKE ALL ... FROM PUBLIC` + `REVOKE EXECUTE ... FROM anon` (explícito: el proyecto tiene `ALTER DEFAULT PRIVILEGES` que otorga EXECUTE a `anon` en toda función nueva) + `GRANT EXECUTE ... TO authenticated`, **en el mismo archivo**. Lo verifica `test_function_acl_gate.sql`.
- `KPI_Validation.yml`: se agrega `20261009000001` como **último** `psql -f` de la cadena de reapply. Sin eso, el reapply de `20261002000001` recrea las firmas de 8 args como overloads fantasma y toda llamada posicional falla con 42725 ("function is not unique") — mecanismo ya documentado cinco veces en ese paso.
- Todo el DDL de tabla con `IF NOT EXISTS`; el CHECK de `iva_condition` con `NOT VALID` (0 filas hoy, pero el patrón es el de la saga) y `DROP CONSTRAINT IF EXISTS` antes de crearlo.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **Se reescriben dos RPCs del hot path de compras (104 compras/30d)** a partir de una copia desactualizada y se pierde silenciosamente un bloque (lo que pasó con el `credit` de C-30). | Regla dura de la saga: partir del `pg_get_functiondef` de la función **VIVA en prod**, diffear contra el cuerpo del último archivo de migración y **enumerar en el PR** cada bloque preservado (flag `sale_items_rpc_v2`, snapshots, `purchase_items`, `branch_stock`, `stock_movements`, banco, evento). Task explícita. |
| **El cargo se dispara donde no debe** y las compras sin forma de pago empiezan a endeudar proveedores. | D5: `v_kind` crudo. Test de triangulación con las tres formas — `credit` (carga), `cash` (no carga), sin método (no carga) — como caso RED antes de escribir el bloque. |
| **Cambio de firma ⇒ overload fantasma 42725** en el reapply de CI. | D12: reapply final en `KPI_Validation.yml` + gate anti-overload dentro de la migración (`SELECT count(*) FROM pg_proc WHERE proname = ...` = 1). |
| **`DROP FUNCTION` + `CREATE` resetea ACLs** y `anon` queda con EXECUTE por `ALTER DEFAULT PRIVILEGES`. | REVOKE explícito de `PUBLIC` **y** de `anon` en el mismo archivo; `test_function_acl_gate.sql` corre en cada PR. |
| **La compra a crédito se vuelve inmutable** (`P0423`) apenas se postea el cargo, y el usuario descubre que no puede corregir un error de tipeo. Es el escenario que produjo el cargo fantasma de $75.150 en la venta. | El camino de corrección existe y es atómico: borrar la operación (`rpc_delete_purchase_operation` compensa cta cte + banco + stock y emite `PurchaseDeleted`) y volver a cargarla. El diálogo de borrado ya enumera la compensación (`operation-delete-compensation`). Se agrega copy explícito en el aviso de bloqueo del listado de compras. **Checkpoint de governance**: mostrárselo al PO antes del merge. |
| **La UI dice "sin forma de pago" y el asiento dice "a crédito"** (divergencia D5 vs evento). | Es preexistente y está en la spec. El texto de apoyo del selector nombra el efecto de cada elección (requirement vigente de `payment-method`); la ausencia de forma de pago no promete ni niega cuenta corriente. |
| **Cinco columnas nuevas en un maestro sin `CREATE TABLE` versionado** (`suppliers` viene del schema pre-migraciones). | Todo `ADD COLUMN IF NOT EXISTS` + nullable + sin default: aditivo puro, sin reescritura de tabla, sin backfill. Rollback = dejar de escribir (no se dropea en prod). |
| **La KB afirma algo falso** sobre `suppliers.tax_id` y alguien diseña contra eso. | Se corrige `knowledge-base/04_modelo_de_datos.md` (H5) en el mismo change, señalando que la tabla con CUIT es `invoice_suppliers` (OCR). |
| **Doble fuente del límite de plan** si alguien copia el pre-conteo de `create_client`. | D3: el service no cuenta. Comentario en el código apuntando al trigger como única fuente + test que asserta el 403 vía `P0B10`. |

## Migration Plan

Un solo PR de implementación (más el de archive), con checkpoints de governance MEDIUM en el medio.

1. **Safety net**: correr la suite backend completa y los tests de compras del frontend; registrar el baseline (`N/N passing`). Cualquier fallo previo se reporta, no se arregla acá.
2. **Verificar el MAX de migraciones vivo en prod** antes de nombrar el archivo (`20261009000001` es la expectativa: el MAX local es `20261007000001` — `cuentas-billetera-tipo`, #447 — y `20261008000001` está reservado por `cuenta-corriente-party-guard`, #450, todavía sin aplicar).
3. **Capturar el `pg_get_functiondef` vivo** de `rpc_create_purchase_operation` y `rpc_atomic_update_purchase_operation` y diffearlo contra el último archivo de migración. *(Checkpoint 1: si difieren, se reporta antes de seguir.)*
4. **DB** — migración con: columnas de `suppliers`, las dos RPCs, ACLs, gates. Aplicar local, correr los gates, verificar idempotencia reaplicando el archivo dos veces.
5. **Backend** — repos/services/routers/schemas de proveedores; passthrough de `supplier_id` en compras; mapeo de `P0B10`. TDD por task.
6. **Frontend** — hook, tipos, query keys, form de proveedor, página `/proveedores`, sidebar, selector + bloque de crédito en el form de compra, badge en el listado.
7. **Verificación visual** desktop + mobile, claro + oscuro.
8. *(Checkpoint 2)*: demo al PO — crear un proveedor, cargar una compra a crédito, ver el saldo en `/proveedores/[id]/cuenta`, intentar editarla (bloqueo `P0423`) y borrarla (compensación).
9. **CI**: `KPI_Validation.yml` con el reapply final; verde en validate-kpis + vitest + pytest + playwright + Vercel.
10. **Merge** ⇒ build + deploy + migración automáticos. Verificar post-merge que el MAX en prod es `20261009000001`.

**Coordinación con `cuenta-corriente-party-guard` (activo, 0/64, propuesto 2026-08-23 por otra sesión — #448/#450)**: reservó `20261008000001` y endurece `c30_get_or_create_supplier_account` (guard de pertenencia `P0404`) + revoca `authenticated` en `_pay_register_party_charge`. No hay conflicto de archivos (su design lo confirma) y el revoke no afecta a nuestra RPC (`PERFORM` como definer). Dos reglas: (a) nuestra migración es `20261009000001`, numerada **después** de la suya aunque la suya no esté aplicada — si la nuestra mergea primero, el apply de la suya debe verificar que `db push`/la integración de GitHub no saltee una versión menor que el MAX (usar `--include-all` si hace falta); (b) D6 mantiene el chequeo de pertenencia del proveedor **dentro** de `rpc_create_purchase_operation` (defensa en profundidad, mismo criterio que party-guard §2), así el camino nuevo no depende del orden de merge. Al archivar, el segundo de los dos rebasea sus deltas de `supplier-account` y `party-account-charge` sobre la spec ya sincronizada.

**SPEC-07 (review A) — al archivar hay que reescribir una frase de `party-account-charge`.** El delta de `cuenta-corriente-party-guard` (`openspec/changes/cuenta-corriente-party-guard/specs/party-account-charge/spec.md`, requirement del par `(cuenta, parte)` coherente) justifica poner el guard en la resolución de la cuenta corriente con esta afirmación: *"El helper NO SHALL confiar en que su llamador lo haya verificado —los caminos de alta de venta y de compra reciben el identificador de la parte del payload del cliente y no lo validan—"*. Desde este change esa frase es **falsa para la compra**: `rpc_create_purchase_operation` valida pertenencia y `deleted_at` del proveedor antes de tocar nada (D6, defensa en profundidad, deliberadamente redundante con el party-guard). El que archive **segundo** SHALL reescribirla para que diga que el camino de compra **sí** valida como defensa en profundidad y que la verificación canónica —la que cubre a todos los llamadores, presentes y futuros— es la del party-guard en `c30_get_or_create_*_account`. La conclusión normativa (dónde vive el guard obligatorio) no cambia; lo que cambia es el hecho que la sostiene, y una spec que afirma un hecho falso induce al próximo lector a "arreglar" una validación que ya existe.

**Rollback**: la migración es aditiva en datos (columnas nullable, sin backfill). Revertir el comportamiento = reaplicar los cuerpos previos de las dos RPCs (el `p_supplier_id` queda como parámetro ignorado) sin dropear columnas ni tocar `supplier_account_movements`. Un cargo ya posteado se revierte por su camino normal (borrado de la operación → `_pay_reverse_party_charge`), nunca con DELETE.

## Open Questions

> Governance **MEDIUM**. Cada OQ lleva la recomendación del design; si el PO no responde, se implementa la recomendada y queda firmada en el archive.

### OQ-1 — ¿La compra a crédito **sin proveedor** se bloquea?

- **A) Bloquear** con `credit_requires_supplier` (`P0400`), antes de tocar stock, y el form impide llegar a ese estado. → **RECOMENDADA**
- B) Permitir: la compra se registra, no carga nada, la forma de pago queda como etiqueta.

*Por qué A*: la spec `payment-method` ya lo declara por escrito (*"cliente en venta, proveedor en compra"*), es exactamente lo que hace el POS con la venta a crédito, y B produce deuda sin acreedor — un pasivo que la app muestra en el asiento (`2100 Proveedores`) y no puede mostrar en ninguna cuenta corriente.

### OQ-2 — ¿Qué se hace con las compras históricas sin proveedor?

- **A) Nada.** Quedan con `supplier_id NULL`, sin cargo, y el listado las muestra como "Sin proveedor". El PO puede reimputar el proveedor editando la operación (D7), mientras no tenga cargo/banco posteado. → **RECOMENDADA**
- B) Backfill firmado, después de que el PO cree los proveedores y asigne cada compra a mano.

*Por qué A*: hoy hay **0 proveedores** en prod, así que no hay a quién imputar sin inventarlo. Y un backfill de cargos escribiría movimientos append-only con fecha de hoy por compras de junio: un saldo correcto en total y falso en el tiempo. Si el PO quiere el histórico, B es un change aparte con datos que hoy no existen.

### OQ-3 — ¿Cuál es el mínimo de identidad fiscal del proveedor?

- **A) Espejo completo de `clients`**: `tax_id`, `iva_condition`, `legal_name`, `email`, `phone`. → **RECOMENDADA**
- B) Solo `tax_id` + `email` + `phone`.
- C) Solo `name` (status quo).

*Por qué A*: RN-96 y DEC-18 definen `FiscalIdentity` como VO **compartido**; divergir en columnas hoy encarece la extracción a tabla común mañana. Son 5 columnas nullable sobre una tabla vacía — costo cero, y habilita que la factura de compra futura (percepciones, `v25-tax-perceptions`) tenga de dónde leer la condición del proveedor.

### OQ-4 — Límite de proveedores por plan: ¿pre-chequeo en el service o solo el trigger?

- **A) Solo el trigger** `trg_guard_supplier_plan_limit` + mapeo de `P0B10` → 403. → **RECOMENDADA**
- B) Espejar `create_client`: pre-contar en el service **y** dejar el trigger.

*Por qué A*: una sola definición del límite. El pre-conteo de `create_client` es la duplicación, no el patrón — y el trigger es, por diseño, la capa que ve **todos** los inserts (incluidos los que no pasan por el backend). El costo de A es que el 403 llega desde una excepción de Postgres en vez de un `if`; el mapeo de `P0B10` lo resuelve y hay que hacerlo igual (hoy ese error saldría 500 desde cualquier camino).

### OQ-5 — ¿`cost_center_id` entra al contrato tri-estado de edición junto con `supplier_id`?

- **A) Sí, en este change.** Es la misma OQ-1 de `edicion-preserva-contexto`, y hoy el `CostCenterSelect` **ya está montado** en el form de edición de compra sin ningún efecto: el usuario cambia el centro de costo, guarda, y no pasa nada. → **RECOMENDADA**
- B) No: queda para un change de limpieza propio.

*Por qué A*: son ~10 líneas (un parámetro + un `provided` + el passthrough) sobre RPCs que este change ya está reescribiendo de todos modos, y elimina una UI que miente **hoy en producción**. Si el PO elige B, se quitan las tasks marcadas `[OQ-5]` y se desmonta el `CostCenterSelect` en modo edición para que al menos deje de mentir.

### OQ-6 — ¿`/proveedores` necesita pantalla de detalle?

- **A) No**: listado + acceso directo a la cuenta corriente. → **RECOMENDADA**
- B) Sí: `/proveedores/[id]` espejo de `/clientes/[id]`, con historial de compras y agregados de actividad.

*Por qué A*: el detalle de cliente existe porque hay un read-model detrás (`client-activity`, `client-purchase-history`, con sus RPCs y agregados). El equivalente de compras por proveedor **no existe** — construirlo es un change propio, y hacerlo acá triplicaría el alcance para 0 proveedores en producción. Se registra `historial-compras-por-proveedor` como candidato siguiente.
