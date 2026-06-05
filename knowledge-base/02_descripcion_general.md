# 02 — Descripción General

## Stack Tecnológico

### Frontend
| Tecnología | Versión | Rol |
|---|---|---|
| Next.js | 16.1.6 | Framework principal (App Router) |
| React | 19.2.3 | UI library |
| TypeScript | 5.7.3 | Tipado estático |
| Tailwind CSS | 3.4.x | Estilos utilitarios |
| Radix UI | varias | Componentes accesibles sin estilos |
| shadcn/ui | — | Design system sobre Radix + Tailwind |
| Zustand | 5.x | Estado global cliente |
| TanStack React Query | 5.x | Cache y fetching de datos del servidor |
| React Hook Form + Zod | — | Formularios con validación de schemas |
| Recharts + D3.js | — | Gráficos de negocio y analytics |
| date-fns | 4.1.0 | Utilidades de fechas |
| Sonner | 1.x | Toast notifications |
| cmdk | 1.1.1 | Command palette / selector de búsqueda |
| Embla Carousel | 8.x | Carruseles de contenido |
| Vaul | 1.x | Drawers mobile |
| next-themes | 0.4.x | Modo oscuro/claro |

### Backend / BaaS (Supabase)
| Tecnología | Rol |
|---|---|
| Supabase Auth | Autenticación (JWT, OAuth, email) |
| PostgreSQL (Supabase) | Base de datos principal (OLTP) |
| Row Level Security (RLS) | Autorización a nivel de fila |
| Edge Functions (Deno) | Lógica de negocio, IA, email, OCR |
| Storage (S3-compatible) | Archivos: avatars, facturas |
| Realtime (Supabase) | No usado en MVP actual |
| Webhooks (Supabase) | Trigger email en INSERT de email_logs |
| RPCs (PostgreSQL Functions) | Operaciones atómicas de negocio |

### IA
| Tecnología | Rol |
|---|---|
| OpenAI API (`gpt-4o-mini`) | Generación de insights, predicciones, simulaciones, OCR |
| Supabase Edge Functions | Wrapper de llamadas a OpenAI (sin exposición de API key al cliente) |

### Email
| Tecnología | Rol |
|---|---|
| Resend | Proveedor de email transaccional |
| Supabase DB Webhook | Trigger: INSERT en `email_logs` → dispara `send-email` Edge Function |
| `email_logs` table | Cola de emails con deduplicación y tracking de estado |

### Infraestructura / DevOps
| Tecnología | Rol |
|---|---|
| Vercel | Deploy del frontend Next.js |
| GitHub Actions | CI/CD (branch protection, migrations CI) |
| pnpm | Package manager (v10.33.4) |
| Supabase CLI | Migraciones locales y gestión de schema |

## Arquitectura General

```
Usuario / Browser
      │
      ▼
 Vercel CDN
      │
  Next.js App Router (SSR / RSC / Client)
      │
      ├── Server Components → Supabase DB (directamente via supabase-js server)
      ├── Client Components → Supabase DB (via @supabase/ssr, anon key + RLS)
      │
      └── API Routes / Server Actions
            │
            └── Supabase Edge Functions (OpenAI, Resend, OCR)
                      │
                      ├── OpenAI API (gpt-4o-mini)
                      └── Resend API
```

## Módulos de la Aplicación

