# Contrato de tokens — v4-visual-3d-refresh (Fase A)

> Documento vivo. Extiende (no reemplaza) el registro de tokens base de color que formaliza `v4-frontend-01` (aún no ejecutado al momento de escribir esto). Fuente única: `frontend/app/globals.css` (`:root` = tema claro, `.dark` = tema oscuro), expuesta como utilities de Tailwind en `frontend/tailwind.config.ts` → `theme.extend`.
>
> Regla dura del sistema (spec `visual-design-system`, Requirement "Lenguaje visual con tokens semánticos extendidos"): ninguna utility de token semántico se consume como *arbitrary value* (`shadow-[var(--elevation-1)]`); siempre se compila desde `theme.extend` (`shadow-elevation-1`).

## Color (base — registro formal es de `v4-frontend-01`)

> **`tokens-contraste-aa` (2026-08-17): token de superficie ≠ token de texto.** Cada rol semántico (`primary`/`success`/`warning`/`destructive`) tiene HOY dos tokens de color independientes, no uno: uno pinta la SUPERFICIE (fondos, tintes `/5` `/10` `/15`, bordes, el punto de `NotificationBell`, las series de gráficos) y otro pinta el TEXTO/ícono que va encima. Comparten nombre de utility (`text-success` sigue siendo `text-success`) pero **ya no comparten valor HSL** — es intencional: un mismo verde no puede ser vívido-como-fondo y oscuro-como-texto a la vez. El cableado vive en `tailwind.config.ts` → `theme.extend.textColor` (remapea SOLO las utilities `text-*`; `bg-*`/`border-*`/`ring-*`/`fill-*` siguen leyendo `theme.extend.colors`, sin tocar). Motivo completo: `openspec/changes/tokens-contraste-aa/design.md` §Context/§D1-D3.

| Rol | Token superficie (`bg-*`/`border-*`/`ring-*`) | Token texto (`text-*`) | Contraste mín. | Uso |
|---|---|---|---|---|
| `primary` | `--primary` — claro `142 71% 45%` · oscuro `142 71% 45%` | `--primary-text` — claro `142 71% 26%` · oscuro `142 71% 45%` | 4,5:1 | Marca, CTAs, series de gráfico |
| `success` | `--success` — claro `142 71% 45%` · oscuro `142 71% 45%` | `--success-text` — claro `142 71% 26%` · oscuro `142 71% 45%` | 4,5:1 | Estados positivos (venta, cobro, alta) |
| `warning` | `--warning` — claro `48 96% 53%` · oscuro `48 96% 53%` | `--warning-text` — claro `40 95% 28%` · oscuro `48 96% 53%` | 4,5:1 | Alertas no bloqueantes (stock bajo, vencimientos) |
| `destructive` | `--destructive` — claro `0 84% 42%` · oscuro `0 62.8% 30.6%` | `--destructive-text` — claro `0 84% 42%` · oscuro `0 91% 71%` | 4,5:1 | Errores, acciones destructivas |
| `--ring` (indicador de foco, no es un rol con texto) | claro `142 71% 35%` · oscuro `142 71% 45%` | — | 3:1 (SC 1.4.11) | Anillo de foco (`focus-visible:ring-ring`) — **acoplado a `--primary`** (OQ-4, decisión PO 2026-08-17: se deja así — ningún fallo hoy. Si `v4-frontend-01` retoca el verde de marca, revisar `--ring` en el mismo commit, no asumir que sigue pasando 3:1) |
| `--<rol>-foreground` (texto/ícono SOBRE el sólido del rol — `bg-<rol>` a opacidad 100%, ej. botón primario) | usa la superficie de arriba como fondo | `--primary-foreground` (claro `0 0% 3.9%`, cambiado — OQ-2) / `--success-foreground` / `--warning-foreground` / `--destructive-foreground` | 4,5:1 | `ui/button.tsx`, `ui/badge.tsx`, `ui/toast.tsx` (variantes sólidas) |
| `--muted` / `--foreground` | `bg-muted` / `text-foreground` | — | — | Texto/superficie secundaria |

