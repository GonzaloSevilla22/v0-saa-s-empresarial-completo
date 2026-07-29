# Contrato de tokens — v4-visual-3d-refresh (Fase A)

> Documento vivo. Extiende (no reemplaza) el registro de tokens base de color que formaliza `v4-frontend-01` (aún no ejecutado al momento de escribir esto). Fuente única: `frontend/app/globals.css` (`:root` = tema claro, `.dark` = tema oscuro), expuesta como utilities de Tailwind en `frontend/tailwind.config.ts` → `theme.extend`.
>
> Regla dura del sistema (spec `visual-design-system`, Requirement "Lenguaje visual con tokens semánticos extendidos"): ninguna utility de token semántico se consume como *arbitrary value* (`shadow-[var(--elevation-1)]`); siempre se compila desde `theme.extend` (`shadow-elevation-1`).

## Color (base — registro formal es de `v4-frontend-01`)

| Token CSS | Utility Tailwind | Claro | Oscuro | Uso |
|---|---|---|---|---|
| `--primary` | `bg-primary` / `text-primary` | `142 71% 45%` | `142 71% 45%` | Marca, CTAs primarios |
| `--destructive` | `bg-destructive` / `text-destructive` | `0 84.2% 60.2%` | `0 62.8% 30.6%` | Errores, acciones destructivas |
| `--success` | `bg-success` / `text-success` | `142 71% 45%` | `142 71% 45%` | Estados positivos (venta, cobro, alta) |
| `--warning` | `bg-warning` / `text-warning` | `48 96% 53%` | `48 96% 53%` | Alertas no bloqueantes (stock bajo, vencimientos) |
| `--muted` / `--foreground` | `bg-muted` / `text-foreground` | — | — | Texto/superficie secundaria |

**Nota de coordinación**: `success`/`warning` ya existían como CSS var en `app/globals.css` antes de este change, pero no estaban expuestos en `tailwind.config.ts`. La task 1.9 de este change (migrar clases hardcodeadas `emerald-*`/`amber-*` en las superficies de mayor tráfico) los necesita como utility real, no arbitrary value — se expusieron en `theme.extend.colors` sin definir NINGÚN valor HSL nuevo (misma CSS var, cero segunda fuente de verdad). `v4-frontend-01` sigue siendo el dueño formal del registro de tokens base de color (incluye además borrar `frontend/styles/globals.css`, el `globals.css` muerto — **no tocado por este change**, fuera de su alcance) y del lint anti-regresión de color.

## Motion (tokens de segundo nivel — este change)

| Token CSS | Utility Tailwind | Valor | Uso |
|---|---|---|---|
| `--motion-duration-fast` | `duration-fast` | `120ms` | Micro-feedback: hover, press, toggle |
| `--motion-duration-base` | `duration-base` | `200ms` | Transiciones estándar: entrada de card, fade |
| `--motion-duration-slow` | `duration-slow` | `320ms` | Transiciones enfatizadas: modales, listas con stagger |
| `--motion-ease-standard` | `ease-standard` | `cubic-bezier(0.4, 0, 0.2, 1)` | Curva por defecto (Material standard) |
| `--motion-ease-emphasized` | `ease-emphasized` | `cubic-bezier(0.2, 0, 0, 1)` | Entradas que quieren sensación de "llegada" |

Mismos valores en `:root` y `.dark` — el motion no varía por tema, se declaran en ambos bloques por explicitud y para permitir overrides futuros sin tocar `:root`.

**Contrato compartido 2D/3D (design.md D4)**: Framer Motion no puede leer CSS custom properties en su prop `transition` (necesita números/arrays evaluados en JS). Por eso los mismos valores se replican como constantes TypeScript en `frontend/lib/motion-tokens.ts` (`MOTION_DURATION.fast/base/slow` en segundos, `MOTION_EASE.standard/emphasized` como arrays de cubic-bezier). Ese archivo es la fuente que consumen `components/motion/*`. Si se cambia un valor acá, hay que actualizar `lib/motion-tokens.ts` en el mismo commit — documentado también como comentario en ambos archivos.

## Elevación / sombra

