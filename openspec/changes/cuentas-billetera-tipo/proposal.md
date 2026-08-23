## Why

En `/banco` el alta es única — "Nueva cuenta bancaria" — y mete en la misma bolsa bancos reales y billeteras virtuales. El PO lo pidió textual (2026-08-22): *"aca deberia haber otra que sea agregar billetera virtual no solo agregar banco para diferenciarlos"*.

La foto de producción confirma que el problema no es hipotético: **las 4 cuentas activas de la cuenta real son billeteras virtuales, ninguna es un banco** (`MP`, `Mercado Pago`, `Naranja X`, `UALA`; más 4 duplicados de Mercado Pago ya soft-deleted). El formulario les pide "Banco" y "CBU" a todas, cuando lo que el usuario tiene es una billetera con **alias/CVU**. El resultado es un catálogo donde el usuario no distingue de un vistazo qué es un banco y qué es una billetera, ni al elegir cuenta, ni en el historial de movimientos, ni al mapear la cuenta destino de un método de pago.

## What Changes

- **Nuevo atributo `bank_accounts.account_kind`** (`'bank' | 'wallet'`, `NOT NULL DEFAULT 'bank'`, con `CHECK`), que clasifica cada cuenta. Migración idempotente.
- **Backfill de las cuentas existentes** por heurística de nombre sobre `name`/`bank_name` (lista de marcas cerrada y documentada: Mercado Pago/MP, Ualá, Naranja X, Personal Pay, Brubank, Lemon, Belo, Prex, Cuenta DNI, MODO, BNA+). Las cuentas **ambiguas quedan en `'bank'`** (default seguro, nunca se adivina).
- **Alta diferenciada en `/banco`**: dos botones — **"+ Banco"** y **"+ Billetera virtual"** — que abren el **mismo `BankAccountFormDialog` parametrizado por `kind`**, no un formulario nuevo.
- **Los campos no cambian: cambian las etiquetas.** Investigado el formulario actual (`name`, `bank_name`, `cbu`, `alias`, `currency`, `opening_balance`, `opening_date`): una billetera necesita exactamente los mismos campos, porque **el CVU también es de 22 dígitos** y comparte la validación `^[0-9]{22}$` con el CBU. Por eso `cbu` se reetiqueta a **"CVU"** y `bank_name` a **"Billetera"** cuando `kind = 'wallet'` — sin columnas nuevas, sin ocultar campos, sin tocar el `CHECK` de tabla ni el `P0411` de la RPC.
- **Distinción visible** en todas las superficies que ya listan cuentas: ícono + badge por tipo (`Landmark` banco / `Wallet` billetera) en el selector de `/banco`, el encabezado del historial de movimientos, la conciliación, y los selectores de cuenta-default de `PaymentMethodManager` y `PaymentMethodSelect`.
- **`rpc_create_bank_account` gana el parámetro `p_account_kind`** (8º, `DEFAULT 'bank'`), validado contra el dominio cerrado. Como la firma cambia, se hace `DROP` explícito de la firma vieja de 7 argumentos antes del `CREATE` (evita la ambigüedad de overload `42725`), seguido de `GRANT EXECUTE` a `authenticated` y `REVOKE` explícito de `PUBLIC` y `anon`.
- **Sin impacto contable**: el `kind = 'wallet'` de `payment_methods` ya rutea a `1110 Banco` en el consumidor contable, y `account_kind` es un atributo **descriptivo** de la cuenta. Ningún asiento, saldo ni conciliación cambia de comportamiento.

## Capabilities

### New Capabilities

Ninguna. El change extiende una capability existente; no introduce un dominio nuevo.

### Modified Capabilities

- `bank-account`: la entidad `BankAccount` incorpora `account_kind` como atributo obligatorio con dominio cerrado; `rpc_create_bank_account` y `POST /bank-accounts` aceptan y persisten el tipo; el alta desde `/banco` se bifurca en dos entradas sobre un formulario parametrizado con etiquetas por tipo; las superficies que listan cuentas muestran el tipo.

> `payment-method` **no** se modifica: mostrar el ícono del tipo junto a la cuenta-default es presentación de un atributo de `bank-account`, no un cambio de requisito de los métodos de pago.

## Impact

**Base de datos** (migración nueva, `MAX(version)` en prod verificado = `20261006000001`)
- `public.bank_accounts`: columna `account_kind` + `CHECK` + backfill.
- `public.rpc_create_bank_account`: `DROP` firma de 7 args → `CREATE` de 8 args → re-`GRANT`/`REVOKE`. Requiere sumar la RPC a la cadena de reapply de `KPI_Validation.yml` si ya figura ahí.

**Backend Python**
- `backend/schemas/bank_accounts.py` — `BankAccountCreate.account_kind` y `BankAccountOut.account_kind`.
- `backend/repositories/bank_account_repository.py` — la llamada posicional `rpc_create_bank_account($1..$7)` pasa a `$1..$8`; los `SELECT` de lectura suman la columna.
- `backend/services/bank_accounts.py` — propaga el campo; nuevo ERRCODE de tipo inválido mapeado a 422.
- `backend/routers/bank_accounts.py` — sin cambios de lógica (solo el shape ya validado por Pydantic).

**Frontend** — superficie declarada: **la misma `/banco`, sin rutas nuevas**
- `frontend/components/bank-accounts/BankAccountFormDialog.tsx` — prop `kind`, título y etiquetas derivadas.
- `frontend/app/(dashboard)/banco/page.tsx` — dos botones de alta (estado vacío y encabezado de la card), ícono en el selector y en el encabezado de movimientos.
- `frontend/hooks/data/use-bank-accounts.ts` — `accountKind` en `BankAccountApi`/`BankAccount`/`mapBankAccount` y en el payload de alta.
- `frontend/lib/bank-account-kind.ts` **(nuevo, capa canónica)** — fuente única de etiqueta, ícono y variante de badge por tipo, siguiendo el precedente de `lib/product-stock.ts`. Ningún consumidor redefine el mapeo por su cuenta.
- `frontend/components/payment-methods/PaymentMethodManager.tsx` y `PaymentMethodSelect.tsx` — el `Landmark` hardcodeado pasa a resolverse por tipo.

**Verificación**: desktop + mobile y tema claro + oscuro, según la regla de superficie frontend del proyecto.

**Governance**: LOW-MEDIUM. Atributo descriptivo sobre una tabla en producción con 8 filas; sin efectos sobre dinero, asientos ni saldos.