**Grupo 4 resuelto (sign-off PO 2026-08-17, OQ-1 y OQ-2 APPROVED)**: `--destructive` en `:root` pasó de `0 84.2% 60.2%` a `0 84% 42%` y `--primary-foreground` en `:root` de `355.7 100% 97.3%` a `0 0% 3.9%`. Los 28 pares canónicos de `frontend/__tests__/lib/token-contrast-aa.test.ts` alcanzan ahora el umbral real (4,5:1 texto / 3:1 UI) — ya no queda ningún piso documentado. `text-destructive-foreground`/`bg-destructive` sólido claro: 3,60:1 → 5,80:1. `text-primary-foreground`/`bg-primary` sólido claro: 2,09:1 → 8,62:1.

**Nota de coordinación**: `success`/`warning` ya existían como CSS var en `app/globals.css` antes de `v4-visual-3d-refresh`, pero no estaban expuestos en `tailwind.config.ts` — se expusieron en `theme.extend.colors` sin definir ningún valor HSL nuevo. `v4-frontend-01` sigue siendo el dueño formal del registro de tokens base de color (incluye además borrar `frontend/styles/globals.css`, el `globals.css` muerto — no tocado por ningún change de esta serie) y del lint anti-regresión de color. `v4-frontend-04` sigue siendo dueño del resto de su alcance de accesibilidad (axe-core en CI, `aria-label`, skip-link, command palette, focus-trap) — `tokens-contraste-aa` solo adelantó su bullet de auditoría de contraste (ver `CHANGES.md`).

### Regla operativa: un rol nuevo nace con los dos tokens

Si se agrega un rol semántico de color nuevo (hoy: `primary`/`success`/`warning`/`destructive`; ej. un futuro `info`), **nace con su token de superficie Y su token de texto declarados en `:root` y en `.dark` desde el primer commit** — no se agrega "superficie primero, texto después". El gate de contraste (`token-contrast-aa.test.ts`) tiene que cubrir sus pares canónicos (texto sobre tinte del peor caso, texto sobre `--card`, `-foreground` sobre el sólido) agregando una fila a la tabla `ROLES` del test — ver `visual-design-system` §"Un rol nuevo nace con los dos tokens".

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

Todo token semántico introducido en esta fase tiene valor en `:root` y en `.dark` (color, elevación) o es tema-agnóstico y se declara igual en ambos por explicitud (motion). El contraste WCAG AA de los tokens de color lo verifica `frontend/__tests__/lib/token-contrast-aa.test.ts` (introducido por `tokens-contraste-aa`, 2026-08-17) — ya no alcanza con que un token tenga valor en los dos temas, ese valor tiene que además cumplir el umbral de contraste del rol en ese tema (ver la sección Color de arriba).

## Colores 3D (Fases B–D — fuente paralela, no CSS)

Los materiales de las escenas 3D (`lib/three/heroSceneTheme.ts`, `lib/three/celebrationTheme.ts`) usan valores hex hardcodeados en TypeScript, no CSS custom properties — Three.js/`meshStandardMaterial` recibe colores como valores JS (`string`/`number`), no puede leer `var(--token)`. Mismo trade-off ya documentado para `lib/motion-tokens.ts` (Framer Motion tiene la misma limitación). Estos NO son clases de Tailwind y quedan **fuera** del alcance del lint anti-regresión de color de `v4-frontend-01` (ese lint apunta a `className`, no a props de materiales WebGL ni a `fill`/`stroke` de SVG) — documentados y testeados en su propio archivo (`heroSceneTheme.test.ts`, `celebrationTheme.test.ts`) en su lugar. Si se retoca la paleta de marca (`--primary` etc.), estos archivos deben revisarse manualmente — no se actualizan solos.

## Barrido de color — estado al cierre de Fase D (task 4.1)

Este change **no reimplementa** el lint de color transversal (`v4-frontend-01`, aún no ejecutado como change propio en este repo al momento de escribir esto). Alcance de esta Fase D: verificado que ninguna de las superficies/archivos que este change tocó (landing, `auth/login`, `auth/register`, POS, dashboard, `components/three/*`) introduce clases Tailwind de color hardcodeadas nuevas (`grep` dirigido, 0 matches) — la migración transversal de las ~883 clases originales de la auditoría UX/UI sigue siendo alcance de `v4-frontend-01`, no de este change.
