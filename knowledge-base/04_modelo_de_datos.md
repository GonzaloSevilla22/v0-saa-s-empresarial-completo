# 04 — Modelo de Datos

## Convenciones del Schema

- **IDs**: UUID v4 en todas las entidades
- **Timestamps**: `created_at` (default `NOW()`) en todas las tablas; `updated_at` en profiles e invoice_documents (con trigger de auto-update)
- **Foreign Keys**: referencias a `auth.users(id)` para `user_id`; `ON DELETE CASCADE` o `SET NULL` según el contexto
- **Tipos de moneda**: `NUMERIC(15,2)` para dinero; `NUMERIC(15,4)` para cantidades de stock (soporte de fracciones)
- **RLS habilitado**: todas las tablas de usuario (ver `03_actores_y_roles.md`)

---

## Tablas Principales

### `profiles` — Perfil del Usuario
```sql
id              UUID        PK  REFERENCES auth.users
role            TEXT        DEFAULT 'user'      -- 'user' | 'admin'
plan            TEXT        DEFAULT 'pro'       -- 'free' | 'pro' (beta: todos pro)
name            TEXT
last_name       TEXT
business_name   TEXT
avatar_url      TEXT
phone           TEXT
bio             TEXT
currency        TEXT        DEFAULT 'ARS'       -- ARS | USD | EUR | BRL | CLP
timezone        TEXT        DEFAULT 'America/Argentina/Buenos_Aires'
date_format     TEXT        DEFAULT 'DD/MM/YYYY' -- DD/MM/YYYY | MM/DD/YYYY | YYYY-MM-DD
language        TEXT        DEFAULT 'es'
insights_used   INTEGER     DEFAULT 0
insights_reset_at TIMESTAMP DEFAULT NOW()
created_at      TIMESTAMP   DEFAULT NOW()
updated_at      TIMESTAMP   -- auto-update via trigger
```

---

### `products` — Catálogo de Productos
```sql
id                  UUID        PK
user_id             UUID        FK auth.users
name                TEXT
category            TEXT        -- Electrónica|Ropa|Alimentos|Hogar|Salud|Accesorios|Otros
price               NUMERIC(15,2)
cost                NUMERIC(15,2)
stock               NUMERIC(15,4)   -- fraccionario (ej: 0.5 kg)
min_stock           INTEGER
barcode             TEXT        UNIQUE(user_id, barcode)
sku                 TEXT        UNIQUE(user_id, sku)
parent_id           UUID        FK products(id)  -- para variantes
is_variant          BOOLEAN     DEFAULT FALSE
base_unit_id        UUID        FK units_of_measure(id)
stock_control_type  TEXT        -- 'tracked'|'untracked'|'variant_only'
created_at          TIMESTAMP
```

#### `product_attributes` — Atributos de Variantes
```sql
id          UUID    PK
product_id  UUID    FK products(id)
key         TEXT    -- ej: 'color', 'talle'
value       TEXT    -- ej: 'Rojo', 'XL'
sort_order  INTEGER
```

---

### `sales` — Ventas
```sql
id              UUID    PK
user_id         UUID    FK auth.users
client_id       UUID    FK clients(id) NULLABLE
product_id      UUID    FK products(id) ON DELETE SET NULL
operation_id    UUID    -- agrupa ítems del mismo carrito
amount          NUMERIC(15,2)   -- precio unitario × cantidad
quantity        NUMERIC(15,4)
unit_id         UUID    FK units_of_measure(id)
date            DATE
created_at      TIMESTAMP
```

### `purchases` — Compras a Proveedores
```sql
id              UUID    PK
user_id         UUID    FK auth.users
product_id      UUID    FK products(id) ON DELETE SET NULL
operation_id    UUID    -- agrupa ítems del mismo carrito
amount          NUMERIC(15,2)
quantity        NUMERIC(15,4)
description     TEXT
unit_id         UUID    FK units_of_measure(id)
date            DATE
created_at      TIMESTAMP
```

### `expenses` — Gastos
```sql
id          UUID    PK
user_id     UUID    FK auth.users
category    TEXT    -- Alquiler|Servicios|Marketing|Logística|Personal|Impuestos|Otros
amount      NUMERIC(15,2)
description TEXT
date        DATE
created_at  TIMESTAMP
```

---

### `clients` — Clientes
```sql
id          UUID    PK
user_id     UUID    FK auth.users
name        TEXT
email       TEXT
phone       TEXT
created_at  TIMESTAMP
```
> El campo `status` (activo/inactivo/perdido) y `category` se manejan en la lógica de app, no confirmados como columnas en la DB.

---

