## Context

Change de retrofit del Modelo V3 (`modelo-dominio-aliadata-v3.md` §7.1 y §7.3), governance **BAJO** (maestros/catálogo). Se verificó la base de prod (`gxdhpxvdjjkmxhdkkwyb`, ~29 cuentas) ANTES de diseñar, porque los supuestos de `CHANGES.md` sobre estos maestros ya fallaron dos veces esta semana. Lo verificado cambió el alcance real respecto de lo escrito en el roadmap.

**Estado real en prod (verificado):**

`units_of_measure` (10 filas, todas `is_system=true`, **0 filas per-tenant**):
```
id uuid PK · user_id uuid NULL · name text NOT NULL · symbol text NOT NULL
type text NOT NULL  CHECK (type IN ('unit','weight','volume','length','custom'))
factor numeric NOT NULL DEFAULT 1.0 · base_unit_id uuid NULL (self-FK)
is_system bool NOT NULL DEFAULT false · created_at timestamptz NOT NULL DEFAULT now()
account_id uuid NULL (FK accounts)
```
RLS (org-based, ya vigente): SELECT `is_system=true OR account_id IN current_account_ids()`; INSERT/UPDATE/DELETE `is_system=false AND account_id IN current_account_ids()`. Es decir: catálogo **mixto** — las system rows son globales (visibles a todo tenant), las custom son per-cuenta. El frontend expone `UnitOfMeasure` en `frontend/lib/types.ts` con el mismo enum de `type`. No se encontró ningún hook/form que consuma unidades hoy (el catálogo existe pero no está cableado a la UI del producto).

`clients` (16 columnas, **ninguna de dirección**):
```
id · user_id (DEFAULT auth.uid()) · name · email · phone · created_at
status (DEFAULT 'activo') · category · company_id · account_id
tax_id · legal_name · iva_condition · credit_limit
deleted_at · deleted_by            ← soft delete ya aplicado (v3-soft-delete-policy)
```
RLS: SELECT `account_id IN current_account_ids()`; INSERT/UPDATE/DELETE `is_account_writer(account_id)`. 1121 clientes vivos. La API FastAPI de clientes ya existe (router/service/repository/schemas/tests) y usa `BaseRepository` con `soft_delete()` + `not_deleted_clause()`.

**Constraint de plataforma (confirmado 3×):** la integración GitHub de Supabase auto-aplica las migraciones al mergear a `main` ANTES del `db push` de Actions → toda migración DEBE ser idempotente / both-worlds-safe. Los gates de CI corren sobre un Postgres vacío efímero; `handle_new_user` (trigger real) además siembra branch + cashbox desde `20260812000001`.

## Goals / Non-Goals

**Goals:**
- Formalizar `units-of-measure` como capability con contrato explícito (unidad tipada, catálogo mixto global/per-tenant, factor relativo a la base del mismo tipo) **sin tocar el schema** — el requisito físico del V3 §7.1 ya está en la DB.
- Introducir `client_addresses`: direcciones operativas múltiples por cliente con `alias`, invariante **exactamente una primaria por cliente** (entre filas vivas), soft-delete y switch atómico de la primaria.
- Entregar el corte más chico y coherente: **DB + API**, con contrato de tipos TS. Governance BAJO ⇒ autonomía plena si los tests pasan.

**Non-Goals:**
- **NO** renombrar el enum de `units_of_measure.type` a la nomenclatura canónica del V3 (`peso|volumen|contable`). Es BREAKING (CHECK + tipo del frontend + colapso de `length`/`custom`) y no aporta valor funcional hoy (0 filas per-tenant, conversión es V3.5). Queda como OQ / decisión del PO.
- **NO** implementar conversión entre unidades (capability V3.5).
- **NO** globalizar el catálogo de unidades más allá de lo ya vigente (`is_system` ya da el catálogo global). No se agregan unidades nuevas.
- **NO** tocar la dirección FISCAL (vive en `FiscalIdentity`, inmutable por snapshot). `client_addresses` son SOLO operativas/editables.
- **NO** UI en este change (alta/edición de direcciones en el form de cliente se difiere). Solo el tipo TS `ClientAddress`.
- **NO** backfill de direcciones para los 1121 clientes: nadie tenía dirección antes; la tabla nace vacía.

## Decisions

### D1 — UoM: spec-only, cero DDL. La alineación del enum se difiere.
`type` ya es `NOT NULL` con CHECK y 10 system rows tipadas. El V3 §7.1 pide "persistir el tipo desde ahora para habilitar la conversión sin migración futura" — **ya está persistido**. Por lo tanto la mitad UoM de este change es **documental**: crea `specs/units-of-measure/spec.md` fijando las invariantes (toda unidad porta `type`; `factor` es relativo a la unidad base del mismo `type`; la conversión V3.5 solo opera dentro del mismo `type`; catálogo mixto global+per-tenant).
- **Alternativa considerada (rechazada):** renombrar `unit|weight|volume|length|custom` → `contable|peso|volumen|...`. Rechazada: BREAKING, toca frontend, colapsa dos valores (`length`, `custom`) sin destino claro, y no habilita nada que hoy se use. Se documenta como **OQ1** para el PO. Si el PO lo aprueba luego, es su propio change chico con migración de datos + CHECK swap + type frontend.
- **Consecuencia:** el spec habla de tipos semánticos (peso/volumen/conteo) mapeando a los valores físicos vigentes, sin obligar a renombrarlos.

