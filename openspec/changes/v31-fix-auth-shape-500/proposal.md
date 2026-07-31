## Why

`get_current_user` (`backend/core/auth.py:63-67`) devuelve `{"user_id", "role", "plan"}`, pero tres endpoints leen ese contexto con la clave `"sub"` — que **no existe** en el dict — y con un `or` que la usa como fallback de `account_id`. El resultado es un string vacío (`""`) donde el código de abajo espera un UUID: `quotes.py:60` (`created_by`), `customer_accounts.py:61` y `supplier_accounts.py:61` (`account_id`). En producción eso es un 500 (H-06 de la auditoría 2026-07-07, confirmado sin remediar en la exploración del 2026-07-30).

El defecto es invisible para la suite porque el contrato del contexto de auth **no está tipado ni verificado**: el fixture de tests emite un JWT con `sub`/`role="authenticated"` y los repositorios están mockeados, así que el `""` nunca llega a Postgres. Código roto + doble roto = test verde. Mientras ese contrato siga siendo un `dict` sin forma declarada, **todo test nuevo de autorización hereda la misma ceguera** — y los tres changes que siguen en el cluster (`v31-fsm-status-triggers`, `v31-authz-token-hook`, `v3-rbac-multirole`) escriben exactamente ese tipo de test. Por eso este change va primero.

## What Changes

- **`AuthContext` como `TypedDict`** en `backend/core/auth.py` con el shape real `{user_id: str, role: str, plan: str}`. `get_current_user` pasa a declararlo como tipo de retorno (hoy es `-> dict`), y las firmas de servicios/guards que hoy reciben `auth: dict` lo adoptan donde el cambio es mecánico.
- **Los 3 call sites rotos pasan a la clave canónica**:
  - `backend/routers/quotes.py:60` → `created_by=auth["user_id"]` (hoy `auth.get("sub", "")`).
  - `backend/routers/customer_accounts.py:61` y `backend/routers/supplier_accounts.py:61` → el `account_id` del tenant se resuelve con la dependencia existente `Depends(get_account_id)` (el mismo resolver que ya usan los demás endpoints de esos routers), **no** desde un claim del JWT. La expresión actual `auth.get("account_id") or auth.get("sub", "")` era doblemente incorrecta: ni `account_id` ni `sub` existen en el contexto, y el id de usuario nunca fue el id de cuenta.
- **Test de regresión de contrato (anti-deriva)**: un test verifica que las claves que produce `get_current_user` coinciden exactamente con las declaradas en `AuthContext`, de forma que agregar/renombrar/quitar una clave en cualquiera de los dos lados rompa la suite en vez de degradar en silencio.
- **Tests de los 3 endpoints** que afirman que el UUID real del actor/tenant llega al repositorio — hoy ningún test observa ese argumento, que es la razón por la que el `""` pasó desapercibido.
- **Auditoría cerrada del shape**: se verifica que no queden otros lectores del contexto con claves inexistentes (barrido de `auth.get(`/`auth[` en `backend/`), y se documenta el resultado.

Sin **BREAKING**: la API HTTP no cambia de forma; cambia de un 500 a la respuesta que siempre debió dar.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `backend-auth`: el contrato del contexto que expone el dependency de autenticación pasa a ser **tipado y verificable**, con `plan` incluido (hoy `REQ-BA-02` documenta solo `{user_id, role}`, un shape que el código dejó atrás), y con la regla explícita de que los consumidores derivan el actor de `user_id` y el tenant del resolver de cuenta — nunca de claims que el contexto no expone. Se agrega además el requisito de que los dobles de test no puedan divergir del contrato real.

## Impact

- **Código**: `backend/core/auth.py` (TypedDict + tipo de retorno), `backend/routers/quotes.py`, `backend/routers/customer_accounts.py`, `backend/routers/supplier_accounts.py`, `backend/core/guards.py` (firmas), `backend/tests/conftest.py` (fixture del contexto), tests nuevos.
- **API**: `POST /quotes`, `GET /clientes/{client_id}/cuenta`, `GET /proveedores/{supplier_id}/cuenta` dejan de responder 500.
- **Base de datos**: ninguna migración. No se toca SQL, ni RLS, ni RPCs.
- **Dependencias**: ninguna nueva. `TypedDict` viene de la stdlib (`typing`).
- **Governance**: **MEDIO**. No cambia el modelo de autorización ni la validación del JWT (eso es `v31-authz-token-hook`, CRÍTICO): corrige lectores del contexto y agrega infraestructura de tests. Se implementa con checkpoints y las decisiones no obvias se explicitan en `design.md`.
- **Cluster**: prerequisito de `v31-fsm-status-triggers`, `v31-authz-token-hook` y `v3-rbac-multirole` — es el paso 1 de la secuencia firmada por el PO el 2026-07-30.