| Módulo | Ruta | Descripción |
|---|---|---|
| Dashboard | `/dashboard` | Resumen general, KPIs del período, acceso rápido |
| Ventas | `/ventas` | Registro y listado de ventas, carrito multi-producto |
| Compras | `/compras` | Registro y listado de compras a proveedores |
| Gastos | `/gastos` | Registro de gastos por categoría (fijos/variables) |
| Productos | `/productos` | Catálogo, variantes, atributos, unidades de medida |
| Clientes | `/clientes` | Directorio de clientes con historial de compras |
| Stock | `/stock` | Inventario, ajustes, historial de movimientos |
| Insights IA | `/insights` | Análisis automático de los últimos 30 días |
| Copiloto IA | `/copiloto-ia` | Chat con asistente financiero (RAG sobre datos propios) |
| Simulador | `/simulador` | What-if: "¿qué pasa si subo el precio un 20%?" |
| Ferias / IA | `/ferias/ia` | Recomendaciones de productos para eventos presenciales |
| Cursos | `/cursos` | Plataforma de aprendizaje para emprendedores |
| Comunidad | `/comunidad` | Foro de posts y respuestas entre emprendedores |
| Configuración | `/configuracion` | Perfil, moneda, idioma, zona horaria, seguridad |
| Admin Métricas | `/admin/metricas` | Dashboard AARRR para el operador de la plataforma |
| Admin Contenido | `/admin/cursos`, `/admin/seguros`, `/admin/landing` | Gestión de contenido de la plataforma |

## Integraciones Externas

### Resend (Email)
- **Propósito**: emails transaccionales (bienvenida, alertas de stock, avisos de reuniones y pools)
- **Implementación**: API key en variable de entorno servidor; envío via Edge Function `send-email`
- **Deduplicación**: constraint UNIQUE en `email_logs(user_id, event_type, metadata)` + debounce 24h para alertas de stock

### OpenAI (IA)
- **Modelo**: `gpt-4o-mini` en todas las Edge Functions de IA
- **Timeout**: 25 segundos (con fallback gracioso si se supera)
- **Funciones**: ai-insights, ai-prediccion, ai-resumen, ai-simulador, fair-advisor, invoice-ocr

### Supabase (BaaS completo)
- **Auth**: JWT con refreshed sessions via `@supabase/ssr`
- **DB**: PostgreSQL con RLS en todas las tablas de usuario
- **Storage**: 2 buckets (avatars público, invoices privado)
- **Edge Functions**: Deno runtime, 60s timeout máximo

## Variables de Entorno Requeridas

| Variable | Descripción | Lado |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | URL del proyecto Supabase | Cliente + Servidor |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Anon key de Supabase | Cliente + Servidor |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role (bypasa RLS) | Solo servidor |
| `OPENAI_API_KEY` | API key de OpenAI para Edge Functions | Edge Functions |
| `RESEND_API_KEY` | API key de Resend | Edge Functions |

## Estructura de Directorios (Clave)

```
/
├── app/
│   ├── (dashboard)/         # Rutas autenticadas del emprendedor y admin
│   │   ├── dashboard/
│   │   ├── ventas/
│   │   ├── compras/
│   │   ├── productos/
│   │   ├── clientes/
│   │   ├── gastos/
│   │   ├── stock/
│   │   ├── insights/
│   │   ├── copiloto-ia/
│   │   ├── simulador/
│   │   ├── ferias/
│   │   ├── cursos/
│   │   ├── comunidad/
│   │   ├── configuracion/
│   │   └── admin/           # Rutas exclusivas para rol admin
│   ├── auth/                # Login, registro, recuperación
│   ├── landing/             # Landing pública
│   ├── actions/             # Server Actions de Next.js
│   └── api/                 # API Routes
├── components/
│   ├── ui/                  # Componentes base (shadcn/ui)
│   ├── ventas/              # Componentes de módulo
│   ├── products/
│   ├── ai/
│   └── ...
├── lib/
│   ├── supabase/            # Clientes de Supabase (server, client, middleware)
│   ├── services/            # Servicios de datos por módulo
│   ├── types.ts             # Tipos globales TypeScript
│   ├── constants.ts         # Planes, límites, categorías, config
│   └── ...
├── hooks/                   # Custom hooks (React Query + Zustand)
├── supabase/
│   ├── migrations/          # ~60+ migraciones ordenadas cronológicamente
│   └── functions/           # 10 Edge Functions
└── contexts/                # Contextos React (auth, theme, etc.)
```