### D2 — `client_addresses`: tabla nueva con `account_id` DIRECTO.
Se agrega `account_id uuid NOT NULL` (además de `client_id`) para que el scope de tenancy sea **directo**, igual que `clients`, y así:
- Las 4 RLS policies pueden reutilizar `current_account_ids()` / `is_account_writer(account_id)` sin un JOIN a `clients` en cada policy (más simple y más barato que resolver el tenant vía `client_id → clients.account_id`).
- Habilita el patrón de `BaseRepository.soft_delete()` (allowlist con scope directo por `account_id`) — misma familia que `clients`/`products`.
- **Alternativa (rechazada):** scope indirecto solo por `client_id` (como `cashboxes` vía `branch_id`). Rechazada porque `cashboxes` fue justamente la excepción problemática del soft-delete (quedó fuera de la allowlist, deuda documentada). No repetir ese patrón cuando el scope directo es trivial acá.
- **FK:** `client_id → clients(id)` sin `ON DELETE CASCADE` (el borrado del cliente es SOFT, nunca hard; un cascade duro no aplica). `account_id → accounts(id)`. Ambas FKs indexadas.

### D3 — Invariante "exactamente una primaria": índice único parcial + RPC de switch atómico.
- **Enforcement declarativo:** `CREATE UNIQUE INDEX ... ON client_addresses (client_id) WHERE is_primary AND deleted_at IS NULL`. Garantiza *como máximo una* primaria viva por cliente a nivel DB (dos INSERT/UPDATE concurrentes que intenten marcar primaria colisionan).
- **Switch atómico:** RPC `rpc_set_primary_client_address(p_address_id, p_account_id)` que en una transacción baja `is_primary` de la primaria vigente del cliente y sube la nueva. Evita la ventana en que el índice parcial rechazaría un UPDATE naïve (subir la nueva antes de bajar la vieja → violación transitoria). El servicio llama al RPC en vez de dos UPDATEs sueltos.
- **"Al menos una" (opcional):** la invariante fuerte del V3 es "exactamente una". Se implementa como: la PRIMERA dirección de un cliente se marca `is_primary=true` automáticamente (en el service, si el cliente no tiene ninguna viva); borrar la única/primaria deja al cliente sin primaria hasta que se marque otra (no se auto-promueve — se documenta como comportamiento, evita magia sorpresiva). El "exactamente una" se garantiza en el camino feliz (siempre hay ≥1 tras el primer alta) sin un trigger que bloquee el borrado de la última.
- **Alternativa (rechazada):** trigger `BEFORE INSERT/UPDATE` que fuerce el desmarcado de las demás. Rechazado: el RPC es explícito, testeable y no esconde efectos en un trigger; el índice parcial ya es la red de seguridad declarativa.

### D4 — Soft-delete del cliente padre: sin cascade, inalcanzable por lectura.
Cuando un cliente se soft-deletea (`deleted_at` set), sus direcciones **no** se tocan (no hay cascade — el soft delete del cliente es un UPDATE, no un DELETE). Las lecturas de direcciones **siempre** parten de un cliente vivo (el endpoint valida que el `client_id` exista y esté vivo antes de listar/mutar direcciones), así que las direcciones de un cliente borrado quedan lógicamente inalcanzables sin necesidad de propagarles `deleted_at`. Las propias direcciones tienen su `deleted_at`/`deleted_by` para el borrado individual de una dirección.
- **Alternativa (rechazada):** propagar el soft-delete a las direcciones (trigger que copie `deleted_at`). Rechazado: innecesario para la corrección (inalcanzables igual) y agrega un trigger que habría que revertir al restaurar un cliente. Se documenta como OQ2 por si el PO quiere reactivación de cliente con sus direcciones intactas (el diseño actual ya lo soporta: reactivar el cliente vuelve a hacer alcanzables sus direcciones no borradas).

### D5 — API: endpoints anidados bajo el cliente, 3 capas, reutilizando `BaseRepository`.
- Rutas: `GET /clients/{client_id}/addresses`, `POST /clients/{client_id}/addresses`, `PUT /clients/{client_id}/addresses/{address_id}`, `DELETE /clients/{client_id}/addresses/{address_id}`, `POST /clients/{client_id}/addresses/{address_id}/set-primary`.
- Capas: `routers/clients.py` (o un router propio `routers/client_addresses.py` montado bajo `/clients`) → `services/client_addresses.py` (guards `require_role(["user","admin"])`, orquesta el RPC de primaria) → `repositories/client_address_repository.py` (extiende `BaseRepository`, usa `not_deleted_clause`). Cada endpoint valida primero que el cliente exista y esté vivo (404 si no).
- Pydantic v2: `ClientAddressCreate`, `ClientAddressUpdate`, `ClientAddressOut`. Handlers parse-call-return, sin lógica.
- **`client_addresses` se agrega a `SOFT_DELETE_TABLES`** en `backend/repositories/base.py` (scope directo por `account_id` — cumple el requisito de la allowlist).

