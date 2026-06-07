## MODIFIED Requirements

### Requirement: Router registration

The FastAPI application in `backend/main.py` SHALL register all domain routers including the payments router.

All registered routers:
- `health.router`
- `ws.router`
- `expenses.router` (C-16)
- `clients.router` (C-16)
- `products.router` (C-16)
- `branches.router` (C-16)
- `stock.router` (C-16)
- `sales.router` (C-16)
- `purchases.router` (C-16)
- `organizations.router` (C-16)
- `payments.router` ← C-17 addition, prefix `/payments`

#### Scenario: Payments router is reachable

- **WHEN** a client sends `POST /payments/webhook`
- **THEN** the request is routed to `backend/routers/payments.py`

## ADDED Requirements

### Requirement: Service-role pool initialization

The `backend/core/database.py` module SHALL expose a `get_service_pool()` async context that provides a connection using the Supabase service_role key, separate from the user JWT pool.

#### Scenario: Service pool is initialized at startup

- **WHEN** the FastAPI application starts
- **THEN** `init_service_pool()` is called during lifespan and `get_service_pool()` returns a valid asyncpg connection

#### Scenario: Only payments router uses the service pool

- **WHEN** any router other than `payments` is called
- **THEN** it uses the JWT-passthrough pool, not the service pool
