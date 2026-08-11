# Matriz de clasificación de superficies — v4-visual-3d-refresh

> Documento vivo. Clasifica cada ruta del App Router en una de tres clases (D8 de `openspec/changes/v4-visual-3d-refresh/design.md`):
>
> - **`3d`** — alto impacto: escena 3D (React Three Fiber) + refresh 2D + micro-animaciones.
> - **`2d-motion`** — refresh de tokens + micro-animaciones 2D (Framer Motion). **Sin 3D.**
> - **`refresh-only`** — solo tokens (color/spacing/elevación/tipografía). Animación mínima o nula. **Sin 3D.**
>
> Regla (D8): ante duda, se degrada a la clase de menor costo de render. Ninguna pantalla operativa densa (POS, tablas, listados) sube a `3d`.
>
> **Estado al cierre de Fase D (2026-07-29)**: las 6 superficies `3d` de esta tabla están **implementadas** (Fases B/C): landing (`HeroScene`), login/registro (`AuthScene`), celebraciones "venta cerrada"/"meta alcanzada" (`Celebration3D`). Verificado empíricamente que ninguna superficie `2d-motion`/`refresh-only` carga el bundle 3D (grep de contenido sobre los chunks de build de 6 rutas operativas, 0 matches — ver `3d-budget.md`). Dos excepciones a la clasificación original de Fase A, documentadas con su razón en `openspec/changes/v4-visual-3d-refresh/tasks.md` (3.3/3.4): onboarding no tiene ruta real (no se fabricó una), empty states del dashboard degradados a `2d-motion` (D8 lo permite explícitamente).

## Landing / marketing

| Ruta | Clase | Notas |
|---|---|---|
| `/` (`app/page.tsx`, `LandingPageFull`) | `3d` ✅ | Landing pública principal — `HeroSceneMount` montado en `Hero()` (`LandingPageFull.tsx`), bloque `hidden lg:block` sobre la estructura editable existente. `LandingManager` (editor admin) no renderiza `LandingPageFull`/`HeroSection` — es un CRUD de lista sin preview embebido, cero riesgo de romperse. **Elemento flotante ocupado**: `WhatsAppFab` (change `landing-whatsapp-fab`) vive en la esquina **inferior derecha** con `z-40`, montado en `app/page.tsx` — no en `LandingPageFull` — para no entrar al bundle de cliente y para que su alcance sea exclusivo de esta ruta. Un futuro flotante (cookies, chat) debe ubicarse sabiendo que esta esquina está tomada. |
| `/landing` (`app/landing/page.tsx`, `LandingRenderer`) | `3d` ✅ | Variante de renderer — mismo `HeroSceneMount` montado en `HeroSection.tsx`. |
| `/legal/privacidad`, `/legal/terminos` | `refresh-only` | Texto legal estático, sin motion. |

## Auth

| Ruta | Clase | Notas |
|---|---|---|
| `/auth/login` | `3d` ✅ | `AuthSceneMount` (anillos toroidales) como capa de fondo (`z-0`, `pointer-events-none`) detrás del card (`z-10`). Formulario 100% usable sin 3D — verificado en browser real. |
| `/auth/register` | `3d` ✅ | Ídem login. |
| `/auth/forgot-password` | `2d-motion` | Flujo secundario de auth, no es el momento de mayor impacto — refresh + transición de estado (enviado/error). |
| `/auth/reset-password` | `2d-motion` | Ídem. |
| `/auth/verify-email` | `2d-motion` | Ídem. |

## Onboarding

| Ruta | Clase | Notas |
|---|---|---|
| _(no existe en el App Router)_ | `3d` (reservado, sin implementar) | D8 clasifica onboarding como `3d`. **Decisión Fase C (task 3.3)**: no se fabricó una ruta/feature de onboarding nueva solo para colgar una escena 3D — fuera del alcance 100% presentacional de este change (no inventa features de producto). La infraestructura reutilizable (`GatedSceneMount`, `Lazy3DCanvas`, patrón Hero/Auth) queda lista para cuando exista el flujo real. |

## Dashboard y operación (`app/(dashboard)/*`)