### D6 — Migración idempotente / both-worlds-safe + gate auto-limpiante.
- Todo el DDL con `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `DROP POLICY IF EXISTS` + `CREATE POLICY` (patrón idempotente para policies). Timestamp posterior a `20260812000001`.
- Gate de comportamiento en `DO $$` que: inserta un anchor sintético en `auth.users` (dispara `handle_new_user` → account + branch + cashbox), resuelve la account vía `account_members`, crea un cliente, inserta 2 direcciones probando el switch de primaria y la invariante (2ª marcada primaria baja la 1ª; intento de 2 primarias colisiona el índice), y limpia hijo→padre por email del anchor (`accounts=0` al final). Degrada con `RAISE NOTICE` si el contexto no permite el gate (prod real). Patrón idéntico a `20260811000001` y `20260812000001`.

## Risks / Trade-offs

- **[El índice único parcial rechaza un switch de primaria mal hecho]** → mitigado por el RPC `rpc_set_primary_client_address` que baja-antes-de-subir en una transacción; el service nunca hace dos UPDATEs sueltos.
- **[Ventana sin primaria tras borrar la única dirección primaria]** → aceptado y documentado (D3): no se auto-promueve otra. El "exactamente una" se sostiene en el camino de altas normal; forzarlo con un trigger que bloquee el borrado de la última complicaría el borrado del cliente. UI futura debe re-marcar una primaria.
- **[Enum de `type` desalineado con la nomenclatura V3]** → NO se corrige acá (D1). Riesgo puramente semántico/documental, cero impacto funcional. OQ1 al PO.
- **[Migración corre 2×+ por la integración GitHub]** → mitigado por D6 (todo idempotente).
- **[Gate rompe el reset de CI si deja basura]** → mitigado por limpieza hijo→padre por email del anchor y `EXCEPTION WHEN OTHERS` con best-effort cleanup (patrón ya probado en #268/#269).
- **[TDD estricto en apply]** → baseline suite pytest 912 verde; los nuevos tests de `client_addresses` deben preservarla (safety net antes de tocar `clients.py`).

## Migration Plan

1. **DB** (`2026081300xxxx_v3_client_addresses.sql`): CREATE TABLE `client_addresses` + índices (FK client_id, FK account_id, único parcial de primaria) + RLS (4 policies idempotentes) + `rpc_set_primary_client_address` + gate auto-limpiante. Cero DDL sobre `units_of_measure`.
2. **Backend:** schemas + repository (+ allowlist en `base.py`) + service + endpoints + tests (TDD: RED→GREEN→TRIANGULATE por endpoint e invariante).
3. **Frontend:** tipo `ClientAddress` en `frontend/lib/types.ts` (sin UI).
4. **Docs:** `knowledge-base/04_modelo_de_datos.md` (nueva ficha `client_addresses`; corregir la ficha de `units_of_measure` para reflejar el enum real y el catálogo mixto) + `CHANGES.md`.
5. **Deploy:** merge a `main` → GitHub Actions (build + Vercel + `db push`). NUNCA aplicar con el MCP `apply_migration`.
- **Rollback:** aditivo. En prod NO se dropea; se deja de escribir. Referencia de reversión en el header de la migración (DROP TABLE `client_addresses`, DROP FUNCTION del RPC, quitar `client_addresses` de `SOFT_DELETE_TABLES`).

## Open Questions

- **OQ1 (PO):** ¿Alinear el enum de `units_of_measure.type` a la nomenclatura canónica del V3 (`peso|volumen|contable`)? Es BREAKING (CHECK + `frontend/lib/types.ts` + colapsar `length`/`custom`). Este change NO lo hace; si se aprueba, es un change chico aparte con migración de datos. Hoy hay 0 filas per-tenant, así que el costo de datos es mínimo — el costo real es el frontend y el semántico.
- **OQ2 (PO):** ¿Se requiere reactivación de cliente con sus direcciones intactas? El diseño actual ya lo soporta (no se propaga soft-delete a direcciones). Confirmar que ese comportamiento es el deseado (vs. borrar las direcciones al borrar el cliente).
- **OQ3 (PO):** ¿Alcanza con dirección operativa "plana" (`street`, `city`, `province`, `postal_code`, `notes`) o el negocio necesita georreferencia / país / campos AR específicos (localidad vs. departamento)? Se propone lo mínimo y se amplía si el PO lo pide.
