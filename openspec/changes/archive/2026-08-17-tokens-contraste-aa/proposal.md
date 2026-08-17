## Why

La verificación visual de `clientes-frecuentes-historial` (task 10.1, 2026-08-17) encontró que el patrón canónico de badge del design system — `text-success` sobre `bg-success/15` — mide **2,02:1** en tema claro, y `text-warning` sobre `bg-warning/15` mide **1,43:1**. WCAG AA exige 4,5:1 para texto. No es un defecto de ese change: es el par de tokens establecido, reutilizado sin modificar en 19 componentes de producción.

La auditoría numérica completa de este propose (script sobre los valores reales de `frontend/app/globals.css`, fórmula WCAG 2.1 con composición alpha en espacio gamma) muestra que **el problema es mucho más grande que los dos badges reportados**: en tema claro fallan **13 de 13** pares canónicos de token, incluido el CTA principal del producto (`bg-primary` + `text-primary-foreground` = **2,09:1**), el botón destructivo (`bg-destructive` + `text-destructive-foreground` = **3,60:1**), el mensaje de error de formulario (`text-destructive` sobre card = **3,76:1**) y el anillo de foco (`--ring` = **2,30:1**, contra el mínimo de 3:1 de SC 1.4.11). En tema oscuro fallan además los dos pares de `destructive` en texto (**1,76:1** sobre tinte) — el tema oscuro **no** estaba sano, solo lo estaban `success` y `warning`.

Causa raíz: `:root` (claro) y `.dark` declaran **valores idénticos** para `--success`, `--warning` y sus foregrounds (`globals.css:41-44` vs `:110-113`). Una luminosidad elegida para funcionar como texto claro sobre fondo oscuro no puede funcionar como texto sobre un tinte claro. El sistema tiene un solo token por rol semántico, pero ese rol se usa para dos trabajos con requisitos de luminosidad opuestos: **pintar una superficie** y **pintar texto sobre una superficie**.

Este change ejecuta el primer bullet del scope de `v4-frontend-04` ("auditoría de contraste de los tokens contra WCAG AA — 4,5:1 texto, 3:1 UI") y su criterio de aceptación "contraste de todos los tokens semánticos ≥ AA", adelantado porque hay un defecto medido en superficies vivas. **No** reemplaza a `v4-frontend-04`, que conserva el resto de su alcance (axe-core en CI, `aria-label`, skip-link, command palette, focus-trap).

## What Changes

- **Separar el token de texto del token de superficie.** Se introducen `--success-text`, `--warning-text`, `--destructive-text` y `--primary-text` en ambos temas: oscuros en claro, luminosos en oscuro. Los tokens base (`--success`, `--warning`, `--primary`) **no** cambian: siguen pintando fondos, tintes, bordes, puntos de notificación y series de gráficos con el color de marca actual.
- **Sin migración de componentes.** Los nuevos tokens se cablean en `tailwind.config.ts` vía `theme.extend.textColor`, que en Tailwind v3 sobrescribe únicamente la paleta de utilities de texto. `text-success` / `text-warning` / `text-destructive` / `text-primary` pasan a resolver al token accesible **sin tocar una sola línea de los 19 componentes que usan success/warning, los 53 que usan `text-destructive` ni los 67 que usan primary**. `bg-*`, `border-*`, `ring-*` y `*-foreground` quedan intactos.
- **`--primary-foreground` en claro: `355.7 100% 97.3%` → `0 0% 3.9%`.** El tema oscuro y `--success-foreground` (mismo verde `142 71% 45%`) ya usaban casi-negro; el tema claro era el único inconsistente. 2,09:1 → 8,62:1 sin tocar el verde de marca.
- **`--destructive` en claro: `0 84.2% 60.2%` → `0 84% 42%`.** Es el único caso donde el foreground es casi-blanco, así que oscurecer la base arregla **los dos** pares a la vez (sólido 3,60 → 5,80). Cambia el rojo visible de botones destructivos y de la barra negativa de `/rentabilidad`. **Requiere sign-off del PO (OQ-1).**
- **`--ring` en claro: `142 71% 45%` → `142 71% 35%`.** Indicador de foco 2,30:1 → 3,70:1 (SC 1.4.11 pide 3:1).
- **Gate anti-regresión**: test vitest que parsea `frontend/app/globals.css`, calcula los ratios WCAG de los 28 pares canónicos (texto sobre tinte /5 /10 /15, texto sobre superficie plana, foreground sobre sólido, anillo sobre superficie) en ambos temas, y falla por debajo de 4,5:1 (texto) / 3:1 (UI). Es el RED del ciclo TDD y el que impide que el design system vuelva a degradarse en silencio.
- **Sin superficie frontend nueva.** Este change modifica superficies existentes ya visibles; no crea pantallas ni rutas. Las superficies afectadas se enumeran en Impact y se verifican en claro/oscuro y desktop/mobile antes del merge (regla PO 2026-08-02).

