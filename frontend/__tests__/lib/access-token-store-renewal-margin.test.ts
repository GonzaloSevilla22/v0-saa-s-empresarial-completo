// @vitest-environment node
/**
 * auth-hardening-jwt-cookies — Parte C. Revisión adversarial pre-merge (MINOR: el
 * margen de renovación del navegador depende, sin decirlo, de una constante de
 * `auth-js`).
 *
 * El navegador pide el token cuando le faltan menos de `RENEWAL_MARGIN_MS`. El
 * servidor sólo lo renueva cuando le faltan menos de `EXPIRY_MARGIN_MS`
 * (`auth-js/dist/main/lib/constants.js`), que es el margen con el que
 * `getSession()` decide llamar a GoTrue (`GoTrueClient.js:2341-2371`).
 *
 * Si el margen del navegador superara el del servidor, el manejador devolvería el
 * **mismo** token —para él todavía no vence—, el navegador lo seguiría viendo por
 * vencer y agendaría la renovación con `delay = 0` (`access-token-store.ts:117`):
 * una tormenta de pedidos contra el endpoint más caliente que introduce la Parte C y
 * contra un balde de rate limit que, desde D20, comparten los 38 tenants.
 *
 * Es una relación entre un número nuestro y un número de la librería, y ninguna de
 * las dos partes la menciona. Este candado la hace explícita y la deja medida
 * contra la versión instalada, no contra un comentario.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { createRequire } from "node:module"
import { RENEWAL_MARGIN_MS } from "@/lib/auth/access-token-store"

/**
 * `constants.js` de la versión de `auth-js` realmente instalada. `auth-js` es
 * dependencia transitiva de `supabase-js`, así que se resuelve **a través** de él
 * (pnpm no la expone en el `node_modules` del frontend) y nunca por una ruta
 * `.pnpm/@supabase+auth-js@<versión>` escrita a mano, que envejecería con el
 * próximo bump.
 */
function authJsConstantsSource(): string {
  const fromFrontend = createRequire(path.join(process.cwd(), "index.js"))
  const supabaseJs = fromFrontend.resolve("@supabase/supabase-js")
  const authJsEntry = createRequire(supabaseJs).resolve("@supabase/auth-js")
  const constants = path.join(path.dirname(authJsEntry), "lib", "constants.js")
  return fs.readFileSync(constants, "utf8")
}

function numericExport(source: string, name: string): number {
  // `exports.X = 30 * 1000;` / `exports.X = 3;`
  const match = source.match(new RegExp(String.raw`exports\.${name}\s*=\s*([0-9*\s]+);`))
  if (!match) throw new Error(`no se encontró exports.${name} en constants.js de auth-js`)
  return match[1]
    .split("*")
    .map((part) => Number(part.trim()))
    .reduce((a, b) => a * b, 1)
}

describe("el margen de renovación del navegador contra el del servidor", () => {
  const source = authJsConstantsSource()
  const tickMs = numericExport(source, "AUTO_REFRESH_TICK_DURATION_MS")
  const threshold = numericExport(source, "AUTO_REFRESH_TICK_THRESHOLD")
  const expiryMarginMs = tickMs * threshold

  it("se leen los dos números de la librería instalada (el test no compara NaN)", () => {
    expect(tickMs).toBe(30_000)
    expect(threshold).toBe(3)
    expect(expiryMarginMs).toBe(90_000)
  })

  it("el margen del navegador es MENOR que el del servidor", () => {
    expect(
      RENEWAL_MARGIN_MS,
      `RENEWAL_MARGIN_MS (${RENEWAL_MARGIN_MS} ms) tiene que ser menor que el EXPIRY_MARGIN_MS ` +
        `de auth-js (${expiryMarginMs} ms): si no, el manejador devuelve el mismo token, el ` +
        `navegador lo sigue viendo por vencer y reintenta con delay 0.`,
    ).toBeLessThan(expiryMarginMs)
  })

  it("y no es cero ni negativo: un token puede vencer en vuelo", () => {
    expect(RENEWAL_MARGIN_MS).toBeGreaterThan(0)
  })
})
