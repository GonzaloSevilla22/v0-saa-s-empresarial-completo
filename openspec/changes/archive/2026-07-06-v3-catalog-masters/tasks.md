## 1. UoM — formalización documental (sin código, sin migración)

- [x] 1.1 Corregir la ficha de `units_of_measure` en `knowledge-base/04_modelo_de_datos.md`: enum real de `type` (`unit|weight|volume|length|custom`), catálogo mixto (`is_system` global + `account_id` per-tenant), y RLS vigente. Nota: la capability `units-of-measure` se sincroniza a `openspec/specs/` en el archive.
- [x] 1.2 Registrar OQ1 (alineación del enum a `peso|volumen|contable`) como pendiente del PO en `CHANGES.md` — NO ejecutar el rename en este change.

## 2. Migración DB — `client_addresses` (idempotente, both-worlds-safe)

- [x] 2.1 Crear `supabase/migrations/2026081300xxxx_v3_client_addresses.sql` (timestamp > `20260812000001`; verificar con `ls supabase/migrations | sort | tail -3`). Header con QUÉ HACE / GOVERNANCE BAJO / IDEMPOTENCIA / APPLY vía CI / ROLLBACK.
- [x] 2.2 `CREATE TABLE IF NOT EXISTS public.client_addresses`: `id uuid PK`, `account_id uuid NOT NULL` (FK accounts), `client_id uuid NOT NULL` (FK clients, sin ON DELETE CASCADE), `alias text`, `street text`, `city text`, `province text`, `postal_code text`, `notes text`, `is_primary boolean NOT NULL DEFAULT false`, `created_at timestamptz NOT NULL DEFAULT now()`, `updated_at timestamptz`, `deleted_at timestamptz`, `deleted_by uuid`.
- [x] 2.3 Índices `IF NOT EXISTS`: FK `account_id`, FK `client_id`, y el único parcial de la invariante: `CREATE UNIQUE INDEX ... ON client_addresses (client_id) WHERE is_primary AND deleted_at IS NULL`.
- [x] 2.4 `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + 4 policies idempotentes (`DROP POLICY IF EXISTS` + `CREATE POLICY`) replicando `clients`: SELECT `account_id IN current_account_ids()`; INSERT `WITH CHECK is_account_writer(account_id)`; UPDATE `USING + WITH CHECK is_account_writer(account_id)`; DELETE `USING is_account_writer(account_id)`.
- [x] 2.5 `CREATE OR REPLACE FUNCTION public.rpc_set_primary_client_address(p_address_id uuid, p_account_id uuid)`: en una transacción, valida que la dirección pertenezca a la cuenta y esté viva, baja `is_primary` de la primaria vigente de ese `client_id`, sube la nueva. `SECURITY DEFINER` con `SET search_path = public` solo si hace falta; preferir INVOKER + RLS. Devuelve la dirección resultante.
- [x] 2.6 Gate de comportamiento auto-limpiante (`DO $$`): anchor sintético en `auth.users` → resolver account vía `account_members` → crear cliente → insertar 2 direcciones (assert: la 1ª es primaria; el switch a la 2ª deja exactamente una primaria; intentar 2 primarias directas colisiona el índice). Limpieza hijo→padre por email del anchor (`accounts=0`). Degrada con `RAISE NOTICE` si el contexto no permite el gate. `EXCEPTION WHEN OTHERS` con best-effort cleanup.

## 3. Backend — capa de datos y allowlist

- [x] 3.1 (RED) Test de repositorio: `list_by_client` excluye borrados y filtra por `account_id`; `create` marca primaria la primera; `set_primary` delega en el RPC. Escribir el test antes del repo.
- [x] 3.2 (GREEN) `backend/repositories/client_address_repository.py` extendiendo `BaseRepository` (usa `not_deleted_clause`); métodos `list_by_client`, `get_by_id`, `create`, `update`, `set_primary` (llama al RPC), `count_live_for_client`.
- [x] 3.3 Agregar `"client_addresses"` a `SOFT_DELETE_TABLES` en `backend/repositories/base.py` (scope directo por `account_id`).

## 4. Backend — schemas Pydantic v2

- [x] 4.1 `backend/schemas/client_addresses.py`: `ClientAddressCreate`, `ClientAddressUpdate` (todos opcionales), `ClientAddressOut` (`from_attributes=True`). Sin lógica en los schemas.

## 5. Backend — servicio (guards + orquestación de primaria)

- [x] 5.1 (RED) Tests de servicio: `require_role(["user","admin"])`; crear la primera dirección la marca primaria; `set_primary` sobre dirección de otro cliente/cuenta → 404/rechazo; borrar dirección es soft. Escribir antes del service.
- [x] 5.2 (GREEN) `backend/services/client_addresses.py`: valida que el cliente exista y esté vivo (404 si no) antes de cualquier operación; auto-primaria en la primera; `set_primary` invoca el RPC; `delete` usa `BaseRepository.soft_delete("client_addresses", ...)`.

## 6. Backend — router (endpoints anidados)

- [x] 6.1 (RED) Tests de endpoint (TestClient): GET/POST/PUT/DELETE `/clients/{client_id}/addresses[/{address_id}]` + `POST .../{address_id}/set-primary`; 201/200/204; 404 con cliente inexistente/borrado; aislamiento por cuenta. Escribir antes del router.
- [x] 6.2 (GREEN) Endpoints en `backend/routers/clients.py` (o `routers/client_addresses.py` montado bajo `/clients`): parse-call-return, `Depends(get_current_user)`, `Depends(get_account_id)`, `Depends(get_repo)`.
- [x] 6.3 (TRIANGULATE) Segundo caso por endpoint (happy + edge): p. ej. set-primary idempotente (marcar la ya-primaria no rompe); crear 2ª dirección no-primaria no toca la 1ª.

## 7. Frontend — solo contrato de tipos (sin UI)

- [x] 7.1 Agregar `export interface ClientAddress` en `frontend/lib/types.ts` (campos alineados a `ClientAddressOut`, sin `any`, PascalCase de campos en camelCase). Sin componentes.

## 8. Verificación y cierre

- [x] 8.1 Correr la suite pytest completa: baseline 912 verde preservada + nuevos tests de `client_addresses`.
- [x] 8.2 Actualizar `knowledge-base/04_modelo_de_datos.md` con la nueva ficha `client_addresses` y el ERD (relación `clients (1:N) client_addresses`).
- [x] 8.3 Marcar el change en `CHANGES.md` §"Roadmap Modelo V3" con las decisiones D1–D6 y las OQ1–OQ3 para el PO.
- [x] 8.4 `openspec validate "v3-catalog-masters" --strict` verde antes de abrir PR. Commits convencionales; rama nueva off main; PR (no commitear a main).