## Capabilities

### New Capabilities

Ninguna. El contrato de tokens ya vive en la capability `visual-design-system`; agregar una capability paralela duplicaría la fuente de verdad.

### Modified Capabilities

- `visual-design-system`: se **agrega** un requirement que fija el contraste WCAG AA de los tokens semánticos como invariante verificada por test (hoy el spec solo lo menciona como algo que "audita `v4-frontend-04`", sin criterio ejecutable), y otro que establece la separación token-de-texto / token-de-superficie como regla del sistema. Se **modifica** el requirement "Tema claro y oscuro coherente" para que exigir valor en ambos temas no alcance: el valor debe además cumplir el umbral de contraste del rol.

## Impact

**Archivos que se editan (5)**

| Archivo | Cambio |
|---|---|
| `frontend/app/globals.css` | 4 tokens nuevos × 2 temas; `--primary-foreground` y `--ring` en `:root`; `--destructive` en `:root` (OQ-1) |
| `frontend/tailwind.config.ts` | `theme.extend.textColor` con las 4 claves remapeadas |
| `frontend/__tests__/lib/token-contrast-aa.test.ts` | **nuevo** — gate de contraste |
| `frontend/docs/design-tokens.md` | tabla de color con el par texto/superficie y el contraste mínimo por rol |
| `CHANGES.md` | anotar en `v4-frontend-04` que su bullet de contraste queda cubierto acá |

**Superficies afectadas (ninguna se edita; todas cambian de color y se verifican)**

*Badge/pill sobre tinte — el caso que originó el hallazgo:*
`components/clientes/ClientActivityBadge.tsx` · `components/ventas/sale-operations-list.tsx` · `components/shared/cart-item-list.tsx` · `components/dashboard/KpiSummaryCard.tsx` · `components/dashboard/ai-alerts.tsx` · `components/dashboard/TrialBanner.tsx` · `app/(dashboard)/productos/page.tsx` · `app/(dashboard)/clientes/page.tsx` · `app/(dashboard)/facturacion/page.tsx` · `app/(dashboard)/admin/pagos/ambiguas/page.tsx`

*Texto/cifra coloreada sobre superficie plana:*
`components/dashboard/kpi-card.tsx` · `components/dashboard/KpiSummaryBlock.tsx` · `components/dashboard/recent-activity.tsx` · `components/dashboard/ai-summary-card.tsx` · `components/products/product-catalog.tsx` · `app/(dashboard)/dashboard/page.tsx`

*Íconos semánticos:*
`components/ventas/sale-receipt-button.tsx` · `components/products/product-import-dialog.tsx` · `components/dashboard/NotificationBell.tsx`

*Alcance ampliado por el remapeo de `text-destructive` (53 archivos) y `text-primary` (67 archivos)* — se verifican por cohorte representativa, no archivo por archivo: `components/ui/form.tsx` (FormMessage), `components/ui/button.tsx`, `components/ui/badge.tsx`, `components/ui/toast.tsx`, `components/data-table/data-table.tsx`, `components/ai/PriceSuggestionModal.tsx`, `components/bank-reconciliation/ReconciliationBoard.tsx`.

*Gráficos (afectados solo por OQ-1, consumen `hsl(var(--destructive))` / `hsl(var(--primary))` directo):*
`app/(dashboard)/rentabilidad/page.tsx` · `app/(dashboard)/reportes/sucursal/page.tsx` · `app/(dashboard)/reportes/comparativo/page.tsx` · `app/(dashboard)/reportes/centros-costo/page.tsx`

**Tests existentes en riesgo**: `__tests__/components/CartItemList.test.tsx` afirma `text-warning` como string de clase — el remapeo conserva el nombre de la utility, así que debe seguir verde (es el control negativo de que no hubo churn de componentes). `__tests__/lib/color-token-migration.test.ts` y `__tests__/components/ui-token-refresh.test.tsx` no deberían moverse.

**Fuera de alcance**: `lib/three/*.ts` (hex de materiales WebGL, no leen CSS vars), el lint de color de `v4-frontend-01`, y el resto de `v4-frontend-04` (axe-core, aria-label, skip-link, command palette). No se toca lógica de negocio, hooks, RPCs, auth ni RLS.
