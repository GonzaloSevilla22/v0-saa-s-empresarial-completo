/**
 * Gate del punto ciego de `token-contrast-aa` en la superficie de
 * administración de roles (v3-rbac-multirole Parte C, ronda 2 adversarial).
 *
 * `__tests__/lib/token-contrast-aa.test.ts` valida los pares canónicos de
 * `app/globals.css` (`text-muted-foreground`, `text-primary`,
 * `text-warning`, …) a **opacidad plena**. No puede ver —ni podría, porque
 * no corre el pipeline de Tailwind sobre las pantallas— una utilidad
 * `opacity-NN` aplicada ENCIMA de esos tokens en un componente: la
 * composición alpha baja el contraste real por debajo de AA sin que ningún
 * gate lo note.
 *
 * Eso es exactamente lo que se midió en vivo en `/organizacion/roles` (stack
 * local completo, composición alpha sobre el fondo efectivo de la tarjeta):
 *
 *   | elemento                            | clase                  | claro | oscuro | mín. |
 *   |-------------------------------------|------------------------|-------|--------|------|
 *   | etiqueta del rol VENCIDO             | `opacity-60`           | 2,32  | 3,36   | 4,5  |
 *   | fecha del rol VENCIDO ("venció …")   | `opacity-60`×`80`=0,48 | 1,92  | 2,59   | 4,5  |
 *   | fecha del rol VIGENTE ("hasta …")    | `opacity-80`           | 3,76  | 4,96   | 4,5  |
 *
 * Los tokens por sí solos SÍ cumplen (`text-muted-foreground` 4,83:1 claro /
 * 7,24:1 oscuro; `text-primary` 5,6:1 / 6,96:1) — el que rompía era el
 * multiplicador. Retirados los dos `opacity-*`, las tres filas pasan.
 *
 * Este gate impide la regresión atándose al ARTEFACTO REAL (lee el fuente de
 * las dos pantallas de la Parte C), no a una copia. Sólo prohíbe la opacidad
 * en variantes que aplican SIEMPRE: `disabled:opacity-*` y `hover:opacity-*`
 * siguen permitidas — WCAG 2.1 exime explícitamente a los controles
 * inactivos (1.4.3), y el estado hover es transitorio y no es el estado de
 * reposo del texto.
 *
 * RED: devolviendo `opacity-60` al badge del rol vencido en
 * `app/(dashboard)/organizacion/roles/page.tsx`, este test falla.
 */
import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const FRONTEND_ROOT = resolve(__dirname, "../..")

/** Superficie de la Parte C: las dos pantallas de administración de roles. */
const RBAC_ADMIN_FILES = [
  "app/(dashboard)/organizacion/roles/page.tsx",
  "app/(dashboard)/organizacion/invitar/page.tsx",
] as const

/**
 * `opacity-<n>` sin prefijo de variante. `disabled:opacity-50`,
 * `hover:opacity-80` y `group-hover:opacity-0` quedan fuera a propósito: la
 * clase de reposo es la única que decide el contraste del texto que el
 * usuario lee.
 */
const UNCONDITIONAL_OPACITY = /(^|[\s"'`{])(opacity-\d{1,3})(?=[\s"'`}]|$)/g

/** Quita comentarios de bloque y de línea para no contar una mención en prosa. */
function stripComments(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/[^\n]*/g, "$1")
}

describe("gate de contraste AA — utilidades opacity en la superficie RBAC", () => {
  for (const file of RBAC_ADMIN_FILES) {
    it(`${file} no atenúa texto con una utilidad opacity incondicional`, () => {
      const source = stripComments(readFileSync(resolve(FRONTEND_ROOT, file), "utf8"))
      const hits = [...source.matchAll(UNCONDITIONAL_OPACITY)].map((m) => m[2])

      expect(
        hits,
        `Utilidad(es) de opacidad sin variante en ${file}: ${hits.join(", ")}. ` +
          "Una opacity-* encima de un token de color baja el contraste real por " +
          "debajo de WCAG AA y el gate token-contrast-aa no puede verlo " +
          "(valida globals.css a opacidad plena). Usá un token semántico más " +
          "apagado, o marcá la diferencia con tamaño/tachado/texto.",
      ).toEqual([])
    })
  }

  it("el badge del rol vencido sigue distinguiéndose sin atenuar el contraste", () => {
    const source = readFileSync(
      resolve(FRONTEND_ROOT, "app/(dashboard)/organizacion/roles/page.tsx"),
      "utf8",
    )
    // Los tres discriminantes que reemplazan a la opacidad: token apagado,
    // tachado y el prefijo textual del estado.
    expect(source).toContain("text-muted-foreground")
    expect(source).toContain("line-through")
    expect(source).toMatch(/"hasta"\s*:\s*"venció"|is_active \? "hasta" : "venció"/)
  })
})
