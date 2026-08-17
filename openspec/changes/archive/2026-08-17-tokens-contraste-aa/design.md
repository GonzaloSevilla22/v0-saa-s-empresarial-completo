## Context

**Governance: MEDIUM.** Es lógica de presentación transversal — se implementa por pasos, exponiendo las decisiones no obvias. Una de ellas (OQ-1) toca el rojo de marca y sube a decisión del PO.

Los tokens semánticos de color viven en `frontend/app/globals.css` (`:root` = claro, `.dark` = oscuro) y se exponen como utilities en `frontend/tailwind.config.ts` → `theme.extend.colors`. Cada rol tiene hoy **un solo** token de color más su `-foreground`:

```
:root   --success: 142 71% 45%   --success-foreground: 0 0% 3.9%
.dark   --success: 142 71% 45%   --success-foreground: 0 0% 3.9%   ← idénticos
```

Ese token único cumple dos trabajos con requisitos de luminosidad **opuestos**:

1. **Pintar superficie** — `bg-success`, `bg-success/15`, `border-success/25`, el punto de `NotificationBell`, las series de Recharts. Acá el color debe ser vívido y su `-foreground` (casi-negro) se lee encima.
2. **Pintar texto** — `text-success` sobre `bg-success/15` o sobre la card. Acá, en tema claro, el color debe ser **oscuro** para leerse sobre un fondo casi blanco.

Un verde de `L=45%` funciona para (1) y para (2)-en-oscuro. Falla para (2)-en-claro. Como el sistema tiene un solo token, el tema claro quedó roto.

### Medición (fórmula WCAG 2.1, composición alpha en espacio gamma, superficie `--card`)

Reproducible: script en el scratchpad del propose; el test de la task 2 lo canoniza en el repo.

| Par | Claro | Oscuro |
|---|---|---|
| `text-success` sobre `bg-success/15` | **2,02** ❌ | 6,35 ✅ |
| `text-success` sobre card | **2,30** ❌ | 8,06 ✅ |
| `text-success-foreground` sobre `bg-success` | 8,62 ✅ | 8,62 ✅ |
| `text-warning` sobre `bg-warning/15` | **1,43** ❌ | 8,74 ✅ |
| `text-warning` sobre card | **1,53** ❌ | 12,12 ✅ |
| `text-warning-foreground` sobre `bg-warning` | 12,96 ✅ | 12,96 ✅ |
| `text-destructive` sobre `bg-destructive/15` | **3,09** ❌ | **1,76** ❌ |
| `text-destructive` sobre card | **3,76** ❌ | **1,85** ❌ |
| `text-destructive-foreground` sobre `bg-destructive` | **3,60** ❌ | 9,59 ✅ |
| `text-primary` sobre `bg-primary/15` | **2,02** ❌ | 6,35 ✅ |
| `text-primary` sobre card | **2,30** ❌ | 8,06 ✅ |
| `text-primary-foreground` sobre `bg-primary` | **2,09** ❌ | 8,62 ✅ |
| `--ring` sobre card (mín. 3:1) | **2,30** ❌ | 8,06 ✅ |

**13/13 fallan en claro. 2 fallan en oscuro.** Dos hallazgos que el reporte original no tenía:

- **El CTA principal del producto está en 2,09:1.** `--primary` y `--success` son el **mismo** verde `142 71% 45%`, pero `--success-foreground` es casi-negro y `--primary-foreground` en claro es `355.7 100% 97.3%` (rose-50, casi blanco). En `.dark`, `--primary-foreground` **ya es** `0 0% 3.9%`. El tema claro es el único inconsistente de los tres lugares donde se decide el texto sobre ese verde.
- **El tema oscuro no estaba sano.** `text-destructive` en oscuro resuelve al rojo oscuro `0 62.8% 30.6%` (pensado como fondo de botón) sobre un fondo oscuro: **1,76:1**, peor que cualquier fallo del tema claro. Afecta los `FormMessage` de todos los formularios.

## Goals / Non-Goals

**Goals**

