/**
 * Paridad de los DOS exports de gastos (gastos-forma-pago, tasks 11.5/11.5b).
 *
 * El usuario tiene dos caminos para bajarse sus gastos y no sabe que son dos:
 *   · el CSV local de `/gastos` (`exportToCSV`, sólo la página vigente);
 *   · el `ExportButton`, que se resuelve en la Edge Function Deno
 *     `supabase/functions/generate-export/index.ts` y también alimenta la hoja
 *     "Gastos" del XLSX consolidado.
 *
 * La task lo dice explícitamente: tocar uno solo los deja divergentes, y el
 * usuario ve una columna en un archivo y no en el otro. Ninguna suite podía
 * detectarlo — el export local no tenía test y la Edge Function sólo tiene un
 * test de integración que se saltea sin credenciales. Este gate lee los dos
 * archivos y exige la columna en ambos.
 *
 * ⚠️ La Edge Function tiene DEPLOY PROPIO: no viaja con la migración del
 * merge. Este test verifica el código, no el despliegue.
 */
import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const REPO_ROOT = resolve(__dirname, "../../..")
const EDGE_FN = resolve(REPO_ROOT, "supabase/functions/generate-export/index.ts")
const GASTOS_PAGE = resolve(__dirname, "../../app/(dashboard)/gastos/page.tsx")

const edgeSource = readFileSync(EDGE_FN, "utf-8")
const pageSource = readFileSync(GASTOS_PAGE, "utf-8")

describe("export de gastos — paridad entre el CSV local y la Edge Function", () => {
  it("el CSV local de /gastos declara la columna 'Forma de pago'", () => {
    expect(pageSource).toContain('header: "Forma de pago"')
  })

  it("el CSV de la Edge Function declara la columna 'forma_pago' en los headers de expenses_csv", () => {
    expect(edgeSource).toContain(
      "rowsToCsv(['fecha', 'categoria', 'descripcion', 'forma_pago', 'monto', 'moneda', 'sucursal'], rows)",
    )
  })

  it("`fetchExpensesRows` hace el JOIN al catálogo y emite el campo, no sólo el header", () => {
    // Un header sin su campo produce una columna vacía en todas las filas: es
    // la forma más silenciosa de "cumplir" la task sin exportar el dato.
    expect(edgeSource).toContain("payment_method:payment_methods(name)")
    expect(edgeSource).toMatch(/forma_pago:\s+\(\(r\.payment_method/)
  })

  it("los dos caminos usan el MISMO literal para el gasto sin imputar", () => {
    expect(edgeSource).toContain("'Sin especificar'")
    expect(pageSource).toContain('"Sin especificar"')
  })

  it("la hoja 'Gastos' del XLSX consolidado se alimenta del mismo fetchExpensesRows", () => {
    // Si alguien duplicara el fetch para el XLSX, la columna aparecería en el
    // CSV y no en el Excel — exactamente la divergencia que este gate cuida.
    const occurrences = (edgeSource.match(/fetchExpensesRows\(supabase, dateFrom\)/g) ?? []).length
    expect(occurrences).toBe(2)
    expect(edgeSource).toContain("{ name: 'Gastos',     rows: expensesRows }")
  })
})