| Ruta | Clase | Notas |
|---|---|---|
| `/dashboard` | `2d-motion` | Shell con KPIs, gráfico y actividad reciente — refresh + micro-animaciones de entrada/feedback. Empty states destacados: **degradados a `2d-motion` deliberadamente** (Fase C task 3.4 — D8 lo permite explícitamente al exceder presupuesto; no existe un componente de empty-state dedicado en el dashboard real). Lleva la celebración "meta alcanzada" (`Celebration3D` variant="goal", overlay efímero, no cambia esta clasificación del shell). |
| `/ventas` | `2d-motion` | Listado + acciones — refresh + feedback, sin 3D. |
| `/ventas/pos` | `2d-motion` | **Superficie operativa densa — confirmado sin 3D en su UI core** (D8, Non-Goal; verificado por grep de bundle, ver `3d-budget.md`). La celebración "venta cerrada" (`Celebration3D` variant="sale") es un overlay `pointer-events-none fixed inset-0` efímero y separado, disparado por el estado `lastSale` ya existente — no forma parte del POS core ni bloquea el cobro. |
| `/ventas/ordenes`, `/ventas/ordenes/[id]` | `refresh-only` | Tabla/detalle de órdenes. |
| `/compras` | `2d-motion` | Listado + formulario denso — refresh + feedback inline. |
| `/gastos` | `2d-motion` | Formulario denso (RHF/Zod es `v4-frontend-05`, fuera de alcance) — refresh + feedback. |
| `/clientes`, `/clientes/[id]/cuenta` | `refresh-only` | Listado y cuenta corriente — tabla de datos. |
| `/proveedores/[id]/cuenta` | `refresh-only` | Cuenta corriente proveedor — tabla de datos. |
| `/productos` | `2d-motion` | Catálogo con import CSV — refresh + feedback de import (éxito/error), sin 3D. |
| `/stock` | `refresh-only` | Tabla de datos / listado. |
| `/sucursales` | `refresh-only` | Listado de sucursales. |
| `/sucursales/[id]/caja` | `2d-motion` | Arqueo de caja — feedback de apertura/cierre. |
| `/sucursales/[id]/stock` | `refresh-only` | Tabla de stock por sucursal. |
| `/facturacion` | `refresh-only` | Listado de comprobantes fiscales. |
| `/finanzas/conciliacion` | `2d-motion` | Conciliación bancaria — feedback de match/estado. |
| `/rentabilidad` | `refresh-only` | Reportes/gráficos — charts siguen `v4-frontend-07`. |
| `/reportes/comparativo`, `/reportes/sucursal` | `refresh-only` | Reportes/gráficos. |
| `/insights` | `2d-motion` | Tarjetas de insights IA — refresh + entrada animada. |
| `/copiloto-ia` | `2d-motion` | Interfaz conversacional — feedback de carga/respuesta. |
| `/comunidad` | `2d-motion` | Feed — refresh + entrada de lista con stagger. |
| `/cursos`, `/cursos/[id]` | `2d-motion` | Catálogo/detalle de cursos — refresh + entrada. |
| `/configuracion`, `/configuracion/fiscal` | `refresh-only` | Formularios de configuración. |
| `/exportaciones` | `refresh-only` | Panel de exportaciones. |
| `/planes`, `/planes/success`, `/planes/failure` | `2d-motion` | Upgrade de plan — refresh + feedback de éxito/error (candidato futuro a micro-celebración 2D, no 3D en esta fase). |
| `/seguros` | `refresh-only` | Listado. |
| `/simulador` | `2d-motion` | Simulador interactivo — feedback de cálculo. |
| `/organizacion/invitar`, `/organizacion/roles` | `refresh-only` | Formularios/tabla de gestión de organización. |
| `/admin/**` (analytics, landing editor, métricas, pagos, seguros, cursos, copilot-ia, feria-ia) | `refresh-only` | Herramientas internas de administración — no son superficie de cara al cliente, sin motion pesado. |

## Confirmación de non-goals (D8 / proposal.md)

- **POS / venta rápida** (`/ventas/pos`): `2d-motion`. **Confirmado sin 3D** — verificado empíricamente en Fase D (grep de contenido `react-three|THREE\.|three/build` sobre los 17 chunks del client-reference-manifest de build de producción, 0 matches; ver `3d-budget.md`).
- **Tablas de datos / listados** (`/ventas/ordenes`, `/stock`, `/clientes`, `/sucursales/[id]/stock`, `/facturacion`, `/seguros`, todo `/admin/**`): `refresh-only`. **Confirmado sin 3D** (mismo método, verificado sobre `/stock`, `/clientes`, `/ventas/ordenes`, `/facturacion`).

## Estado — cierre Fase D (2026-07-29)

Fases A (refresh 2D), B (infra 3D + piloto hero) y C (login/registro + celebraciones) completas y mergeadas a `main`. Las 6 superficies `3d` de esta tabla (landing ×2 rutas, auth ×2 rutas, celebraciones ×2 variantes) están implementadas con sus guardrails (gate de capacidad, `Lazy3DCanvas`, `SceneErrorBoundary`, `AdaptiveDpr`/`AdaptiveEvents`). Onboarding (3.3) y empty states (3.4) resueltos como excepciones documentadas — ver sección "Onboarding" arriba y la fila `/dashboard`. Non-goals (POS core, tablas) confirmados sin 3D por verificación empírica de bundle, no solo por diseño.