- Los 28 pares canónicos (4 roles × 2 temas × {tinte peor caso, superficie plana, sólido} + `--ring`) alcanzan AA, medido por test.
- Cero churn en componentes: ningún `className` cambia.
- El color de marca de las **superficies** (verde primario, amarillo de alerta) no se altera.
- El gate impide que el design system vuelva a degradarse sin que nadie lo note.

**Non-Goals**

- No se corrigen los hex de `lib/three/*.ts` (materiales WebGL, no leen CSS vars — límite ya documentado en `docs/design-tokens.md`).
- No se implementa el lint de color de `v4-frontend-01` ni el resto de `v4-frontend-04` (axe-core en CI, `aria-label`, skip-link, command palette, focus-trap).
- No se introduce un rol `info`/categórico nuevo (no existe hoy; inventarlo no es alcance de este change).
- No se toca lógica de negocio, hooks de datos, RPCs, auth ni RLS.

## Decisions

### D1 — Tokens de texto dedicados (Opción B), no oscurecer las bases (Opción A)

**Elegido: Opción B** — `--success-text`, `--warning-text`, `--primary-text` nuevos; las bases quedan como están.

Se evaluó **Opción A** (oscurecer `--success`/`--warning` solo en el bloque `:root`). Se descarta por una asimetría medible: **el `-foreground` de `success`/`warning`/`primary` es casi-negro**, así que oscurecer la base sube el contraste del texto pero **hunde el del sólido**. Con `--success: 142 71% 26%`, el par `bg-success` + `text-success-foreground` cae de 8,62 a **3,26** — se cambia un fallo por otro. Además `--primary` es el mismo verde y alimenta 4 pantallas de gráficos vía `hsl(var(--primary))`; oscurecerlo repintaría todos los reportes.

**Excepción deliberada: `destructive` sí se arregla por Opción A.** Es el único rol cuyo `-foreground` es casi-**blanco** (`0 0% 98%`), así que oscurecer la base mejora los **dos** pares a la vez: texto 3,09 → 4,65 y sólido 3,60 → 5,80. Un solo cambio de valor en vez de un token nuevo más un botón que sigue fallando. En tema oscuro no aplica: ahí el sólido necesita ser oscuro para que el blanco se lea, y el texto necesita ser claro — requisitos irreconciliables, así que `--destructive-text` existe igual y en `.dark` vale un rojo claro.

### D2 — Cablear por `theme.extend.textColor`, no migrando 139 archivos

En Tailwind v3, `theme.textColor` deriva por defecto de `theme('colors')`, y `theme.extend.textColor` **se superpone solo sobre la paleta de utilities de texto**. Se remapean las 4 claves conservando la subclave `foreground`:

```ts
textColor: {
  success:     { DEFAULT: 'hsl(var(--success-text))',     foreground: 'hsl(var(--success-foreground))' },
  warning:     { DEFAULT: 'hsl(var(--warning-text))',     foreground: 'hsl(var(--warning-foreground))' },
  destructive: { DEFAULT: 'hsl(var(--destructive-text))', foreground: 'hsl(var(--destructive-foreground))' },
  primary:     { DEFAULT: 'hsl(var(--primary-text))',     foreground: 'hsl(var(--primary-foreground))' },
}
```

`bg-*`, `border-*`, `ring-*`, `fill-*` y `divide-*` siguen leyendo `theme.extend.colors` — el color de marca de las superficies queda intacto. El objeto (no un string) es obligatorio: un string mataría `text-success-foreground`, que hoy usan `facturacion/page.tsx:220` y `admin/pagos/ambiguas/page.tsx:150`.

**Por qué importa**: `text-destructive` aparece en **53 archivos** y `text-primary`/`bg-primary` en **67**. Migrar a un nombre de utility nuevo sería un diff enorme, propenso a omisiones, y dejaría dos utilities compitiendo (`text-success` vs `text-success-text`) para que el próximo componente elija mal. Esto es exactamente la regla de reutilización antes que repetición: el arreglo vive en la capa canónica (token + config), no repartido en 139 archivos.

