/**
 * Gate de contraste WCAG 2.1 AA — `tokens-contraste-aa` (task 2.1).
 *
 * La verificación visual de `clientes-frecuentes-historial` (task 10.1,
 * 2026-08-17) encontró que `text-success` sobre `bg-success/15` mide
 * 2,02:1 en tema claro — muy por debajo del 4,5:1 que exige WCAG AA para
 * texto. La auditoría completa (design.md §Context) mostró que el problema
 * alcanza 11 de los 13 pares canónicos en tema claro y 2 en tema oscuro
 * (13 fallos combinados). Este test es el RED de ese hallazgo y el gate
 * anti-regresión permanente: parsea `frontend/app/globals.css` — única
 * fuente de verdad de los tokens — y calcula el ratio de contraste real de
 * cada par canónico en ambos temas, en vez de depender de una auditoría
 * manual.
 *
 * Por qué no jsdom/getComputedStyle (design.md §D4): jsdom no compone
 * alpha ni corre el pipeline de Tailwind, así que no puede resolver
 * `bg-success/15` — es exactamente lo que obligó a medir el hallazgo
 * original a mano. Este test hace la aritmética en TypeScript puro
 * (HSL→RGB, linearización sRGB, luminancia relativa, composición alpha en
 * espacio gamma) sobre los valores crudos del CSS.
 *
 * Reutilización (task 2.6): no existía ninguna utilidad de
 * luminance/hslToRgb/contrast en `frontend/lib/` ni en `frontend/__tests__/`
 * al escribir este test (`grep -i "luminance|hslToRgb|contrast"` sobre
 * ambos directorios no encontró nada relevante — el único hit fue un
 * comentario de un test de Three.js no relacionado). La aritmética nace acá
 * porque es la única consumidora hoy; si un segundo consumidor aparece,
 * se promueve a `frontend/lib/`.
 *
 * RED intencional (task 2.2): al momento de escribir este test,
 * `--success-text` / `--warning-text` / `--destructive-text` /
 * `--primary-text` todavía NO existen en `globals.css`. `readVar()` cae al
 * token base (`--success`, etc.) cuando el token `-text` no está
 * declarado — así el test reproduce EXACTAMENTE cómo resuelve Tailwind hoy
 * (`text-success` usa `--success`) y sigue siendo válido sin reescribirse
 * cuando el grupo 3 agregue los tokens `-text` (solo cambia el CSS).
 *
 * Grupo 4 (superficies sólidas `destructive`/`primary`) requiere sign-off
 * del PO para OQ-1/OQ-2 (design.md §Open Questions) y no corre en este
 * apply. Mientras tanto, los dos pares que dependen de esas decisiones se
 * afirman como PISO (no empeorar el ratio documentado) en vez del umbral
 * real — ver `ROLES[…].solidKnownGap` más abajo. Es el mismo patrón que
 * prescribe la task 4.3 para el caso de rechazo del PO.
 */
import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const FRONTEND_ROOT = resolve(__dirname, "../..")
const GLOBALS_CSS_PATH = resolve(FRONTEND_ROOT, "app/globals.css")
const TAILWIND_CONFIG_PATH = resolve(FRONTEND_ROOT, "tailwind.config.ts")

// ---------------------------------------------------------------------------
// Aritmética WCAG 2.1 (HSL → RGB → luminancia relativa → ratio de contraste)
// ---------------------------------------------------------------------------

interface Hsl {
  h: number
  s: number
  l: number
}

interface Rgb {
  r: number
  g: number
  b: number
}

/** Parsea el formato de las CSS custom properties de shadcn/ui: "142 71% 45%". */
function parseHsl(raw: string): Hsl {
  const match = raw.trim().match(/^(-?[\d.]+)\s+([\d.]+)%\s+([\d.]+)%$/)
  if (!match) {
    throw new Error(`No se pudo parsear el valor HSL: "${raw}"`)
  }
  const [, h, s, l] = match
  return { h: Number(h), s: Number(s), l: Number(l) }
}

