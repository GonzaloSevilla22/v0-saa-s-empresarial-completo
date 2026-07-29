# Matriz de clasificación de superficies — v4-visual-3d-refresh

> Documento vivo. Clasifica cada ruta del App Router en una de tres clases (D8 de `openspec/changes/v4-visual-3d-refresh/design.md`):
>
> - **`3d`** — alto impacto: escena 3D (React Three Fiber) + refresh 2D + micro-animaciones. Solo Fase B/C (bloqueado a sign-off del PO sobre las Open Questions del design).
> - **`2d-motion`** — refresh de tokens + micro-animaciones 2D (Framer Motion). **Sin 3D.**
> - **`refresh-only`** — solo tokens (color/spacing/elevación/tipografía). Animación mínima o nula. **Sin 3D.**
>
> Regla (D8): ante duda, se degrada a la clase de menor costo de render. Ninguna pantalla operativa densa (POS, tablas, listados) sube a `3d`.
>
> Esta Fase A (tasks 1.1–1.11) **no implementa 3D en ningún caso** — la columna `3d` documenta la clasificación objetivo para cuando se ejecuten las Fases B/C (post sign-off PO), no trabajo ya realizado.

## Landing / marketing

| Ruta | Clase | Notas |
|---|---|---|
| `/` (`app/page.tsx`, `LandingPageFull`) | `3d` | Landing pública principal — hero de alto impacto (D8). Editable por admin (`LandingManager`); la escena 3D debe convivir con la estructura editable, no reemplazarla (Open Question 4 del design). |
| `/landing` (`app/landing/page.tsx`, `LandingRenderer`) | `3d` | Variante de renderer de landing (mismas secciones editables). Mismo tratamiento que `/`. |
| `/legal/privacidad`, `/legal/terminos` | `refresh-only` | Texto legal estático, sin motion. |

## Auth

| Ruta | Clase | Notas |
|---|---|---|
| `/auth/login` | `3d` | Escena 3D de acompañamiento lateral/fondo (D8). Formulario 100% usable sin 3D. |
| `/auth/register` | `3d` | Ídem login. |
| `/auth/forgot-password` | `2d-motion` | Flujo secundario de auth, no es el momento de mayor impacto — refresh + transición de estado (enviado/error). |
| `/auth/reset-password` | `2d-motion` | Ídem. |
| `/auth/verify-email` | `2d-motion` | Ídem. |

## Onboarding

| Ruta | Clase | Notas |
|---|---|---|
| _(no existe todavía en el App Router)_ | `3d` (reservado) | D8 clasifica onboarding como `3d` (ilustración por paso). Sin ruta implementada aún — clasificación reservada para cuando se construya el flujo, no hay trabajo pendiente en esta Fase A. |

## Dashboard y operación (`app/(dashboard)/*`)

| Ruta | Clase | Notas |
|---|---|---|
| `/dashboard` | `2d-motion` | Shell con KPIs, gráfico y actividad reciente — refresh + micro-animaciones de entrada/feedback. Empty states destacados (primera carga sin datos) son candidatos a `3d` ligero en Fase C (D8), no en Fase A. |
| `/ventas` | `2d-motion` | Listado + acciones — refresh + feedback, sin 3D. |
| `/ventas/pos` | `2d-motion` | **Superficie operativa densa — explícitamente sin 3D** (D8, Non-Goal). La celebración "venta cerrada" (D8: `3d` efímero) es un overlay aparte, on-demand, fuera de la superficie POS misma — se implementa en Fase C, no en A. |
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

- **POS / venta rápida** (`/ventas/pos`): `2d-motion`. **Confirmado sin 3D.**
- **Tablas de datos / listados** (`/ventas/ordenes`, `/stock`, `/clientes`, `/sucursales/[id]/stock`, `/facturacion`, `/seguros`, todo `/admin/**`): `refresh-only`. **Confirmado sin 3D.**

## Estado de esta Fase A

Ninguna superficie de esta tabla recibe 3D en la Fase A (tasks 1.1–1.11): la columna `3d` es la clasificación objetivo para las Fases B/C, que quedan bloqueadas a sign-off explícito del PO sobre las 5 Open Questions de `design.md`. Esta Fase A aplica `refresh-only`/`2d-motion` (tokens + micro-animaciones Framer Motion) sobre las superficies listadas.