**Trade-off aceptado**: `text-success` y `bg-success` dejan de resolver al mismo valor. Es intencional y es el punto del change, pero es sorprendente si no se sabe — por eso se documenta en `docs/design-tokens.md` con una columna por uso y se codifica como requirement del spec.

### D3 — Valores propuestos

Derivados invirtiendo la fórmula WCAG sobre el tinte compuesto y verificados con el script; el test de la task 2 es la autoridad final.

| Token | `:root` (claro) | `.dark` (oscuro) | Nota |
|---|---|---|---|
| `--success-text` | `142 71% 26%` (`#137136`) | `142 71% 45%` | oscuro conserva el valor vigente, que ya pasa |
| `--warning-text` | `40 95% 28%` (`#8B5E04`) | `48 96% 53%` | ídem |
| `--destructive-text` | `0 84% 42%` (`#C51111`) | `0 91% 71%` (`#F87272`) | en claro coincide con la base ya oscurecida |
| `--primary-text` | `142 71% 26%` | `142 71% 45%` | ídem |
| `--primary-foreground` | `0 0% 3.9%` *(cambia)* | `0 0% 3.9%` | alinea claro con oscuro y con `--success-foreground` |
| `--destructive` | `0 84% 42%` *(cambia, OQ-1)* | `0 62.8% 30.6%` | |
| `--ring` | `142 71% 35%` *(cambia)* | `142 71% 45%` | 2,30 → 3,70 (SC 1.4.11 pide 3:1) |

`--warning-text` corre el matiz de 48° a 40°: a `L=28%` el amarillo puro vira a oliva apagado; 40° da un ámbar oscuro que se lee como "familia del amarillo de alerta". Es el mismo desplazamiento de matiz que hacen las escalas de Radix al oscurecer. Si en la verificación visual el PO lo ve desconectado del tinte, `48 96% 26%` es la alternativa hue-fiel y también pasa (4,97:1).

Resultado con el set completo aplicado: **28/28 pares en PASS**, márgenes de 4,65 a 12,96 (el más ajustado es `text-destructive` sobre `bg-destructive/15` en claro).

### D4 — El test parsea el CSS, no el DOM ni el config

El gate lee `frontend/app/globals.css` con una regex sobre los bloques `:root` y `.dark`, y calcula en JS puro. Alternativas descartadas:

- **jsdom + `getComputedStyle`**: no resuelve `bg-success/15` (jsdom no compone alpha ni corre el pipeline de Tailwind); es lo que obligó a la verificación manual del hallazgo original.
- **Playwright contra la app corriendo**: mide lo real pero necesita stack levantado, es lento, y falla por razones ajenas al contraste. Queda como verificación complementaria de la task 5, no como gate.
- **Leer `tailwind.config.ts`**: el config solo dice `hsl(var(--x))`; los números están en el CSS. El CSS es la fuente de verdad, así que el test lee de ahí.

El test **también** afirma el cableado del config (que las 4 claves de `textColor` existen y apuntan a los tokens `-text`), porque si alguien borra ese bloque los ratios del CSS siguen verdes mientras la app vuelve a fallar en pantalla.

### D5 — La lista de pares vive en el test, no dispersa

Una única tabla de pares canónicos `{ rol, uso, umbral }` genera los casos. Agregar un rol futuro = agregar una fila. Evita la deriva entre lo que dice el spec y lo que el test cubre.

## Risks / Trade-offs