function hslToRgb({ h, s, l }: Hsl): Rgb {
  const sFrac = s / 100
  const lFrac = l / 100
  const c = (1 - Math.abs(2 * lFrac - 1)) * sFrac
  const hPrime = (((h % 360) + 360) % 360) / 60
  const x = c * (1 - Math.abs((hPrime % 2) - 1))
  const m = lFrac - c / 2

  let rPrime: number
  let gPrime: number
  let bPrime: number
  if (hPrime < 1) [rPrime, gPrime, bPrime] = [c, x, 0]
  else if (hPrime < 2) [rPrime, gPrime, bPrime] = [x, c, 0]
  else if (hPrime < 3) [rPrime, gPrime, bPrime] = [0, c, x]
  else if (hPrime < 4) [rPrime, gPrime, bPrime] = [0, x, c]
  else if (hPrime < 5) [rPrime, gPrime, bPrime] = [x, 0, c]
  else [rPrime, gPrime, bPrime] = [c, 0, x]

  return {
    r: (rPrime + m) * 255,
    g: (gPrime + m) * 255,
    b: (bPrime + m) * 255,
  }
}

/**
 * Composición alpha "over" en espacio gamma (sRGB codificado, sin
 * linealizar) — es lo que hace el navegador al pintar `bg-success/15`
 * sobre una superficie opaca (design.md §D4). `bg` se asume 100% opaco
 * (--card / --background siempre lo son en este sistema de tokens).
 */
function compositeOver(fg: Rgb, bg: Rgb, alpha: number): Rgb {
  return {
    r: alpha * fg.r + (1 - alpha) * bg.r,
    g: alpha * fg.g + (1 - alpha) * bg.g,
    b: alpha * fg.b + (1 - alpha) * bg.b,
  }
}

