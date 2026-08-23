# supplier-account

> Synced from change `v21-customer-supplier-accounts` (C-30) — 2026-06-20

## Purpose

Cuentas corrientes de proveedores: espejo simétrico de `customer-account` en la capa de proveedores. `SupplierAccount` materializa cuánto se le debe al proveedor; integra ledger append-only `supplier_account_movements` para compras a crédito manuales, pagos idempotentes y ajustes. La integración con el flujo de compras de stock es manual (OQ-3 opción B): `rpc_create_purchase_operation` no toca la cta cte automáticamente.

## Requirements

### Requirement: Agregado SupplierAccount con saldo materializado
El sistema SHALL proveer un agregado `SupplierAccount` (tabla `supplier_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `supplier_id` (FK→`suppliers`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado: lo que se le debe al proveedor), `created_by`, `created_at`. SHALL existir a lo sumo **una** `SupplierAccount` por `(account_id, supplier_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER`; la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

#### Scenario: crear cuenta corriente de un proveedor
- **WHEN** se crea una `SupplierAccount` para un proveedor de la cuenta
- **THEN** existe una fila en `supplier_accounts` con `balance = 0` y `(account_id, supplier_id)` único

#### Scenario: una sola cuenta por proveedor
- **WHEN** se intenta crear una segunda `SupplierAccount` para el mismo `(account_id, supplier_id)`
- **THEN** la operación es idempotente y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `supplier_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

### Requirement: Ledger append-only de movimientos del proveedor con balance_after
El sistema SHALL proveer un ledger `supplier_account_movements` (`id`, `supplier_account_id` FK→`supplier_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `purchase|payment_made|debit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only** (RLS solo SELECT, sin UPDATE/DELETE). Cada movimiento SHALL persistir su `balance_after`, computado a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

#### Scenario: movimiento persiste balance_after
- **WHEN** se postea un movimiento de `amount = 1000` (purchase) sobre una cuenta con `balance = 0`
- **THEN** la fila del ledger tiene `balance_after = 1000` y la cabecera `supplier_accounts.balance` queda en `1000`

#### Scenario: ledger es append-only
- **WHEN** un usuario intenta UPDATE o DELETE sobre `supplier_account_movements`
- **THEN** la operación es denegada por RLS

#### Scenario: movement_type fuera del dominio es rechazado
- **WHEN** se intenta insertar un movimiento con `movement_type = 'sale'` (tipo de cliente, no de proveedor)
- **THEN** el CHECK rechaza la fila (`check_violation`)

### Requirement: Helper intra-transacción c30_register_supplier_account_movement
El sistema SHALL proveer `public.c30_register_supplier_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC**, que **NO abre transacción propia**, espejo exacto de `c30_register_customer_account_movement`: lock de cabecera con `FOR UPDATE`, `balance_after = balance + p_amount`, INSERT append-only, UPDATE de la cabecera, RETURN id. La acumulación SHALL usar UPDATE-then-INSERT, nunca `ON CONFLICT DO UPDATE` con delta.

#### Scenario: el helper serializa con FOR UPDATE
- **WHEN** dos movimientos concurrentes sobre la misma `SupplierAccount` se postean
- **THEN** el lock de cabecera los serializa y ambos quedan reflejados en el saldo final

#### Scenario: el helper no es callable desde authenticated
- **WHEN** el rol `authenticated` intenta invocar el helper directamente
- **THEN** la llamada es denegada (REVOKE de PUBLIC)

### Requirement: PaymentMade reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `SupplierAccount`; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_made'`; (d) invoca el helper con `amount` negativo (`payment_made` reduce lo que se debe); (e) inserta una fila en `payments_made`; (f) **rutea el egreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` negativo (egreso), `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago; cuando es `cash` SHALL seguir el camino de caja existente sin tocar el ledger bancario; (g) emite el evento `PaymentMade` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`. Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Los parámetros `p_payment_method` y `p_bank_account_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`). Un pago que excede el saldo sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar pago disminuye el saldo
- **WHEN** se registra un `PaymentMade` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `supplier_account_movement` de tipo `payment_made` con `amount = −400` y `balance_after = 600`, y una fila en `payments_made`

#### Scenario: pago idempotente no duplica
- **WHEN** se llama `rpc_register_payment_made` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo pago, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario) y la segunda llamada devuelve el resultado original

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentMade` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: pago por transferencia registra egreso bancario en la misma transacción
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `SupplierAccount` queda en `balance = 600`, existe una fila en `payments_made`, y existe un `bank_movement` de `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: pago en efectivo no toca el ledger bancario
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'cash'`
- **THEN** el saldo del proveedor se reduce a 600 y NO se inserta ninguna fila en `bank_movements`

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentMade` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400`/`P0412`) y no se inserta ni el pago ni el movimiento bancario

### Requirement: Toda compra a cuenta corriente postea su cargo

El sistema SHALL postear el cargo en `supplier_account_movements` en **todo** camino de alta de compra cuyo `kind` efectivo de forma de pago sea `credit`, por el total de la operación, con signo positivo (aumenta lo que se le debe al proveedor) y `reference_id` apuntando al `operation_id` de la compra. El `kind` SHALL derivarse en el servidor a partir de la forma de pago imputada y NO SHALL aceptarse como dato del cliente.

El disparo SHALL usar el `kind` **crudo** derivado de la forma de pago, y NO el valor por defecto que el evento contable aplica cuando no hay forma de pago imputada: una compra **sin forma de pago** SHALL propagarse como `credit` hacia la partida doble (comportamiento vigente e histórico) y, al mismo tiempo, NO SHALL postear ningún movimiento en la cuenta corriente del proveedor. Solo la imputación **explícita** a una forma de pago de `kind = 'credit'` genera deuda observable en el ledger operativo.

Una compra imputada a `kind = 'credit'` que quede registrada sin su cargo correspondiente SHALL considerarse un defecto, no una configuración válida.

#### Scenario: Compra a crédito postea el cargo

- **GIVEN** un proveedor sin cuenta corriente previa
- **WHEN** se registra desde el formulario de compra una compra de 8000 imputada a una forma de pago de `kind = 'credit'` para ese proveedor
- **THEN** se crea la `supplier_accounts` del proveedor y un movimiento de tipo `purchase` por 8000 con `balance_after = 8000` y `reference_id` = la operación de compra, en el mismo commit

#### Scenario: Compra a crédito emite el evento de cargo

- **WHEN** se registra una compra a crédito de 8000
- **THEN** se inserta en `events` un `SupplierAccountCharged` con el importe, el `supplier_account_id`, el `supplier_id` y la referencia a la operación

#### Scenario: Compra en efectivo no toca la cuenta corriente

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'cash'`, `transfer`, `card`, `check`, `wallet` u `other`
- **THEN** no se crea ningún movimiento en `supplier_account_movements` y el saldo del proveedor no cambia

#### Scenario: Compra sin forma de pago imputada no toca la cuenta corriente

- **WHEN** se registra una compra sin informar forma de pago, con o sin proveedor
- **THEN** no se crea ningún movimiento en `supplier_account_movements`, y el evento contable emitido conserva su valor por defecto `credit`

#### Scenario: Un fallo posterior al cargo revierte la compra entera

- **GIVEN** una compra a crédito en curso cuyo cargo ya fue posteado
- **WHEN** un paso posterior de la misma transacción falla
- **THEN** ni las filas de `purchases`, ni el movimiento de cuenta corriente, ni el evento quedan persistidos

### Requirement: La compra a cuenta corriente exige un proveedor identificado

El sistema SHALL rechazar toda compra imputada a una forma de pago de `kind = 'credit'` que no tenga proveedor asociado, **antes** de aplicar efectos sobre stock, banco o cuentas corrientes. No hay deuda sin acreedor: una compra a cuenta corriente anónima produciría un pasivo imposible de cancelar y un saldo huérfano. El rechazo SHALL usar el mismo código de error de negocio que el rechazo simétrico de la venta a crédito sin cliente.

El sistema SHALL además validar que el proveedor informado pertenezca a la cuenta y no esté borrado, rechazando la operación en caso contrario.

#### Scenario: Compra a crédito sin proveedor es rechazada

- **WHEN** se registra una compra imputada a `kind = 'credit'` sin proveedor
- **THEN** la operación falla con `credit_requires_supplier`, no se modifica stock y no se crea ninguna fila de compra

#### Scenario: El formulario impide llegar a ese estado

- **WHEN** el usuario elige en el formulario de compra una forma de pago de `kind = 'credit'`
- **THEN** el proveedor pasa a ser obligatorio en la superficie y no se puede confirmar la compra sin seleccionarlo

#### Scenario: El formulario muestra el saldo del proveedor al comprar a crédito

- **GIVEN** un proveedor con saldo de 5000 en su cuenta corriente
- **WHEN** el usuario elige una forma de pago de `kind = 'credit'` y selecciona ese proveedor en una compra de 2000
- **THEN** la pantalla muestra el saldo actual (5000) y el saldo proyectado tras la compra (7000)

#### Scenario: Proveedor de otra cuenta o borrado es rechazado

- **WHEN** se registra una compra informando un proveedor inexistente, de otra cuenta, o con `deleted_at` seteado
- **THEN** la operación es rechazada y no se registra ni la compra ni ningún cargo

### Requirement: La compra con cargo posteado es inmutable y se corrige por borrado

El sistema SHALL impedir la edición de una operación de compra que tenga un movimiento posteado en la cuenta corriente del proveedor, con el mismo código de conflicto de estado que usa para las demás operaciones con dinero posteado, y SHALL exponer ese bloqueo en la superficie **antes** de que el usuario intente editar. El camino de corrección SHALL ser el borrado de la operación, que compensa el cargo, el movimiento bancario y el stock de forma atómica.

#### Scenario: Editar una compra a crédito es rechazado

- **GIVEN** una compra a crédito con su cargo posteado en la cuenta corriente del proveedor
- **WHEN** se intenta editar la operación
- **THEN** la operación es rechazada con el conflicto de estado y el mensaje nombra el camino de corrección

#### Scenario: El listado de compras deshabilita la edición con motivo visible

- **GIVEN** una compra con cargo de cuenta corriente posteado
- **WHEN** el usuario consulta el listado de operaciones de compra
- **THEN** la acción de editar aparece deshabilitada con el motivo visible, sin necesidad de llegar al error del servidor

#### Scenario: Borrar la compra devuelve el saldo del proveedor a su valor previo

- **GIVEN** un proveedor cuyo saldo pasó de 0 a 8000 por una compra a crédito
- **WHEN** se borra esa operación de compra
- **THEN** se registra el movimiento de reversión, el saldo vuelve a 0, el movimiento original permanece en el ledger, y el stock queda repuesto

### Requirement: Cargo manual de compra a crédito en cta cte de proveedor
El sistema SHALL proveer `rpc_register_supplier_charge(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que postea un movimiento de tipo `purchase` (`amount` positivo) en la `SupplierAccount`, incrementando lo que se le debe al proveedor. Es el camino **manual y complementario**: sirve para cargar deuda con un proveedor que no nace de una operación de compra registrada en el sistema (saldos iniciales, servicios, ajustes de alta), y convive con el camino automático del alta de compra a crédito.

**Deroga la decisión OQ-3/opción B de C-30**: el flujo de compras de stock ya NO es ajeno a la cuenta corriente. Desde `compras-proveedor-cuenta-corriente`, `rpc_create_purchase_operation` postea el cargo automáticamente cuando la forma de pago imputada es de `kind = 'credit'`, vía el helper compartido de cargo de tercero. La decisión original se tomó cuando el catálogo de formas de pago no existía y la compra no tenía forma de expresar "a crédito".

#### Scenario: cargar compra a crédito aumenta el saldo del proveedor
- **WHEN** se registra un cargo de 1500 sobre la `SupplierAccount` de un proveedor con `balance = 0`
- **THEN** la cuenta queda en `balance = 1500` con un movimiento de tipo `purchase`, `amount = +1500`, `balance_after = 1500`

#### Scenario: el flujo de compras de stock postea el cargo cuando la forma de pago es de cuenta corriente
- **WHEN** se crea una compra de stock vía `rpc_create_purchase_operation` imputada a una forma de pago de `kind = 'credit'`, con proveedor
- **THEN** se crea un `supplier_account_movement` de tipo `purchase` por el total, en el mismo commit que el alta de la compra

#### Scenario: el flujo de compras de stock no postea nada cuando la forma de pago no es de cuenta corriente
- **WHEN** se crea una compra de stock vía `rpc_create_purchase_operation` sin forma de pago imputada, o imputada a un `kind` distinto de `credit`
- **THEN** no se crea ningún `supplier_account_movement`

#### Scenario: el cargo manual y el automático comparten ledger y semántica
- **WHEN** se comparan un cargo posteado manualmente y uno posteado por el alta de una compra a crédito
- **THEN** ambos son movimientos de tipo `purchase` con signo positivo sobre la misma `SupplierAccount`, con `balance_after` calculado por el mismo helper

## Implementation Notes

- **Tablas**: `supplier_accounts`, `supplier_account_movements`, `payments_made` (migración `20260720000001_c30_customer_supplier_accounts.sql`)
- **Helpers**: `c30_register_supplier_account_movement` (REVOKE de PUBLIC), `c30_get_or_create_supplier_account` (lazy auto-create idempotente), `_register_bank_movement` (invocado desde `rpc_register_payment_made` para métodos bancarios, C2 `bank-payment-routing`)
- **RPCs**: `rpc_create_supplier_account`, `rpc_register_payment_made` (extendida en C2 con `p_payment_method`/`p_bank_account_id`), `rpc_register_supplier_charge` — todos SECURITY DEFINER
- **RLS**: solo política SELECT en las 3 tablas (`account_id IN (SELECT current_account_ids())`); escritura solo vía RPC definer
- **Decisión OQ-3**: integración con compras de stock es MANUAL (opción B) — `rpc_create_purchase_operation` no toca la cta cte automáticamente
- **Backend**: `backend/schemas/supplier_accounts.py`, `backend/repositories/supplier_account_repository.py`, `backend/services/supplier_accounts.py`, `backend/routers/supplier_accounts.py`
- **Frontend**: `frontend/app/(dashboard)/proveedores/[id]/cuenta/page.tsx` (árbol `proveedores/` greenfield)
- **Smoke prod**: 2026-06-20 — migración `20260720000001` + hotfix `20260720000002` LIVE; 7/7 smoke cases OK
- **C2 bank-payment-routing** (2026-07-02, PR #249): `rpc_register_payment_made` rutea pagos bancarios a `bank_movements` vía `_register_bank_movement`; migración `20260804000007_bank_payment_routing.sql`. Ver `bank-movement` spec.