- **[El remapeo de `textColor` no se comporta como se espera en Tailwind v3.4]** → Es el riesgo central: todo el "cero churn" depende de él. La task 3 lo verifica compilando de verdad (utilities generadas / snapshot de CSS) antes de dar por buena la migración; si no funciona, el plan B es el nombre de utility explícito (`text-success-text`) y una migración acotada a los 19 archivos de success/warning, dejando destructive resuelto por D1-excepción y primary por OQ-2.
- **[`text-success` y `bg-success` dejan de ser el mismo color]** → Sorprende a quien lea el código. Mitigación: documentado en `docs/design-tokens.md` con una fila por uso, codificado como requirement del spec, y explicado en el comentario del bloque de tokens en `globals.css`.
- **[El verde oscuro de `text-primary` se lee como "apagado" en el dashboard]** → El PO puede percibirlo como pérdida de vitalidad de marca. Mitigación: las superficies (botones, barras de gráfico, badges rellenos) conservan el verde vívido; solo cambia el texto suelto. Se verifica en vivo (task 5) antes del merge.
- **[Oscurecer `--destructive` repinta la barra negativa de `/rentabilidad` y los botones destructivos]** → Es un cambio visible de producto. Mitigación: OQ-1 con sign-off explícito del PO; si lo rechaza, se revierte a Opción B pura para destructive (token `--destructive-text` propio en claro) y el par sólido queda documentado como brecha conocida con su ratio actual fijado como piso.
- **[Un test de contraste con un bug de aritmética da falsa confianza]** → Mitigación: la task 2 arranca en RED contra los valores **actuales** y debe reproducir los 13 fallos con los ratios de la tabla de Context (2,02 / 1,43 / 2,09…). Si el test dice "todo verde" antes de tocar los tokens, el test está mal, no el CSS.
- **[Tests existentes que afirman strings de clase]** → `CartItemList.test.tsx` afirma `text-warning`. El remapeo conserva el nombre, así que debe seguir verde sin tocarlo: es el control negativo de que no hubo churn.
- **[La verificación visual no puede cubrir 139 archivos]** → Se verifica por cohortes de forma de uso (badge sobre tinte, cifra sobre card, ícono, sólido, error de formulario, gráfico, anillo de foco), no archivo por archivo. Las cohortes y sus rutas están enumeradas en la task 5.

## Migration Plan

No hay migración de datos ni de esquema. Es un cambio de presentación con despliegue atómico:

1. Merge → Vercel construye y despliega. Los tokens viajan en el CSS del bundle; no hay estado persistido ni caché del lado del usuario que invalidar más allá del hash del asset.
2. **Rollback**: revertir el commit. No hay migración de DB, ni flag, ni compatibilidad hacia atrás que romper — ningún componente cambió de contrato.
3. Sin feature flag: un flag de color duplicaría la fuente de verdad de los tokens, que es justo lo que este change viene a evitar.

## Open Questions

- **OQ-1 (bloqueante para la task 4)** — ¿Se aprueba oscurecer `--destructive` en claro de `0 84.2% 60.2%` (`#EF4444`) a `0 84% 42%` (`#C51111`)? Arregla el botón destructivo (3,60 → 5,80) y el texto de error, con un solo cambio de valor. Costo: rojo visiblemente más oscuro en botones destructivos, badges y en la barra negativa de `/rentabilidad`. **Recomendación: sí** — 3,60:1 en un botón de acción destructiva es un fallo real de AA sobre un control de alto riesgo.
- **OQ-2** — ¿Se aprueba `--primary-foreground` en claro a casi-negro (`0 0% 3.9%`)? Es el fix más barato del par 2,09:1 y alinea el tema claro con el oscuro, que ya lo hace. Alternativa: oscurecer `--primary` a `142 71% 28%` para mantener el texto blanco, pero eso repinta el verde de marca en toda la app y en 4 pantallas de gráficos. **Recomendación: casi-negro.**
- **OQ-3** — ¿`--warning-text` con matiz corrido a 40° (ámbar oscuro, 5,29:1) o hue-fiel a 48° (oliva oscuro, 4,97:1)? Se decide mirándolo en la verificación visual de la task 5.
- **OQ-4** — El anillo de foco en oscuro pasa (8,06:1) pero comparte valor con `--primary`. Si más adelante se toca el verde de marca, `--ring` se mueve con él. ¿Se independiza `--ring` de `--primary` ahora, o se deja anotado para `v4-frontend-01`? **Recomendación: dejarlo anotado** — no hay fallo hoy y separarlo agrega un token sin defecto que lo justifique.