function srgbChannelToLinear(channel255: number): number {
  const c = channel255 / 255
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function relativeLuminance(rgb: Rgb): number {
  const r = srgbChannelToLinear(rgb.r)
  const g = srgbChannelToLinear(rgb.g)
  const b = srgbChannelToLinear(rgb.b)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** WCAG 2.1 fórmula de contraste: (L_claro + 0.05) / (L_oscuro + 0.05). */
function contrastRatio(a: Rgb, b: Rgb): number {
  const la = relativeLuminance(a)
  const lb = relativeLuminance(b)
  const lighter = Math.max(la, lb)
  const darker = Math.min(la, lb)
  return (lighter + 0.05) / (darker + 0.05)
}

// ---------------------------------------------------------------------------
// Parsing de frontend/app/globals.css
// ---------------------------------------------------------------------------

type ThemeName = "light" | "dark"

/** Bloque de variables `{ "--nombre": "valor crudo" }` de un tema. */
type CssVarBlock = Record<string, string>

function extractBlock(css: string, selectorPattern: string): CssVarBlock {
  // Sin llaves anidadas dentro de :root/.dark en este archivo — un match no
  // codicioso hasta el primer "}" cierra el bloque correctamente.
  const blockMatch = css.match(new RegExp(`${selectorPattern}\\s*\\{([^}]*)\\}`))
  if (!blockMatch) {
    throw new Error(`No se encontró el bloque "${selectorPattern}" en globals.css`)
  }
  const body = blockMatch[1]
  const vars: CssVarBlock = {}
  const varRegex = /--([\w-]+):\s*([^;]+);/g
  let m: RegExpExecArray | null
  while ((m = varRegex.exec(body)) !== null) {
    vars[`--${m[1]}`] = m[2].trim()
  }
  return vars
}

/**
 * Extrae el cuerpo de un bloque `clave: { ... }` de un source TS/JS
 * contando llaves — a diferencia de `extractBlock` (CSS, sin anidamiento),
 * acá SÍ hay objetos anidados (`{ DEFAULT, foreground }` por rol), así que
 * un regex no-codicioso simple corta en el primer `}` interno. Devuelve
 * `null` si la clave no existe.
 */
function extractBalancedBlock(source: string, key: string): string | null {
  const startMatch = source.match(new RegExp(`${key}:\\s*\\{`))
  if (!startMatch || startMatch.index === undefined) return null
  const openIndex = startMatch.index + startMatch[0].length - 1
  let depth = 0
  for (let i = openIndex; i < source.length; i++) {
    if (source[i] === "{") depth++
    else if (source[i] === "}") {
      depth--
      if (depth === 0) return source.slice(openIndex + 1, i)
    }
  }
  return null
}

function loadThemeBlocks(): Record<ThemeName, CssVarBlock> {
  const css = readFileSync(GLOBALS_CSS_PATH, "utf-8")
  return {
    light: extractBlock(css, ":root"),
    dark: extractBlock(css, "\\.dark"),
  }
}

/**
 * Lee `varName` del bloque; si no existe, cae a `fallbackVarName`. Modela
 * cómo Tailwind resuelve `text-<rol>` hoy (sin token `-text` dedicado, la
 * utility usa el token base) — ver nota de RED intencional en el header.
 */
function readVar(block: CssVarBlock, varName: string, fallbackVarName?: string): Rgb {
  const raw = block[varName] ?? (fallbackVarName ? block[fallbackVarName] : undefined)
  if (raw === undefined) {
    throw new Error(
      `Ninguna variable "${varName}"${fallbackVarName ? ` ni su fallback "${fallbackVarName}"` : ""} existe en el bloque`
    )
  }
  return hslToRgb(parseHsl(raw))
}

// ---------------------------------------------------------------------------
// Tabla de pares canónicos (task 2.5 — D5: una sola tabla { rol, uso,
// umbral } genera los casos; agregar un rol futuro = agregar una fila).
// ---------------------------------------------------------------------------

const TEXT_THRESHOLD = 4.5 // WCAG AA texto normal
const UI_THRESHOLD = 3.0 // WCAG AA SC 1.4.11 (indicadores de UI no textuales)
const TINT_OPACITIES = [0.05, 0.1, 0.15] as const // /5 /10 /15
const FLAT_SURFACES = ["--card", "--background"] as const

interface RoleSpec {
  role: "success" | "warning" | "destructive" | "primary"
  textVar: string
  baseVar: string
  foregroundVar: string
  /**
   * Brecha conocida en el par sólido (`<rol>-foreground` sobre `bg-<rol>`),
   * bloqueada por sign-off del PO (design.md §Open Questions — OQ-1 para
   * destructive, OQ-2 para primary). Mientras el grupo 4 no corre, ese par
   * se afirma como PISO (el ratio no puede empeorar respecto del valor
   * documentado) en vez del umbral real de 4,5:1 — mismo patrón que
   * prescribe la task 4.3 para el caso de rechazo del PO. El resto de los
   * pares de estos roles (texto sobre tinte, texto sobre card) SÍ usan sus
   * propios tokens `-text` nuevos (grupo 3, no bloqueado) y se exigen al
   * umbral real.
   */
  solidKnownGap?: Partial<Record<ThemeName, number>>
}

const ROLES: readonly RoleSpec[] = [
  { role: "success", textVar: "--success-text", baseVar: "--success", foregroundVar: "--success-foreground" },
  { role: "warning", textVar: "--warning-text", baseVar: "--warning", foregroundVar: "--warning-foreground" },
  {
    role: "destructive",
    textVar: "--destructive-text",
    baseVar: "--destructive",
    foregroundVar: "--destructive-foreground",
    // OQ-1 (design.md): oscurecer --destructive en :root subiría este par
    // de 3,60 a 5,80. Piso = 3,60 hasta el sign-off (grupo 4).
    solidKnownGap: { light: 3.6 },
  },
  {
    role: "primary",
    textVar: "--primary-text",
    baseVar: "--primary",
    foregroundVar: "--primary-foreground",
    // OQ-2 (design.md): --primary-foreground casi-negro subiría este par
    // de 2,09 a 8,62. Piso = 2,09 hasta el sign-off (grupo 4).
    solidKnownGap: { light: 2.09 },
  },
] as const

type PairKind = "text-on-tint" | "text-on-surface" | "foreground-on-solid" | "ui-on-surface"

interface ContrastCase {
  label: string
  theme: ThemeName
  kind: PairKind
  role: string
  ratio: number
  threshold: number
  isKnownGap: boolean
}

/**
 * Peor caso de contraste texto-sobre-tinte (task 2.4): recorre /5, /10 y
 * /15 sobre --card Y --background y devuelve el ratio más bajo. No se
 * asume cuál opacidad/superficie es peor — se calcula. Para un token de
 * texto que comparte matiz con su base (todos los roles acá), la opacidad
 * más alta (15%) domina siempre: el tinte se acerca más al color base a
 * medida que sube la opacidad, y el color base está más cerca en
 * luminancia del texto (mismo tono) que la superficie plana — así que más
 * opacidad = menos distancia = menos contraste. Verificado por cálculo
 * para los 4 roles × 2 temas al escribir este test: /15 es siempre el
 * mínimo. El código igual evalúa las 6 combinaciones por si un valor
 * futuro rompe esa monotonía.
 */
function worstTintRatio(
  textRgb: Rgb,
  baseRgb: Rgb,
  block: CssVarBlock
): { ratio: number; detail: string } {
  let worst = Number.POSITIVE_INFINITY
  let worstDetail = ""
  for (const surfaceVar of FLAT_SURFACES) {
    const surfaceRgb = readVar(block, surfaceVar)
    for (const opacity of TINT_OPACITIES) {
      const tint = compositeOver(baseRgb, surfaceRgb, opacity)
      const ratio = contrastRatio(textRgb, tint)
      if (ratio < worst) {
        worst = ratio
        worstDetail = `${surfaceVar}/${Math.round(opacity * 100)}`
      }
    }
  }
  return { ratio: worst, detail: worstDetail }
}

function buildCases(blocks: Record<ThemeName, CssVarBlock>): ContrastCase[] {
  const cases: ContrastCase[] = []

  for (const theme of ["light", "dark"] as const) {
    const block = blocks[theme]
    const card = readVar(block, "--card")

    for (const spec of ROLES) {
      const textRgb = readVar(block, spec.textVar, spec.baseVar)
      const baseRgb = readVar(block, spec.baseVar)
      const foregroundRgb = readVar(block, spec.foregroundVar)

      const { ratio: tintRatio, detail } = worstTintRatio(textRgb, baseRgb, block)
      cases.push({
        label: `text-${spec.role} sobre ${detail} (peor caso de tinte)`,
        theme,
        kind: "text-on-tint",
        role: spec.role,
        ratio: tintRatio,
        threshold: TEXT_THRESHOLD,
        isKnownGap: false,
      })

      cases.push({
        label: `text-${spec.role} sobre --card`,
        theme,
        kind: "text-on-surface",
        role: spec.role,
        ratio: contrastRatio(textRgb, card),
        threshold: TEXT_THRESHOLD,
        isKnownGap: false,
      })

      const solidRatio = contrastRatio(foregroundRgb, baseRgb)
      const gapFloor = spec.solidKnownGap?.[theme]
      cases.push({
        label: `text-${spec.role}-foreground sobre bg-${spec.role} (sólido)`,
        theme,
        kind: "foreground-on-solid",
        role: spec.role,
        ratio: solidRatio,
        threshold: gapFloor ?? TEXT_THRESHOLD,
        isKnownGap: gapFloor !== undefined,
      })
    }

    const ring = readVar(block, "--ring")
    for (const surfaceVar of FLAT_SURFACES) {
      const surfaceRgb = readVar(block, surfaceVar)
      cases.push({
        label: `--ring sobre ${surfaceVar}`,
        theme,
        kind: "ui-on-surface",
        role: "ring",
        ratio: contrastRatio(ring, surfaceRgb),
        threshold: UI_THRESHOLD,
        isKnownGap: false,
      })
    }
  }

  return cases
}

// ---------------------------------------------------------------------------
// Gate
// ---------------------------------------------------------------------------

describe("token-contrast-aa — gate WCAG 2.1 AA de los tokens semánticos", () => {
  const blocks = loadThemeBlocks()
  const cases = buildCases(blocks)

  it("genera 28 pares canónicos (4 roles × 3 tipos × 2 temas + ring × 2 superficies × 2 temas)", () => {
    expect(cases).toHaveLength(28)
  })

  it.each(cases.map((c) => [`${c.theme} · ${c.label}${c.isKnownGap ? " [piso — pendiente PO]" : ""}`, c] as const))(
    "%s",
    (_label, c) => {
      expect(c.ratio).toBeGreaterThanOrEqual(c.threshold)
    }
  )

  it("los pares afirmados como umbral real (no piso) alcanzan AA — cuenta 26/28", () => {
    const realCases = cases.filter((c) => !c.isKnownGap)
    expect(realCases).toHaveLength(26)
    for (const c of realCases) {
      expect(c.ratio, c.label).toBeGreaterThanOrEqual(c.threshold)
    }
  })

  it("evalúa :root y .dark por separado — ningún tema se da por válido porque el otro pase", () => {
    const lightCases = cases.filter((c) => c.theme === "light")
    const darkCases = cases.filter((c) => c.theme === "dark")
    expect(lightCases).toHaveLength(14)
    expect(darkCases).toHaveLength(14)
  })

  // D4: el test también afirma el cableado del config — si alguien borra el
  // bloque textColor, los ratios del CSS siguen verdes mientras la app
  // vuelve a fallar en pantalla.
  it("tailwind.config.ts remapea theme.extend.textColor a los 4 tokens *-text, conservando *-foreground", () => {
    const configSrc = readFileSync(TAILWIND_CONFIG_PATH, "utf-8")
    const body = extractBalancedBlock(configSrc, "textColor")
    expect(body, "tailwind.config.ts debe declarar theme.extend.textColor").toBeTruthy()
    const safeBody = body ?? ""
    for (const spec of ROLES) {
      expect(safeBody, `falta la clave "${spec.role}" en textColor`).toMatch(new RegExp(`${spec.role}:\\s*\\{`))
      expect(safeBody, `${spec.role}.DEFAULT debe resolver a hsl(var(${spec.textVar}))`).toContain(
        `hsl(var(${spec.textVar}))`
      )
      expect(safeBody, `${spec.role}.foreground debe resolver a hsl(var(${spec.foregroundVar}))`).toContain(
        `hsl(var(${spec.foregroundVar}))`
      )
    }
  })
})

// ---------------------------------------------------------------------------
// TRIANGULATE (task 2.3) — casos de borde con valores de referencia
// independientes, para descartar que la fórmula infle o deflacte de forma
// sistemática.
// ---------------------------------------------------------------------------

describe("token-contrast-aa — aritmética (casos de borde, task 2.3)", () => {
  it("negro sobre blanco = 21:1 (máximo contraste posible)", () => {
    const black: Rgb = { r: 0, g: 0, b: 0 }
    const white: Rgb = { r: 255, g: 255, b: 255 }
    expect(contrastRatio(black, white)).toBeCloseTo(21, 1)
  })

  it("blanco sobre blanco = 1:1 (mínimo contraste posible)", () => {
    const white: Rgb = { r: 255, g: 255, b: 255 }
    expect(contrastRatio(white, white)).toBeCloseTo(1, 5)
  })

  it("par conocido-bueno del CSS actual: text-warning-foreground sobre bg-warning = 12,96 en ambos temas (valor sin cambios por este change)", () => {
    const blocks = loadThemeBlocks()
    for (const theme of ["light", "dark"] as const) {
      const block = blocks[theme]
      const foreground = readVar(block, "--warning-foreground")
      const base = readVar(block, "--warning")
      expect(contrastRatio(foreground, base), theme).toBeCloseTo(12.96, 1)
    }
  })
})