### `units_of_measure` — Unidades de Medida
```sql
id              UUID    PK
user_id         UUID    FK auth.users  NULLABLE  -- NULL = unidad del sistema
name            TEXT
symbol          TEXT
type            TEXT    -- unit|weight|volume|length|custom
factor          NUMERIC -- factor de conversión respecto a la unidad base
base_unit_id    UUID    FK units_of_measure(id) SELF-REF
is_system       BOOLEAN DEFAULT FALSE
```
**Unidades del sistema seed**: Unidad, Docena, Ciento, Gramo, Kilogramo, Litro, Mililitro, Metro, Centímetro.

---

### `stock_movements` — Libro Mayor de Stock (Ledger)
```sql
id                  UUID    PK
user_id             UUID    FK auth.users
product_id          UUID    FK products(id)
type                TEXT    -- purchase|sale|adjustment|return|initial|sale_return|
                            -- purchase_return|physical_count|loss|damage|expiry|
                            -- transfer_in|transfer_out
quantity_delta      NUMERIC(15,4)   -- puede ser negativo (salida)
quantity_before     NUMERIC(15,4)
quantity_after      NUMERIC(15,4)
reason              TEXT
notes               TEXT
reference_id        TEXT
reference_type      TEXT
performed_by        TEXT
metadata            JSONB
operation_group_id  UUID    -- vincula movimientos del mismo carrito
movement_number     INTEGER -- secuencial global para trazabilidad fiscal
created_at          TIMESTAMP
```

---

### `operation_idempotency` — Guardia Anti-Duplicado
```sql
id                  UUID    PK
user_id             UUID    FK auth.users
idempotency_key     TEXT    UNIQUE(user_id, idempotency_key)
operation_kind      TEXT    -- 'sale' | 'purchase'
operation_id        UUID    -- resultado: id del grupo de operación creado
created_at          TIMESTAMP
```

---

## Tablas de IA

### `ai_insights`
```sql
id          UUID    PK
user_id     UUID    FK auth.users
type        TEXT    -- ventas|stock|margen|rotacion|oportunidad|prediction|general|simulation
priority    TEXT    -- alta|media|baja
message     TEXT    -- insight con acción concreta y dato real
created_at  TIMESTAMP
```

### `ai_conversations` — Historial del Copiloto
```sql
id          UUID    PK
user_id     UUID    FK auth.users
question    TEXT
answer      TEXT
created_at  TIMESTAMP
```

### `fair_recommendations` — Recomendaciones para Ferias
```sql
id              UUID    PK
user_id         UUID    FK auth.users
recommendation  JSONB   -- [{product, reason, recommendedUnits, suggestedPrice}]
created_at      TIMESTAMP
```

---

## Tablas de Comunidad y Aprendizaje

### `posts` — Foro
```sql
id          UUID    PK
user_id     UUID    FK auth.users
title       TEXT
content     TEXT
created_at  TIMESTAMP
```

### `replies`
```sql
id          UUID    PK
post_id     UUID    FK posts(id)
user_id     UUID    FK auth.users
content     TEXT
created_at  TIMESTAMP
```

### `courses`
```sql
id          UUID    PK
title       TEXT
description TEXT
content     TEXT    -- contenido completo del curso
is_pro      BOOLEAN
level       TEXT    -- basico|intermedio|avanzado
category    TEXT
students    NUMERIC
rating      NUMERIC
created_at  TIMESTAMP
```

### `course_progress`
```sql
id          UUID    PK
course_id   UUID    FK courses(id)
user_id     UUID    FK auth.users
completed   BOOLEAN
created_at  TIMESTAMP
UNIQUE(course_id, user_id)
```

---

## Tablas de Marketplace Comunitario

### `meetings` — Reuniones / Eventos
```sql
id              UUID    PK
title           TEXT
description     TEXT
meeting_url     TEXT
start_time      TIMESTAMPTZ
created_at      TIMESTAMP
```

### `purchase_pools` — Pools de Compra Grupal
```sql
id              UUID    PK
title           TEXT
description     TEXT
target_amount   NUMERIC(15,2)
current_amount  NUMERIC(15,2)
closes_at       TIMESTAMPTZ
status          TEXT    -- open|closing|closed
created_at      TIMESTAMP
```

---

## Tablas de OCR / Facturas

