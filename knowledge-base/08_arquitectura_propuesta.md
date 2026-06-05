# 08 — Arquitectura Propuesta

## Patrón Arquitectural: BaaS + Edge-First

EmprendeSmart adopta un patrón "BaaS-first" donde Supabase actúa como backend completo y Next.js solo contiene UI y lógica de presentación. La lógica de negocio crítica vive en:
1. **RPCs PostgreSQL**: operaciones atómicas multi-tabla (ventas, compras, stock)
2. **Edge Functions Deno**: integraciones externas (OpenAI, Resend) y procesamiento pesado (OCR)
3. **Triggers PostgreSQL**: automatizaciones en tiempo real (alertas, notificaciones)
4. **RLS**: autorización declarativa a nivel de fila (sin capa de API propia)

---

## Capa de Presentación (Next.js App Router)

### Server vs Client Components
```
Layout / Pages (Server Components por defecto)
    ├── Fetching inicial de datos → Supabase server client (sin round-trip)
    ├── Server Actions → mutaciones desde formularios (Next.js 13+)
    └── Client Components (marcados con 'use client')
            ├── Interactividad: modales, filtros, carrito, charts
            ├── Estado UI: Zustand (plan, notificaciones, preferencias)
            └── Cache de datos: TanStack React Query (invalidación, refetch)
```

### Supabase Clients — Tres instancias
| Instancia | Archivo | Uso | Auth |
|---|---|---|---|
| Server (RSC) | `lib/supabase/server.ts` | Server Components, Server Actions | Cookie-based JWT |
| Client | `lib/supabase/client.ts` | Client Components, hooks | Cookie-based JWT via @supabase/ssr |
| Middleware | `lib/supabase/middleware.ts` | `middleware.ts` (refresh session) | Cookie-based JWT |

### Gestión de Estado
```
Zustand (global, cliente)
    ├── User/plan state (sincronizado con profiles)
    ├── Notificaciones/toasts
    └── Preferencias UI (sidebar collapsed, etc.)

TanStack React Query (server state, cliente)
    ├── Fetching y cache de datos (products, sales, clients, etc.)
    ├── Invalidación automática post-mutation
    └── Optimistic updates en operaciones críticas

React Hook Form + Zod
    ├── Formularios de registro de operaciones
    ├── Validación client-side antes de llamada a RPC
    └── Schemas definidos en lib/ y compartidos con RPC inputs
```

---

## Capa de Datos (Supabase PostgreSQL)

### Estrategia de Acceso
```
Lectura normal    → supabase.from('table').select(...)  [filtrado por RLS automático]
Lectura admin     → supabase.from('table').select(...)  [con service_role: bypasa RLS]
Escritura simple  → supabase.from('table').insert(...)  [filtrado por RLS]
Escritura atómica → supabase.rpc('rpc_name', params)    [SECURITY DEFINER, bypasa RLS internamente]
```

### Índices de Performance
Las tablas de usuario con alto volumen tienen índices compuestos:
- `(user_id)` — todas las tablas (requerido por RLS initplan fix)
- `(user_id, date)` — sales, purchases (filtros por fecha)
- `(user_id, operation_id)` — sales, purchases (agrupación de carrito)
- `(user_id, sku)`, `(user_id, barcode)` — products (búsqueda rápida)
- `(user_id, created_at)` — ai_insights, stock_movements

### Patrón de Operaciones Atómicas
```sql
-- Ejemplo: rpc_create_operation_aggregate
BEGIN;
  -- 1. Verificar idempotencia
  INSERT INTO operation_idempotency (user_id, idempotency_key, operation_kind)
  VALUES (...) ON CONFLICT DO NOTHING
  RETURNING operation_id;
  
  -- Si ya existe → RETURN existing operation_id (idempotente)
  
  -- 2. Validar amounts (amount_guard)
  -- 3. INSERT en sales/purchases (N ítems)
  -- 4. UPDATE products.stock (tracked only)
  -- 5. INSERT en stock_movements (ledger)
COMMIT;
```

---

## Capa de Edge Functions (Supabase / Deno)

### Patrones comunes
- Todas usan `createClient(url, serviceRoleKey)` para operaciones administrativas
- CORS habilitado en todas (preflight OPTIONS manejado)
- JWT verificado via `supabase.auth.getUser(authHeader.replace('Bearer ', ''))`
- Timeout explícito: Promise.race([openAICall, sleep(25000)]) para LLM calls
- Retry con backoff exponencial en llamadas a OpenAI

### Registro de Resultados IA
```typescript
// Patrón estándar para guardar resultado de IA en DB
await supabase.rpc('rpc_atomic_log_ai_insight', {
  p_user_id: user.id,
  p_type: 'prediction',  // o ventas, stock, etc.
  p_priority: 'media',
  p_message: openAIResponse.text
})
```

---

## Seguridad

### Layers de Seguridad
```
1. Vercel Edge (CDN): HTTPS forzado, headers de seguridad via vercel.json
2. Next.js Middleware: validación de sesión en cada request autenticado
3. Supabase Auth: JWT validation, refresh automático via @supabase/ssr
4. RLS: autorización a nivel de fila en PostgreSQL (last line of defense)
5. SECURITY DEFINER RPCs: operaciones privilegiadas con search_path explícito
6. Storage: RLS en buckets (owner-only para invoices, public read para avatars)
```

