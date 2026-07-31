> **Modo TDD estricto.** Cada tarea de código va precedida por su test (RED) y el test debe fallar por la razón esperada antes de escribir la implementación (GREEN). Ninguna tarea `[x]` sin ejecución real de la suite.
> **Governance MEDIO** — implementar con checkpoints; las decisiones no obvias ya están en `design.md`.

## 1. Red de seguridad (baseline antes de tocar nada)

- [x] 1.1 Ejecutar la suite backend completa (`pytest backend/tests`) y registrar el baseline exacto de tests que pasan. Si algo ya falla, **NO** arreglarlo: reportarlo como fallo preexistente y detenerse para confirmar con el orquestador.
- [x] 1.2 Ejecutar y anotar el baseline acotado de los archivos que este change va a tocar: `test_c29_quote_salesorder.py`, `test_c30_customer_supplier_accounts.py`, `test_auth.py`, `test_api_standards_pagination.py`.
- [x] 1.3 Ejecutar el barrido de auditoría **antes** del fix y guardar la salida en el PR: `auth.get(` y `auth[` sobre `backend/` excluyendo `.venv`. Confirmar el conteo esperado (3 lectores de claves inexistentes en `quotes.py`, `customer_accounts.py`, `supplier_accounts.py`; el resto usando `user_id`/`role`/`plan`).

## 2. Contrato tipado `AuthContext` (D1 + D2)

- [x] 2.1 **RED** — Escribir en `backend/tests/test_auth.py` el test de contrato: decodificar un JWT de test con `get_current_user` y afirmar que `set(resultado.keys()) == set(AuthContext.__annotations__.keys())`. Debe fallar con `ImportError`/`NameError` porque `AuthContext` todavía no existe.
- [x] 2.2 **GREEN** — Declarar `AuthContext(TypedDict)` con `user_id: str`, `role: str`, `plan: str` en `backend/core/auth.py` y anotar `get_current_user(...) -> AuthContext`. Ejecutar: el test de 2.1 pasa.
- [x] 2.3 **TRIANGULATE** — Segundo caso: un JWT que trae `app_metadata` con `role` y `plan` explícitos produce el mismo conjunto de claves (los valores cambian, el shape no). Tercer caso (negativo, anti-deriva): construir un dict con una clave extra y afirmar que la comparación de conjuntos lo detecta — prueba que la aserción de 2.1 no es una tautología. Ejecutar: los tres pasan.
- [x] 2.4 **REFACTOR** — Anotar `AuthContext` en las firmas de `backend/core/guards.py` (`require_role`, `require_plan`, `require_platform_admin`). **No** barrer los ~20 services que declaran `auth: dict` (D5). Ejecutar la suite completa: sin regresiones respecto del baseline de 1.1.

## 3. `POST /quotes` — el actor real llega al repositorio (H-06, call site 1)

- [x] 3.1 **RED** — Test en `test_c29_quote_salesorder.py`: crear un presupuesto con el cliente autenticado y afirmar que el `created_by` recibido por `QuoteRepository.create_quote` es el UUID del usuario del token. Debe fallar mostrando `''`.
- [x] 3.2 **GREEN** — En `backend/routers/quotes.py:60`, reemplazar `auth.get("sub", "")` por `auth["user_id"]`. Ejecutar: 3.1 pasa.
- [x] 3.3 **TRIANGULATE** — Segundo caso con un `sub` distinto en el token: el `created_by` propagado cambia en consecuencia (descarta un valor hardcodeado). Ejecutar: ambos pasan.

## 4. Cuentas corrientes — el tenant sale del resolver de cuenta (H-06, call sites 2 y 3, D3)

- [x] 4.1 **RED** — Test en `test_c30_customer_supplier_accounts.py` para `GET /clientes/{client_id}/cuenta`: afirmar que el `account_id` que recibe `CustomerAccountRepository.get_account` es el UUID de cuenta que devuelve la dependencia `get_account_id` (el `TEST_ACCOUNT_ID` del override del conftest), **no** el `sub` ni `''`. Debe fallar mostrando `''`.
- [x] 4.2 **GREEN** — En `backend/routers/customer_accounts.py`, inyectar `account_id: uuid.UUID = Depends(get_account_id)` en `get_customer_account` y eliminar la línea `account_id = auth.get("account_id") or auth.get("sub", "")`. Mantener el router como validación + DI (nada de lógica). Ejecutar: 4.1 pasa.
- [x] 4.3 **RED** — Test equivalente para `GET /proveedores/{supplier_id}/cuenta` sobre `SupplierAccountRepository.get_account`. Debe fallar mostrando `''`.
- [x] 4.4 **GREEN** — Aplicar el mismo cambio en `backend/routers/supplier_accounts.py`. Ejecutar: 4.3 pasa.
- [x] 4.5 **TRIANGULATE** — Para uno de los dos endpoints, un caso con un `account_id` distinto en el override de la dependencia: el valor propagado sigue al resolver (descarta hardcodeo). Ejecutar: todos pasan.
- [x] 4.6 **REFACTOR** — Verificar que ningún endpoint de esos dos routers quedó resolviendo tenancy a mano; los que ya usaban `get_account_id` no se tocan. Ejecutar la suite completa: sin regresiones.

## 5. Cierre de la auditoría del shape (D6)

- [x] 5.1 Re-ejecutar el barrido de 1.3 **después** del fix y exigir **0** lecturas del contexto con claves fuera de `AuthContext`. Pegar la salida en el PR junto a la de 1.3 (antes/después).
- [x] 5.2 Revisar los dobles de auth en `backend/tests/` (fixtures y `dependency_overrides` que sustituyan `get_current_user`) y alinearlos al contrato declarado. Documentar en el PR cuáles se tocaron y cuáles no aplicaban.
- [x] 5.3 Si el barrido revela algún lector roto adicional no previsto (fuera de los 3 de H-06), **no** arreglarlo silenciosamente: agregarlo como tarea explícita con su ciclo RED/GREEN propio, o documentar por qué queda fuera de scope.

## 6. Verificación y cierre

- [x] 6.1 Ejecutar la suite backend completa dos veces seguidas (descarta flake) y confirmar el conteo de tests nuevos respecto del baseline de 1.1.
- [x] 6.2 Confirmar que **no** se agregó ninguna migración SQL en `supabase/migrations/` (este change no toca la base de datos).
- [x] 6.3 Confirmar que `backend/core/auth.py` no cambió el cómputo de `role` ni de `plan` — solo se agregó la declaración de tipo (Non-Goal explícito: el hook de rol es `v31-authz-token-hook`).
- [x] 6.4 Abrir el PR con la tabla de evidencia del ciclo TDD (tarea / archivo de test / safety net / RED / GREEN / TRIANGULATE / REFACTOR) y el antes/después del barrido de auditoría.
- [ ] 6.5 Verificación post-merge en el backend desplegado: ejercitar `POST /quotes`, `GET /clientes/{id}/cuenta` y `GET /proveedores/{id}/cuenta` con un usuario real y confirmar 2xx en lugar de 500. Registrar el resultado.
      PENDIENTE MANUAL PO (no bloqueante): verificar con sesión real contra Render — ver proposal.
