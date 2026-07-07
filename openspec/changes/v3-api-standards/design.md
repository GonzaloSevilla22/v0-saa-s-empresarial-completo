## Context

El backend FastAPI (`backend/`, 3 capas routers→services→repositories, JWT-passthrough, RLS org-based) creció módulo por módulo. La auditoría del estado real (2026-07-07) contra los estándares del modelo V3 §6/§9 arroja tres divergencias transversales:

| Estándar V3 | Estado actual auditado | Veredicto |
|---|---|---|
| **Errores RFC 7807** (`type/title/status/detail/code/field`) | `backend/core/errors.py` devuelve solo `{"detail": str}`. Mapea `sqlstate P04xx`/`23xxx` → HTTP status (correcto), pero sin envelope 7807. **No hay handler de `RequestValidationError`** → los 422 de Pydantic salen en el shape default de FastAPI `{"detail":[{loc,msg,type}]}`. `main.py` registra solo `asyncpg.PostgresError` y un `Exception` catch-all. | **Gap — construir** el envelope sobre el mapeo existente |
| **Paginación** `?page&size → {items,total,page,pages}` | Tres shapes conviven: `SalesPageOut`/`PurchasesPageOut` = `{items, total_operations}`; `PaymentReceiptsPageOut` = `{items, total}`; `customer_accounts`/`supplier_accounts`/`journal_entries` usan `limit/offset` y devuelven **listas planas sin envelope**. Nombres de parámetro mezclados: `page/page_size` vs `limit/offset`. | **Gap — unificar** envelope y nombres |
| **`Idempotency-Key` header** en toda mutación no-idempotente | La clave viaja como **campo del body** (`idempotency_key` en `SaleOperationIn`, `PurchaseOperationIn`, sales_orders, customer/supplier accounts, bank_reconciliation). `Header(` no se usa en ningún router. **Cerrar caja (`CloseSessionIn`) no tiene idempotencia**. `operation_idempotency` ya existe y es atómica (DEC-06). | **Parcial — cambiar transporte** (body→header) + agregar a cash-close |
| **`BaseRepository[T]` con `soft_delete()` + paginación** | `soft_delete()` y `not_deleted_clause()` ya existen (`v3-soft-delete-policy`, PR #275). **No hay helper de paginación.** | **Parcial — agregar paginación** |
| **UoW: ningún service comitea** (RN-C1) | **Ya se cumple por diseño**: la transacción vive en los RPCs `SECURITY DEFINER` de Postgres; los services orquestan y llaman RPCs, no comitean. No documentado como decisión. | **Documentar — DEC-24** |

Constraint dura de plataforma (Lección C3, registrada): el CHECK `operation_idempotency_operation_kind_check` en prod (`gxdhpxvdjjkmxhdkkwyb`) enumera **exactamente** `sale, purchase, payment_received, payment_made, supplier_charge, bank_movement, event_consumer, bank_statement_import`. `cash_session_close` NO está. Generalizar idempotencia a cerrar caja **requiere una migración a ese CHECK**, y al recrearlo hay que enumerar la unión vigente (CI no atrapa kinds faltantes: DB vacía).

## Goals / Non-Goals

**Goals:**
- Un solo formato de error (`application/problem+json`, RFC 7807) para 4xx y 5xx, construido **sobre** el mapeo de `errors.py` sin cambiar los status que ya devuelve.
- Un solo contrato de paginación (`?page&size → {items,total,page,pages}`) en todos los listados, con el cálculo centralizado en `BaseRepository`.
- `Idempotency-Key` por header en todas las mutaciones no-idempotentes (incluida cerrar caja), con `operation_idempotency` como backing store — **sin cambiar la atomicidad ni los `operation_kind` existentes**, solo agregando `cash_session_close`.
- DEC-24 asentada: el UoW de Aliadata son los RPCs `SECURITY DEFINER`.

**Non-Goals:**
- **No cambiar comportamiento de negocio.** Montos, reglas de stock/caja/fiscales, transiciones FSM, RLS: intactos. Gobernanza BAJO.
- No migrar el manejo de auth/rate-limit (V3 §9 los delega a Supabase Auth — fuera de este change).
- No reescribir los RPCs ni mover la transacción a Python (DEC-24 documenta lo contrario).
- No versionar la API (`/api/v1`) en este change salvo que ya exista el prefijo — el foco es error/paginación/idempotencia (OQ4).
- No tocar las tablas de negocio: la única migración es el `operation_kind` de cerrar caja.

## Decisions

### D1 — Envelope 7807 sobre el mapeo existente, no un reemplazo

`errors.py` ya traduce `sqlstate → HTTP status` con mensajes seguros. Se **envuelve** ese resultado en el shape 7807 en vez de reescribirlo: el handler de `asyncpg.PostgresError` sigue decidiendo el status con `_BUSINESS_ERRCODE_STATUS`, pero emite `{type, title, status, detail, code}` con `code = sqlstate` (el `P04xx`) y media type `application/problem+json`. Se agregan dos handlers nuevos en `main.py`: `RequestValidationError` (→ 422 con `field` por cada violación, tomando `loc[-1]`) y `HTTPException` (para que los `raise HTTPException` dispersos también salgan 7807). El catch-all `Exception` pasa a 7807 genérico. **Alternativa descartada:** una librería de problem-details — innecesaria para 4 handlers; sumaría dependencia contra el espíritu "no vendor nuevo".

### D2 — `code` y `field` como extensiones tipadas

`code`: para errores de RPC es el `sqlstate` (`P0409`, etc.) — ya es estable y el frontend puede ramear por él. Para errores no-DB, un slug estable (`validation_error`, `idempotency_key_required`, `internal_error`). `field`: presente solo en 422 de validación, = nombre del campo ofensor. Ambas son extensiones válidas de 7807 (el RFC permite members adicionales). **Alternativa descartada:** meter `code` dentro de `type` como URI — más ceremonioso, menos ergonómico para el cliente TS.

### D3 — Paginación centralizada en `BaseRepository`, envelope 0-based

Se agrega `paginate(select_sql, count_sql, *args, page, size)` a `BaseRepository` que calcula `offset = page*size`, ejecuta el SELECT paginado y el COUNT, y arma `{items, total, page, pages}` con `pages = ceil(total/size)` (y `pages=0` si `total=0`, sin división por cero). `page` es 0-based (coincide con lo que sales/purchases ya hacen con `page/page_size`, minimizando el delta del frontend). Se introduce un `PageOut[T]` genérico Pydantic (`items: list[T]; total: int; page: int; pages: int`) reutilizable, reemplazando `SalesPageOut`/`PurchasesPageOut`/`PaymentReceiptsPageOut`. **Alternativa descartada:** cursor pagination — mejor para scroll infinito, pero el frontend actual es paginado clásico y `total`/`pages` son necesarios para la UI; cursores serían un cambio de UX no pedido.

### D4 — `Idempotency-Key` por header con fallback de body deprecado

Se agrega un dependency `idempotency_key: str = Depends(require_idempotency_key)` que lee el header `Idempotency-Key` y, si falta, cae al `idempotency_key` del body (compatibilidad), con precedencia del header. Si ninguno está → 422 `idempotency_key_required`. Los schemas de mutación marcan `idempotency_key` como opcional+deprecado (deja de ser required en el body) pero la RPC lo sigue recibiendo igual — el transporte cambia, no el backing store. Ventana de compatibilidad: el frontend migra a header en el mismo change; el body-fallback se puede quitar en un change posterior. **Alternativa descartada:** romper el body de una (BREAKING duro) — innecesario, el fallback cuesta poco y evita coordinar deploy backend/frontend al segundo.

### D5 — `cash_session_close`: migración gobernada al CHECK (Lección C3)

Cerrar caja gana idempotencia real, lo que exige el `operation_kind` nuevo `cash_session_close`. La migración recrea el CHECK enumerando la **unión vigente** (`sale, purchase, payment_received, payment_made, supplier_charge, bank_movement, event_consumer, bank_statement_import, cash_session_close`), verificada con `pg_get_constraintdef` en prod **antes** de escribirla (ya hecho en el propose). Migración idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`), aplicada por CI al mergear (`npx supabase db push`, nunca MCP). El RPC de cierre de caja pasa a registrar en `operation_idempotency` con ese kind dentro de su transacción. **Alternativa descartada:** idempotencia solo a nivel service (dedupe en memoria/Redis) — no atómica con el cierre, perdería la garantía que da la tabla.

### D6 — DEC-24: el UoW de Aliadata son los RPCs SECURITY DEFINER

Se documenta en `knowledge-base/09_decisiones_y_supuestos.md` (numerada DEC-24, la última es DEC-23): el patrón "Router→Service→UoW→Repository, ningún service comitea" (Food Store §6, RN-C1) **ya se satisface** porque la transacción de escritura vive en Postgres (RPC `SECURITY DEFINER`), no en un UoW de Python. Los services son stateless, orquestan y llaman RPCs vía `BaseRepository.call_rpc`; el commit/rollback es atómico en la DB. **No se implementa un UoW de Python** — sería duplicar la transacción que ya garantiza el motor y contradiría DEC-13 (JWT-passthrough) y el diseño de RPCs del proyecto. Es una decisión a asentar, no un refactor.

## Risks / Trade-offs

- **[Cambio de shape de error rompe parsing del frontend]** → El frontend hoy lee `error.detail` (string). El envelope 7807 **mantiene `detail`** como campo top-level, así que el parsing actual sigue funcionando; `code`/`field` son aditivos. Riesgo bajo; se verifica en el apply que ningún consumidor asuma que `detail` es un array (el 422 default sí lo era — ahí el cambio a string+`field` es una mejora, pero hay que revisar los pocos lugares que lo consumían).
- **[Rename de `total_operations`/`total` → `total` en envelope]** → BREAKING para hooks que leen esos nombres. Mitigación: migrar los hooks/servicios TS en el mismo change; el `PageOut` genérico usa `total` (nombre que payments ya usa), minimizando cambios.
- **[Migración del CHECK aplicada por integración GitHub de Supabase antes del `db push`]** → Descubrimiento registrado: la integración auto-aplica al mergear. Mitigación: migración idempotente obligatoria (`IF EXISTS`), verificada en CI; Actions rojo ≠ migración sin aplicar.
- **[Body-fallback deprecado se vuelve permanente]** → Deuda si no se limpia. Mitigación: el fallback queda marcado deprecado en schemas con un TODO ligado a un change de limpieza posterior; no bloquea.
- **[Regresión silenciosa en paginación al reemplazar 3 shapes por 1]** → Mitigación: Strict TDD en el apply cubre cada listado migrado con test de envelope + borde (página fuera de rango, total 0); la suite (~960) es la red.

## Migration Plan

1. **DB:** una migración idempotente que recrea `operation_idempotency_operation_kind_check` con la unión vigente + `cash_session_close`. Se aplica sola por CI al mergear (no pedir `db push` manual).
2. **Backend:** (a) envelope 7807 en `errors.py` + handlers nuevos en `main.py`; (b) `PageOut[T]` + `BaseRepository.paginate()`; (c) `require_idempotency_key` dependency; (d) migrar routers/schemas de listados al `PageOut` y de mutaciones al header; (e) RPC/service de cerrar caja registra idempotencia.
3. **Frontend:** adaptar hooks que leen `total_operations`/`total` al envelope y los que mandan `idempotency_key` en body al header.
4. **KB:** agregar DEC-24.
5. **Rollback:** el shape 7807 y el envelope son aditivos-compatibles en `detail`/`items`; revertir el frontend y el body-fallback restaura el comportamiento previo. El `operation_kind` extra es inocuo si no se usa (no rompe filas existentes).

## Open Questions

- **OQ1 — Alcance del rollout de paginación en este change.** ¿Migramos los 6+ listados divergentes de una, o solo los de más tráfico (sales/purchases/payments) ahora y dejamos customer/supplier/journal para un follow-up? Recomendación: todos, porque el `PageOut` genérico hace el costo marginal por listado bajo y evita dejar el estándar a medias.
- **OQ2 — Ventana del body-fallback de `Idempotency-Key`.** ¿El fallback de body se quita en este change (BREAKING coordinado) o se difiere a un change de limpieza? Recomendación: diferir (menos coordinación de deploy), marcando deprecado.
- **OQ3 — `cash_session_close` idempotency: ¿parte de este change o del change de cash?** Agregar el `operation_kind` + registro es una migración gobernada (BAJO→toca DB). Recomendación: incluirlo aquí (es el único gap que impide "toda mutación tiene Idempotency-Key"), con sign-off explícito de que es solo-transporte + un kind nuevo, sin cambiar el arqueo.
- **OQ4 — Prefijo `/api/v1` versionado.** El V3 §6.2 lo menciona. ¿Los routers ya montan bajo un prefijo? Si no, ¿entra aquí o es ruido para un change de estándares de error/paginación? Recomendación: fuera de alcance salvo que sea trivial — el prefijo es un cambio de routing que afecta a todos los consumidores y merece su propio change.