### Variables de Entorno
```
# Públicas (NEXT_PUBLIC_*)
NEXT_PUBLIC_SUPABASE_URL          # URL del proyecto Supabase
NEXT_PUBLIC_SUPABASE_ANON_KEY     # Clave anónima (RLS restricta)

# Solo servidor (NO exponer al cliente)
SUPABASE_SERVICE_ROLE_KEY         # Service role (bypasa RLS — solo Edge Functions)
OPENAI_API_KEY                    # OpenAI para Edge Functions
RESEND_API_KEY                    # Resend para Edge Functions
```

---

## Infraestructura de Deploy

### Vercel (Frontend)
- Framework: Next.js con App Router
- Turbopack habilitado en dev (`--turbo`)
- Build: `next build`
- Deploy automático en push a `main` (GitHub Actions)
- Config en `vercel.json`

### Supabase (Backend)
- PostgreSQL con extensiones: uuid-ossp, pg_cron (programación de jobs)
- Migraciones gestionadas con Supabase CLI
- Edge Functions en Deno runtime
- Webhooks configurados manualmente en Dashboard Supabase

### CI/CD
- `.github/workflows/` — pipeline de GitHub Actions
- Migrations de DB aplicadas en CI (stub migrations para compatibilidad)
- Type checking: `tsc --noEmit`
- Lint: `next lint`

---

## Estructura de Directorios (Detalle)

```
/
├── app/
│   ├── (dashboard)/
│   │   ├── layout.tsx           # Layout con sidebar + auth guard
│   │   ├── dashboard/page.tsx   # Overview principal
│   │   ├── ventas/              # Módulo ventas
│   │   │   ├── page.tsx         # Listado de ventas
│   │   │   └── nueva/page.tsx   # Formulario de nueva venta (carrito)
│   │   ├── [otros módulos]/
│   │   └── admin/               # Rutas admin (guard de rol)
│   ├── auth/                    # Rutas de auth (sin sidebar)
│   ├── actions/                 # Server Actions (Next.js)
│   │   ├── auth.ts
│   │   ├── sales.ts
│   │   └── ...
│   └── api/                     # API Routes (si hay webhooks o callbacks)
│
├── components/
│   ├── ui/                      # shadcn/ui components base
│   ├── app-sidebar.tsx          # Sidebar de navegación principal
│   ├── ventas/                  # Componentes específicos de módulo
│   ├── products/
│   ├── ai/
│   ├── shared/                  # Componentes reutilizables entre módulos
│   └── ...
│
├── lib/
│   ├── supabase/
│   │   ├── client.ts            # Singleton para Client Components
│   │   ├── server.ts            # Singleton para Server Components
│   │   └── middleware.ts        # updateSession() para middleware.ts
│   ├── services/                # Funciones de acceso a datos por módulo
│   │   ├── salesService.ts
│   │   ├── productsService.ts
│   │   └── ...
│   ├── types.ts                 # Tipos TypeScript globales
│   ├── constants.ts             # Límites de plan, categorías, config
│   ├── utils.ts                 # Utilidades generales (cn, format, etc.)
│   └── [otros utilities]/
│
├── hooks/                       # Custom hooks
│   ├── useSales.ts              # React Query hooks por módulo
│   ├── useProducts.ts
│   └── ...
│
├── contexts/                    # React Contexts
│   └── AuthContext.tsx          # Contexto de autenticación
│
├── supabase/
│   ├── config.toml              # Config Supabase CLI
│   ├── migrations/              # ~60+ archivos .sql
│   └── functions/               # 10 Edge Functions en Deno
│       ├── ai-insights/index.ts
│       ├── ai-prediccion/index.ts
│       ├── ai-resumen/index.ts
│       ├── ai-simulador/index.ts
│       ├── fair-advisor/index.ts
│       ├── invoice-ocr/index.ts
│       ├── create-sale/index.ts
│       ├── create-purchase/index.ts
│       ├── delete-product/index.ts
│       └── send-email/index.ts
│
├── middleware.ts                # Auth middleware global
├── next.config.mjs              # Config Next.js
├── tailwind.config.ts           # Config Tailwind
└── components.json              # Config shadcn/ui
```

---

## Consideraciones de Escalabilidad (Futuras)

| Área | Deuda actual | Plan futuro |
|---|---|---|
| Billing | Freemium sin pasarela real | Integrar Stripe o MercadoPago |
| Analytics | OLTP + dashboard en Supabase | Separar OLAP si volumen crece |
| IA | gpt-4o-mini + heurísticas | Considerar fine-tuning o RAG con datos propios |
| Auth | Solo email/password | OAuth (Google) para reducir fricción |
| Monitoring | Básico (Vercel) | Agregar Sentry o similar para error tracking |
| Multi-idioma | Solo español | i18n si se expande a otros mercados |
| Mobile | Web responsive | PWA o app nativa si tracción lo justifica |
