## ADDED Requirements

### Requirement: Repositorios concretos por dominio extienden BaseRepository
El sistema SHALL proveer una clase repositorio concreta por dominio en `backend/repositories/<domain>.py`. Cada clase extiende `BaseRepository` (C-15) sin constructor propio y expone métodos con nombres de negocio (`list_by_org`, `get_by_id`, `create`, `update`, `delete`) que internamente usan `fetch`, `fetchrow`, `execute` o `call_rpc` de la clase base. Los dominios cubiertos son: `ExpenseRepository`, `ClientRepository`, `ProductRepository`, `BranchRepository`, `StockRepository`, `SalesRepository`, `PurchaseRepository`, `OrganizationRepository`.

#### Scenario: ExpenseRepository.list_by_org retorna gastos de la org activa
- **WHEN** se llama `await repo.list_by_org(org_id=uuid, filters={})` con una conexión JWT-passthrough activa
- **THEN** ejecuta un SELECT filtrado por `org_id` y retorna una `list[asyncpg.Record]` con solo los gastos de esa organización (RLS valida además en PostgreSQL)

#### Scenario: SalesRepository.create_operation llama al RPC atómico existente
- **WHEN** se llama `await repo.create_operation(idempotency_key="...", items=[...])` 
- **THEN** ejecuta `await self.call_rpc("rpc_create_operation_aggregate", ...)` y retorna el `operation_id` del resultado; si la clave ya existe el RPC retorna el operation_id previo (idempotente)

#### Scenario: ProductRepository.get_by_id retorna None para producto de otra org
- **WHEN** se llama `await repo.get_by_id(product_id)` con un JWT de org A y el producto pertenece a org B
- **THEN** retorna `None` porque RLS filtra la fila (no lanza excepción — el service convierte None en HTTP 404)

#### Scenario: StockRepository.transfer llama a rpc_transfer_stock
- **WHEN** se llama `await repo.transfer(from_branch_id, to_branch_id, product_id, quantity)`
- **THEN** ejecuta `await self.call_rpc("rpc_transfer_stock", ...)` y retorna el resultado; si `from_branch` no tiene stock suficiente la RPC lanza CHECK violation que se propaga como `asyncpg.CheckViolationError`

#### Scenario: ClientRepository.create persiste un cliente nuevo
- **WHEN** se llama `await repo.create(org_id=uuid, name="...", email="...", phone="...")`
- **THEN** ejecuta INSERT en `clients` y retorna el registro creado; si el email ya existe para esa org lanza `asyncpg.UniqueViolationError`

### Requirement: Repositorios no acceden al pool directamente
Los repositorios concretos SHALL recibir siempre una conexión asyncpg ya configurada con JWT-passthrough via `get_db_conn` (C-15). Ningún repositorio SHALL importar ni referenciar el objeto `pool` directamente.

#### Scenario: Repositorio instanciado en endpoint con conexión del request
- **WHEN** un endpoint recibe `conn: asyncpg.Connection = Depends(get_db_conn)` e instancia `repo = ExpenseRepository(conn)`
- **THEN** el repositorio opera sobre esa conexión sin abrir una nueva; JWT-passthrough ya está activo

#### Scenario: Repositorio no puede instanciarse sin conexión
- **WHEN** se intenta instanciar `ExpenseRepository()` sin pasar `conn`
- **THEN** Python lanza `TypeError` por el parámetro requerido en el constructor heredado de `BaseRepository`
