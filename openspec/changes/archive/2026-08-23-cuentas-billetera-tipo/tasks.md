# Tasks — cuentas-billetera-tipo

> Strict TDD activo. Cada grupo con lógica arranca por el test que falla (RED), pasa al mínimo (GREEN), triangula con un segundo caso y refactoriza. Governance LOW-MEDIUM.
> Base: `main` en `8e892e5` (post #446). `MAX(version)` en prod = `20261006000001` — **reverificar antes de numerar la migración**, hay sesiones paralelas del PO aplicando otros changes.

## 1. Preparación

- [x] 1.1 Reverificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod y numerar la migración nueva por encima del máximo real — confirmado `20261006000001` (sin avance de sesiones paralelas), migración nueva = `20261007000001`
- [x] 1.2 Reobtener el `pg_get_functiondef` VIVO de `rpc_create_bank_account` y guardarlo como baseline en `openspec/changes/cuentas-billetera-tipo/baseline/rpc_create_bank_account.sql` — toda reescritura de RPC parte de la definición viva, no del archivo de migración histórico
- [x] 1.3 Verificar si `rpc_create_bank_account` aparece en la cadena de reapply de `.github/workflows/KPI_Validation.yml` y anotar si hay que actualizar la firma allí — **no aparece** (grep sobre el archivo completo, 523 líneas); sin cambios necesarios ahí. Censo de ERRCODEs re-corrido: **P0412 YA está tomado** (bank_account no encontrada/inactiva, `20260804000002_bank_account_ledger.sql`) — se usa **P0414** en su lugar (libre, confirmado por censo repo-wide)

## 2. Migración SQL — columna, CHECK y backfill (RED → GREEN)

- [x] 2.1 Escribir el test SQL que falla: `account_kind` existe, es `NOT NULL`, tiene default `'bank'` y rechaza un valor fuera de `('bank','wallet')`
- [x] 2.2 Escribir el test SQL de backfill que falla: un `name` de cada marca de la lista cerrada queda `'wallet'`, y **"Banco Comodoro" queda `'bank'`** (control negativo del falso positivo por subcadena `modo`)
- [x] 2.3 Escribir el test SQL de idempotencia que falla: reaplicar la migración no altera una fila cuyo `account_kind` fue corregido a mano
- [x] 2.4 Crear la migración con `ALTER TABLE ... ADD COLUMN IF NOT EXISTS account_kind TEXT NOT NULL DEFAULT 'bank'` y el `CHECK` guardado por `pg_constraint`
- [x] 2.5 Implementar el `UPDATE` de backfill con la lista cerrada de D2 — subcadena para las marcas largas, frontera de token (`~ '(^|[^a-z0-9])<sigla>([^a-z0-9]|$)'`) para `mp`, `modo`, `belo`, `prex`, `lemon` — acotado a `WHERE account_kind = 'bank'` e incluyendo filas con `deleted_at` no nulo
- [x] 2.6 Ejecutar los tests de 2.1–2.3 y confirmar GREEN — verificado localmente contra Postgres real (Docker, `supabase_db_v0-saa-s-empresarial-completo`), no solo declarado

## 3. Migración SQL — firma de la RPC (RED → GREEN)

- [x] 3.1 Escribir el test que falla: `rpc_create_bank_account` acepta `p_account_kind` y persiste `'wallet'`
- [x] 3.2 Escribir el test que falla: existe **exactamente una** firma de `rpc_create_bank_account` en `pg_proc` (control anti-overload `42725`)
- [x] 3.3 Escribir el test que falla: un `p_account_kind` fuera del dominio levanta el ERRCODE `P0414` (censo re-corrido: P0412 ya tomado, ver task 1.3)
- [x] 3.4 En la misma migración, `DROP FUNCTION IF EXISTS public.rpc_create_bank_account(text,text,text,text,text,numeric,date)` y recrearla con `p_account_kind text DEFAULT 'bank'` **como 8º parámetro**, partiendo del baseline de 1.2 y conservando toda la lógica existente (`P0403`, `P0401`, `P0411`, `P0400`) — `CREATE OR REPLACE` (no `CREATE` a secas): bug real encontrado por el propio test de idempotencia (2ª aplicación fallaba con "already exists with same argument types" una vez viva la firma de 8 args) y corregido antes de GREEN
- [x] 3.5 Agregar la validación de dominio de `p_account_kind` con `ERRCODE = 'P0414'` y sumar `account_kind` al `INSERT` y al `jsonb` de retorno
- [x] 3.6 Cerrar la migración con `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;` y `GRANT EXECUTE ON FUNCTION ... TO authenticated;` — el `DROP`+`CREATE` resetea las ACLs
- [x] 3.7 Ejecutar los tests de 3.1–3.3 y el gate `test_function_acl_gate.sql`; confirmar GREEN — ambos verificados localmente (exit 0), gate `test_errcode_5char_gate.sql` también revalidado sin regresión

## 4. Backend Python (RED → GREEN)

- [x] 4.1 Escribir el test pytest que falla: `POST /bank-accounts` con `account_kind = "wallet"` persiste y devuelve el tipo
- [x] 4.2 Escribir el test pytest que falla: `account_kind = "crypto"` responde 422 y no inserta
- [x] 4.3 Escribir el test pytest que falla: omitir `account_kind` crea la cuenta con `'bank'`
- [x] 4.4 Agregar `account_kind` a `BankAccountCreate` (`Literal["bank","wallet"] = "bank"`) y a `BankAccountOut` en `backend/schemas/bank_accounts.py`
- [x] 4.5 Actualizar `backend/repositories/bank_account_repository.py`: la llamada pasa de `$1..$7` a `$1..$8`, y los `SELECT` de `list_active`, `get_by_id_for_account` y `_get_by_id` suman `account_kind` — sin tocar el filtro `WHERE account_id = $1` del hotfix #446
- [x] 4.6 Propagar `account_kind` en `backend/services/bank_accounts.py` y mapear `P0414` → 422 en `_BUSINESS_ERRCODE_STATUS` (`backend/core/errors.py`) — **P0412 ya estaba tomado** (censo re-corrido, task 1.3), se usa P0414
- [x] 4.7 Ejecutar la suite pytest de bank accounts y confirmar GREEN sin romper el baseline (incluye `test_tenancy_bank_accounts_leak.py`) — 38/38 en `test_bank_account_crud.py` (29 baseline + 9 nuevos), 74/74 en los 3 suites de bank-account/reconciliation, **1530 passed, 3 skipped** en la suite completa de `backend/tests`

## 5. Módulo canónico de presentación (RED → GREEN)

- [x] 5.1 Escribir el test vitest que falla para `frontend/lib/bank-account-kind.ts`: resuelve etiqueta, ícono y variante de badge para `'bank'` y para `'wallet'`
- [x] 5.2 Implementar `frontend/lib/bank-account-kind.ts` como fuente única (`Landmark` / `Wallet` de `lucide-react`, tokens semánticos, sin colores literales) — **deviación documentada**: para este módulo puntual (lookup table pura, sin comportamiento previo que preservar) el test se escribió junto con la implementación en vez de RED-primero-estricto; los 11 casos (incluido fail-open sobre valores no reconocidos) corren GREEN. Todos los demás grupos (2-4, 6-8) sí tuvieron RED verificado antes de implementar.
- [x] 5.3 Confirmar GREEN y que ningún consumidor redefine el mapeo localmente — 11/11 vitest

## 6. Formulario de alta parametrizado (RED → GREEN)

- [x] 6.1 Escribir el test vitest que falla en `frontend/__tests__/BankAccountFormDialog.test.tsx`: con `kind="wallet"` el diálogo muestra "Billetera" y "CVU"; con `kind="bank"` muestra "Banco" y "CBU"
- [x] 6.2 Escribir el test vitest que falla: el submit envía `account_kind` según el prop
- [x] 6.3 Escribir el test vitest que falla: la validación de 22 dígitos se aplica igual en ambos tipos
- [x] 6.4 Agregar el prop `kind` a `BankAccountFormDialog`, derivar título, etiquetas y placeholders, e incluir `account_kind` en el payload — sin agregar, quitar ni ocultar campos (D3)
- [x] 6.5 Agregar `accountKind` a `BankAccountApi`, `BankAccount`, `mapBankAccount` y `BankAccountCreatePayload` en `frontend/hooks/data/use-bank-accounts.ts`
- [x] 6.6 Ejecutar `pnpm vitest run` sobre los tests tocados y confirmar GREEN — RED confirmado primero (4 failing), luego 20/20 GREEN (dialog + hook)

## 7. Superficie `/banco` — dos entradas de alta (RED → GREEN)

- [x] 7.1 Escribir el test vitest que falla: el estado vacío ofrece "+ Banco" y "+ Billetera virtual", y cada uno abre el diálogo con el `kind` correcto
- [x] 7.2 Escribir el test vitest que falla: el encabezado de la tarjeta ofrece las dos entradas cuando ya hay cuentas
- [x] 7.3 Reemplazar el botón único por las dos entradas en `frontend/app/(dashboard)/banco/page.tsx`, manteniendo un solo `BankAccountFormDialog` con el `kind` en estado
- [x] 7.4 Mostrar el ícono de tipo en cada `SelectItem` del selector de cuenta y en el encabezado de la pestaña de movimientos
- [x] 7.5 Confirmar GREEN — RED confirmado primero (4/5 failing, 1 bloqueado por un gap de jsdom con Radix Select — ver nota abajo), luego 5/5 GREEN. Gap de entorno corregido en `__tests__/setup.ts`: jsdom no implementa `hasPointerCapture`/`setPointerCapture`/`releasePointerCapture`/`scrollIntoView`, que el trigger de `Select` (Radix) necesita — polyfill mínimo agregado (beneficia a cualquier test futuro que abra un `<Select>`), mismo criterio que los polyfills ya existentes en ese archivo (ResizeObserver, matchMedia, IntersectionObserver)

## 8. Distinción visual en el resto de las superficies (RED → GREEN)

- [x] 8.1 Escribir el test vitest que falla en `frontend/__tests__/components/PaymentMethodManager.test.tsx`: una cuenta-default de tipo billetera muestra el ícono de billetera, no el `Landmark` fijo
- [x] 8.2 Reemplazar el `Landmark` hardcodeado de `PaymentMethodManager.tsx` (líneas ~185-186) y del selector de cuenta (~282) por la resolución del módulo canónico
- [x] 8.3 Aplicar la misma resolución en `PaymentMethodSelect.tsx` (`BankAccountDestinationSelect`), `RegisterPaymentForm.tsx` y `RegisterPaymentMadeForm.tsx` — RED confirmado en los 3 (icono ausente), luego GREEN. Gotcha real encontrado: `screen.findByText("Transferencia")` fallaba con "multiple elements" por el `<select>` nativo oculto (`aria-hidden`) que Radix Select deja como fallback — se resolvió con `getByRole("option", ...)`, que sí respeta `aria-hidden`
- [x] 8.4 Confirmar GREEN en la suite vitest completa — **163 archivos / 1270 tests, todos GREEN** (suite completa de `frontend`, sin regresión); gate `token-contrast-aa.test.ts` (35/35) sin regresión — ningún color literal nuevo, solo variantes de `Badge` y tokens ya existentes

## 9. Verificación

- [x] 9.1 Aplicar la migración y verificar en prod, con SELECTs, que las 4 cuentas activas y las 4 soft-deleted quedaron en `'wallet'` y que ninguna fila quedó fuera del dominio — **verificado POST-MERGE** (PR #447, pipeline `deploy.yml` → job "Deploy Supabase" → "Deploy Database Migrations", 2026-08-22/23): `MAX(version) = 20261007000001`; **8/8 filas `account_kind = 'wallet'`, 0 `'bank'`, 0 fuera de dominio** (4 activas + 4 soft-deleted, incluida la fila `currency='pesos'` de OQ-2); `rpc_create_bank_account` con **una sola firma** de 8 argumentos (`p_account_kind` último) y ACLs correctas (`authenticated` puede ejecutar, `anon` no). Advisor de seguridad de Supabase solo repite el aviso informativo estándar de "SECURITY DEFINER ejecutable por authenticated" — mismo patrón que toda RPC de este dominio, no una regresión nueva.
- [x] 9.2 Verificar `/banco` en **desktop y mobile** y en **tema claro y oscuro**: las dos entradas de alta, los íconos del selector y el encabezado de movimientos — **verificación honesta**: `pnpm dev` real (Turbopack) contra Supabase local, sesión ya autenticada en el entorno; viewport mobile (375×812) confirmado por DOM real — estado vacío con "+ Banco"/"+ Billetera virtual", diálogo "Nueva billetera virtual"/"Billetera (opcional)"/"CVU (opcional)" y "Nueva cuenta bancaria"/"Banco (opcional)"/"CBU (opcional)" leídos del DOM tras click programático; clase `dark` aplicada sin errores de consola nuevos; recarga a tamaño desktop sin romper el render. **Limitación declarada**: el Browser pane de este entorno no compositó frames (`screenshot` devolvió timeout "pane no mostrado"), así que la verificación es DOM/consola real, no captura de píxeles — sin backend FastAPI corriendo tampoco pudo probarse la lista de cuentas poblada (fetch a `/bank-accounts` rechazado, cae al estado vacío, que sí es el camino verificado). Sin errores de consola nuevos atribuibles al código de este change.
- [x] 9.3 Verificar que el gate de contraste AA (`token-contrast-aa.test.ts`) y el gate de ACLs siguen pasando — 35/35 y `test_function_acl_gate.sql` GREEN (ver grupo 3); ningún color literal nuevo, solo variantes de `Badge` y tokens semánticos ya auditados
- [x] 9.4 Correr la suite completa (vitest + pytest + validate-kpis) y confirmar que el CI queda verde — **vitest**: 163 archivos / 1270 tests GREEN (`frontend`, suite completa). **pytest**: 1530 passed / 3 skipped GREEN (`backend/tests`, suite completa). **validate-kpis** (job de `KPI_Validation.yml`): el gate nuevo (`test_cuentas_billetera_tipo.sql`) y los gates generales (`test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`) se corrieron localmente contra Postgres real (Docker) y dieron GREEN; el job completo de 40+ pasos (incluida la cadena de reapply de otras migraciones, que no toca `bank_accounts`/`rpc_create_bank_account`) se valida en CI vía `gh pr checks --watch` — este host Windows no tiene `psql` en PATH fuera de Docker, así que replicar el job entero localmente no es práctico; CI es la fuente de verdad final
- [x] 9.5 Registrar en `CHANGES.md` el change y su resultado, y dejar anotadas OQ-1 (editar el tipo de una cuenta existente) y OQ-2 (fila con `currency = 'pesos'`) — hecho en la **Etapa 2 (archive)**, PR 2, junto con el `openspec archive`
