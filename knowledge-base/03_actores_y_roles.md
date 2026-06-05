# 03 — Actores y Roles

## Actores del Sistema

### 1. Emprendedor (Usuario Final)
- Microemprendedor de Mendoza, Argentina
- Puede tener plan `free` o plan `pro`
- Durante la beta: todos los usuarios tienen plan `pro` automáticamente
- Accede a las rutas de `(dashboard)` excepto las de `/admin/*`
- Gestiona sus propios datos (ventas, compras, gastos, productos, clientes)

### 2. Admin (Operador de la Plataforma)
- Operador interno de EmprendeSmart
- Tiene acceso total a todas las rutas incluyendo `/admin/*`
- Puede leer datos de todos los usuarios (via `auth.uid()` sin restricción de RLS en tablas admin)
- Gestiona: cursos, reuniones, pools de compra, landing, seguros, analytics de plataforma
- No puede leer datos financieros de usuarios en tablas con RLS (solo via RPC agregadas)

### 3. Sistema (sin actor humano)
- Supabase Webhooks y Triggers automáticos
- Dispara: alertas de stock bajo, emails de bienvenida, notificaciones de reuniones/pools
- Actúa con `service_role` (bypasa RLS)

---

## Tabla RBAC

| Recurso / Acción | Emprendedor Free | Emprendedor Pro | Admin |
|---|---|---|---|
| **Ventas** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Compras** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Gastos** — CRUD propias | ✅ | ✅ | Solo lectura agregada |
| **Productos** — CRUD (hasta 20) | ✅ (máx 20) | ✅ (ilimitado) | — |
| **Clientes** — CRUD (hasta 100) | ✅ (máx 100) | ✅ (ilimitado) | — |
| **Stock** — consulta e inventario | ✅ | ✅ | — |
| **Insights IA** | ✅ (máx 5/período) | ✅ (ilimitado) | Ver métricas uso |
| **Copiloto IA** | ✅ | ✅ | — |
| **Simulador IA** | Limitado | ✅ completo | — |
| **Fair Advisor** | ✅ | ✅ | Ver métricas |
| **OCR Facturas** | ✅ | ✅ | — |
| **Cursos** — ver | Solo básicos | Todos | CRUD completo |
| **Comunidad** — leer | ✅ | ✅ | ✅ + moderar |
| **Comunidad** — publicar | ❌ | ✅ | ✅ |
| **Reuniones** — ver | ✅ | ✅ | CRUD |
| **Pools de compra** — ver | ✅ | ✅ | CRUD |
| **Configuración** — perfil propio | ✅ | ✅ | — |
| **Admin métricas** | ❌ | ❌ | ✅ |
| **Admin cursos** | ❌ | ❌ | ✅ |
| **Admin landing** | ❌ | ❌ | ✅ |
| **Email logs** — leer | ❌ | ❌ | ✅ |

> **Nota**: Durante la beta actual (junio 2026), todos los emprendedores tienen plan `pro`. Las restricciones del plan `free` están definidas en `lib/constants.ts` pero aún no hay billing que habilite el downgrade.

---

## Campos de Rol y Plan en `profiles`

```sql
role  TEXT  DEFAULT 'user'   -- valores: 'user' | 'admin'
plan  TEXT  DEFAULT 'pro'    -- valores: 'free' | 'pro'
                              -- (default fue 'free', migration 20260424000001 lo cambió a 'pro' para beta)
```

## Planes Comerciales (4 planes — fuente: tabla_resumen_planes_aliadata.docx)

| Límite | Gratis | Inicial | Avanzado ⭐ | PRO |
|---|---|---|---|---|
| Precio/mes | $0 | $24.900+IVA | $34.900+IVA | $69.900+IVA |
| Usuarios | 1 | 2 | 5 | 10 |
| Productos | 100 | 500 | 1.500 | 5.000 |
| Clientes | 50 | 250 | 1.000 | 3.000 |
| Proveedores | 20 | 100 | 300 | 1.000 |
| Operaciones/mes | 100 | 500 | 2.000 | 6.000 |
| Historial | 30 días | 12 meses | 24 meses | 5 años |
| Exportaciones/mes | 0 | 3 | 15 | 50 |
| Consultas IA/mes | 5 | 30 | 120 | 300 |
| Consejos IA/mes | 3 | 15 | 60 | 150 |
| Rentabilidad por producto | ❌ | ❌ | ✅ | ✅ |
| Reportes comparativos | ❌ | ❌ | ✅ | ✅ |
| Roles internos | ❌ | ❌ | Básicos | Avanzados |
| Sucursales (módulo) | ❌ | ❌ | ❌ | ✅ |
| Sesión análisis mensual | ❌ | ❌ | ❌ | ✅ |

> ⭐ Plan recomendado en la propuesta comercial.

> **Nota sobre el schema actual**: `profiles.plan` solo tiene `'free'` y `'pro'`. Deberá migrarse a los 4 valores reales al implementar billing. Los valores actuales de `lib/constants.ts` (maxProducts: 20 para free, Infinity para pro) serán reemplazados por la tabla anterior.

## Tracking de Uso IA (en `profiles`)

```sql
insights_used       INTEGER    DEFAULT 0        -- conteo acumulado de insights generados
insights_reset_at   TIMESTAMP  DEFAULT NOW()    -- última vez que se reseteó el contador
```

## RLS (Row Level Security) — Resumen por Tabla

| Tabla | Lectura | Escritura | Borrado |
|---|---|---|---|
| `profiles` | Propio o admin | Propio | No |
| `products` | Propio | Propio | Propio |
| `sales` | Propio | Propio (via RPC) | Propio |
| `purchases` | Propio | Propio (via RPC) | Propio |
| `expenses` | Propio | Propio | Propio |
| `clients` | Propio | Propio | Propio |
| `stock_movements` | Propio | Solo via RPC | No |
| `ai_insights` | Propio | Propio | Propio |
| `ai_conversations` | Propio | Propio | Propio |
| `fair_recommendations` | Propio | Sistema | No |
| `posts` | Público | Auth | Propio o admin |
| `replies` | Público | Auth | Propio o admin |
| `courses` | Público | Admin | Admin |
| `course_progress` | Propio | Propio | No |
| `meetings` | Público | Admin | Admin |
| `purchase_pools` | Público | Admin | Admin |
| `analytics_events` | Admin | Auth (propio) | No |
| `email_logs` | Admin | Sistema | No |
| `invoice_documents` | Propio | Propio | Propio |
| `operation_idempotency` | Propio | Solo via RPC | No |

## Rutas Públicas (sin autenticación)

- `/` — Landing page
- `/landing` — Versión alternativa de landing
- `/auth/login`
- `/auth/register`
- `/auth/forgot-password`
- `/auth/reset-password`
- `/auth/verify-email`

## Middleware de Autenticación

`middleware.ts` corre en todas las rutas excepto:
- `/_next/static/*`
- `/_next/image/*`
- `/favicon.ico`
- Archivos de media

Llama a `updateSession()` para refrescar el token JWT de Supabase en cada request.

## Futuros Roles (Planificados, no implementados)

Según el usuario, se planean más roles en el futuro (pendiente de documentación — ver `10_preguntas_abiertas.md`).
