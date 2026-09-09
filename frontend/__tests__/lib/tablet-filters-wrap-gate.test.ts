/**
 * tablet-filtros-cta — gate atado al artefacto REAL, no sólo al arnés.
 *
 * `e2e/harness/g-tablet-filters-cta.spec.ts` prueba el contrato visual
 * (el CTA entra en el viewport a 1024px) contra `TabletFiltersHarness.tsx`,
 * un arnés que COPIA a mano las clases de las 4 páginas reales. Si algún PR
 * cambia el markup real (sale/purchase-operations-list.tsx, gastos/page.tsx,
 * clientes/page.tsx) sin actualizar el arnés, el gate de Playwright sigue en
 * verde — está probando una copia, no el original.
 *
 * Este test cierra ese hueco: lee con `readFileSync` el código fuente de las
 * 4 superficies reales Y del arnés, y asserta:
 *  - el contenedor de controles (marcado `data-testid="filters-bar"`) lleva
 *    `lg:flex-wrap` en las 5 (paridad arnés↔páginas: la MISMA clase, no una
 *    aproximada);
 *  - el grupo de filtros (`data-testid="filters-group"`) lleva `flex-wrap`
 *    (como `sm:flex-wrap`, que SIGUE conteniendo el token) en las 5.
 *
 * Localiza los elementos por el `data-testid` (no por la cadena de clases
 * completa) para que la aserción no dependa de espacios o de reordenar
 * clases al tocar la barra por otro motivo.
 *
 * RED: sacando `lg:flex-wrap` de una de las 4 páginas reales (dejando el
 * arnés intacto), este test falla — a diferencia del spec de Playwright,
 * que seguiría en verde contra la copia. Restaurado con Edit, vuelve a
 * pasar (ver el registro de verificación en el reporte de cierre).
 */
import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const FRONTEND_ROOT = resolve(__dirname, "../..")

const REAL_FILES = [
  "components/ventas/sale-operations-list.tsx",
  "components/compras/purchase-operations-list.tsx",
  "app/(dashboard)/gastos/page.tsx",
  "app/(dashboard)/clientes/page.tsx",
] as const

const HARNESS_FILE = "app/dev-harness/tablet-filters/TabletFiltersHarness.tsx"

const ALL_FILES = [...REAL_FILES, HARNESS_FILE]

/** Extrae el className del primer elemento cuya etiqueta de apertura declara
 *  `data-testid="{testId}"`, sin importar el orden de los atributos ni los
 *  saltos de línea entre ellos. */
function classNameOf(source: string, testId: string): string {
  const tagMatch = source.match(new RegExp(`<div[^>]*data-testid="${testId}"[^>]*>`, "s"))
  if (!tagMatch) throw new Error(`No se encontró data-testid="${testId}"`)
  const classMatch = tagMatch[0].match(/className="([^"]+)"/)
  if (!classMatch) throw new Error(`data-testid="${testId}" no tiene className`)
  return classMatch[1]
}

function classes(className: string): string[] {
  return className.split(/\s+/).filter(Boolean)
}

describe("tablet-filtros-cta — el contenedor y el grupo de filtros llevan las clases de wrap (fuente real, no el arnés)", () => {
  for (const file of ALL_FILES) {
    it(`${file}: el contenedor de controles (filters-bar) lleva lg:flex-wrap`, () => {
      const source = readFileSync(resolve(FRONTEND_ROOT, file), "utf-8")
      const className = classNameOf(source, "filters-bar")
      expect(classes(className)).toContain("lg:flex-wrap")
    })

    it(`${file}: el grupo de filtros (filters-group) lleva flex-wrap`, () => {
      const source = readFileSync(resolve(FRONTEND_ROOT, file), "utf-8")
      const className = classNameOf(source, "filters-group")
      expect(className).toContain("flex-wrap")
    })
  }

  it("paridad arnés↔páginas: el contenedor de controles del arnés usa EXACTAMENTE las mismas clases que las 4 páginas reales", () => {
    const containerClasses = ALL_FILES.map((file) =>
      classNameOf(readFileSync(resolve(FRONTEND_ROOT, file), "utf-8"), "filters-bar"),
    )
    const [first, ...rest] = containerClasses
    for (const other of rest) expect(other).toBe(first)
  })
})