### `invoice_documents`
```sql
id                      UUID    PK
user_id                 UUID    FK auth.users
storage_path            TEXT
original_name           TEXT
mime_type               TEXT
file_size_bytes         BIGINT
status                  TEXT    -- pending|processing|completed|failed
error_message           TEXT
processing_ms           INTEGER
ai_model                TEXT
ai_raw_response         JSONB
ai_confidence           NUMERIC(4,3)   -- 0 a 1
ai_warnings             TEXT[]
supplier_name           TEXT
supplier_cuit           TEXT
invoice_number          TEXT
invoice_date            DATE
invoice_type            TEXT
invoice_currency        TEXT    DEFAULT 'ARS'
invoice_total           NUMERIC(15,2)
parsed_items            JSONB   -- [{description, quantity, unit_price, total, product_match}]
purchase_operation_id   UUID    -- si fue confirmada como compra
created_at              TIMESTAMP
updated_at              TIMESTAMP   -- auto-update via trigger
UNIQUE INDEX (user_id, supplier_cuit, invoice_number)
```

### `invoice_suppliers` — Directorio de Proveedores
```sql
id          UUID    PK
user_id     UUID    FK auth.users
name        TEXT
cuit        TEXT
address     TEXT
email       TEXT
phone       TEXT
notes       TEXT
created_at  TIMESTAMP
updated_at  TIMESTAMP
UNIQUE(user_id, cuit)
```

### `product_aliases` — Aprendizaje OCR → Producto
```sql
id          UUID    PK
user_id     UUID    FK auth.users
product_id  UUID    FK products(id)
alias       TEXT    -- texto normalizado del OCR
source      TEXT    -- manual|auto
created_at  TIMESTAMP
UNIQUE(user_id, alias)
```

---

## Infraestructura

### `analytics_events`
```sql
id          UUID    PK
user_id     UUID    NULLABLE    FK auth.users
event_name  TEXT
event_data  JSONB
created_at  TIMESTAMP
```

### `email_logs`
```sql
id              UUID    PK
user_id         UUID    NULLABLE    FK auth.users
event_type      TEXT    -- welcome|meeting_notice|pool_notice|low_stock_alert|low_margin_alert
recipient       TEXT    -- email address o 'all_users'
subject         TEXT
status          TEXT    -- pending|sent|failed|partial
provider_id     TEXT    -- ID devuelto por Resend
error_details   TEXT
metadata        JSONB
created_at      TIMESTAMP
sent_at         TIMESTAMP
UNIQUE(user_id, event_type, metadata) NULLS DISTINCT
```

---

## Triggers Automáticos

| Trigger | Tabla | Evento | Acción |
|---|---|---|---|
| `check_low_stock` | `products` | AFTER INSERT/UPDATE | Si `stock ≤ min_stock`, inserta `email_logs` (debounce 24h) |
| `notify_meeting_created` | `meetings` | AFTER INSERT | Inserta `email_logs` con `event_type='meeting_notice'` |
| `notify_pool_created` | `purchase_pools` | AFTER INSERT | Inserta `email_logs` con `event_type='pool_notice'` |
| `trg_profiles_updated_at` | `profiles` | BEFORE UPDATE | Auto-actualiza `updated_at` |
| `trg_invoice_documents_updated_at` | `invoice_documents` | BEFORE UPDATE | Auto-actualiza `updated_at` |

---

## Storage Buckets

| Bucket | Visibilidad | Tamaño máx | Tipos | Path pattern |
|---|---|---|---|---|
| `avatars` | Público | 2 MB | jpg, png, webp, gif | `avatars/{user_id}/{filename}` |
| `invoices` | Privado | 20 MB | jpg, png, pdf | `invoices/{user_id}/{uuid}.{ext}` |

---

## ERD Simplificado (relaciones clave)

```
auth.users
    │
    ├── profiles (1:1)
    │
    ├── products (1:N)
    │       └── product_attributes (1:N)
    │       └── units_of_measure (N:1)
    │
    ├── sales (1:N) ── operation_id (agrupa carrito)
    │       └── clients (N:1)
    │       └── products (N:1)
    │       └── units_of_measure (N:1)
    │
    ├── purchases (1:N) ── operation_id
    │       └── products (N:1)
    │       └── units_of_measure (N:1)
    │
    ├── expenses (1:N)
    │
    ├── clients (1:N)
    │
    ├── stock_movements (1:N) ── operation_group_id
    │       └── products (N:1)
    │
    ├── operation_idempotency (1:N)
    │
    ├── ai_insights (1:N)
    ├── ai_conversations (1:N)
    ├── fair_recommendations (1:N)
    │
    ├── invoice_documents (1:N)
    │       └── invoice_suppliers (N:1)
    │       └── product_aliases (1:N)
    │
    ├── posts (1:N)
    │       └── replies (1:N)
    │
    ├── course_progress (1:N)
    │       └── courses (N:1)
    │
    └── analytics_events (1:N)
```