| Token CSS | Utility Tailwind | Uso |
|---|---|---|
| `--elevation-1` | `shadow-elevation-1` | Cards en reposo, inputs |
| `--elevation-2` | `shadow-elevation-2` | Cards en hover, dropdowns |
| `--elevation-3` | `shadow-elevation-3` | Popovers, tooltips flotantes |
| `--elevation-4` | `shadow-elevation-4` | Diálogos/modales |

Valores distintos en `:root`/`.dark` (mayor opacidad en oscuro para mantener contraste perceptible sobre `--background`/`--card` oscuros).

## Escala tipográfica del refresh

| Token CSS | Utility Tailwind | Tamaño | Uso |
|---|---|---|---|
| `--font-size-display` | `text-display` | `clamp(2rem, 1.5rem + 2vw, 3rem)` | Hero/landing, momentos de marca |
| `--font-size-heading-1` | `text-heading-1` | `1.875rem` | Título de página destacado |
| `--font-size-heading-2` | `text-heading-2` | `1.5rem` | Sección |
| `--font-size-heading-3` | `text-heading-3` | `1.25rem` | Subsección |
| `--font-size-body-lg` | `text-body-lg` | `1.125rem` | Cuerpo destacado |
| `--font-size-caption` | `text-caption` | `0.75rem` | Metadatos, ayudas |

Complementa (no reemplaza) la escala default de Tailwind (`text-xs`…`text-5xl`), en uso consistente en el resto de la app (dashboard, tablas, formularios) — no se migra lo existente, solo se agrega vocabulario para superficies de marca (landing/onboarding/celebraciones, Fases B-D).

## Spacing / ritmo

No se introduce una escala de spacing paralela: la app ya usa consistentemente la escala default de Tailwind (grid de 4px — `gap-4`, `p-6`, `space-y-1.5`, etc.) en los componentes base (`components/ui/*`) y en las superficies auditadas. El "ritmo de spacing" del refresh se resuelve aplicando esa escala existente de forma disciplinada en el refresh de componentes (task 1.8), no redefiniendo tokens nuevos.

## Tema claro/oscuro

Todo token semántico introducido en esta fase tiene valor en `:root` y en `.dark` (color, elevación) o es tema-agnóstico y se declara igual en ambos por explicitud (motion). El contraste WCAG AA de los tokens de color lo audita `v4-frontend-04` — este change no introduce ningún valor de color nuevo (solo expone `success`/`warning` ya existentes), por lo que no debería alterar los resultados de esa auditoría.

## Colores 3D (Fases B–D — fuente paralela, no CSS)

Los materiales de las escenas 3D (`lib/three/heroSceneTheme.ts`, `lib/three/celebrationTheme.ts`) usan valores hex hardcodeados en TypeScript, no CSS custom properties — Three.js/`meshStandardMaterial` recibe colores como valores JS (`string`/`number`), no puede leer `var(--token)`. Mismo trade-off ya documentado para `lib/motion-tokens.ts` (Framer Motion tiene la misma limitación). Estos NO son clases de Tailwind y quedan **fuera** del alcance del lint anti-regresión de color de `v4-frontend-01` (ese lint apunta a `className`, no a props de materiales WebGL ni a `fill`/`stroke` de SVG) — documentados y testeados en su propio archivo (`heroSceneTheme.test.ts`, `celebrationTheme.test.ts`) en su lugar. Si se retoca la paleta de marca (`--primary` etc.), estos archivos deben revisarse manualmente — no se actualizan solos.

## Barrido de color — estado al cierre de Fase D (task 4.1)

Este change **no reimplementa** el lint de color transversal (`v4-frontend-01`, aún no ejecutado como change propio en este repo al momento de escribir esto). Alcance de esta Fase D: verificado que ninguna de las superficies/archivos que este change tocó (landing, `auth/login`, `auth/register`, POS, dashboard, `components/three/*`) introduce clases Tailwind de color hardcodeadas nuevas (`grep` dirigido, 0 matches) — la migración transversal de las ~883 clases originales de la auditoría UX/UI sigue siendo alcance de `v4-frontend-01`, no de este change.
