/**
 * estadisticas-ventas E3 (grupo 8) — export del ranking de productos a CSV.
 *
 * Importa el módulo REAL `supabase/functions/_shared/export-ranking.ts` por
 * ruta relativa (patrón D5/D6 de ai-quota.test.ts: TS puro, sin `Deno.*` a
 * nivel módulo). Lo que se fija acá:
 *
 * - 8.1 / 8.3 (RED): `product_ranking_csv` es un ExportType válido y un tipo
 *   desconocido se rechaza. La UNIÓN de tipos y el ARRAY de tipos válidos que
 *   generate-export duplicaba dejan de existir por separado: hay UNA lista
 *   (EXPORT_TYPES) de la que deriva el tipo, así que no pueden desincronizarse.
 * - 8.4: las filas del CSV salen de las filas del read-model canónico
 *   (rpc_product_ranking), 1:1 y EN EL MISMO ORDEN — la Edge Function no
 *   re-agrega ni reordena; pagina la RPC de a 500 con los MISMOS parámetros
 *   que la pantalla (período, orden, agrupación, sucursal).
 * - Parámetros: defaults de la pantalla (últimos 30 días, unidades,
 *   agrupado), y rechazo de orden / fecha / rango / uuid inválidos ANTES de
 *   tocar la base.
 * - D11: un margen ausente viaja como celda vacía, nunca como 0.
 * - Fix 2026-09-04 (humo real del PO, "se ve mal el excel"): el separador
 *   pasa de coma a `;` (Excel es-AR usa coma decimal y `;` como separador de
 *   listas — misma convención que `frontend/lib/excel.ts`), y las columnas
 *   numéricas del ranking (unidades/importe/costo/margen/margen_pct/
 *   cobertura_costo_pct) convierten el punto decimal de Postgres a coma. Los
 *   otros 5 tipos de export comparten `rowsToCsv` (separador) pero NO tocan
 *   sus decimales — alimentan el ida y vuelta exportar→editar→importar.
 *
 * Run: pnpm vitest run __tests__/export-ranking.test.ts
 */

import { describe, it, expect, vi } from "vitest"
import {
  EXPORT_TYPES,
  RANKING_CSV_HEADERS,
  RANKING_PAGE_SIZE,
  RANKING_MAX_ROWS,
  buildRankingCsv,
  fetchAllRankingRows,
  isExportType,
  parseRankingExportParams,
  rankingRowToCsvRow,
  rowsToCsv,
  type ProductRankingRpcRow,
  type RankingRpcClient,
} from "../../supabase/functions/_shared/export-ranking"

const TODAY = new Date("2026-09-04T15:00:00.000Z")
const ACCOUNT = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
const BRANCH = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

function rpcRow(rank: number, overrides: Partial<ProductRankingRpcRow> = {}): ProductRankingRpcRow {
  return {
    rank,
    product_id: `00000000-0000-0000-0000-${String(rank).padStart(12, "0")}`,
    product_name: `Producto ${rank}`,
    sku: `SKU-${rank}`,
    category: "Ropa",
    parent_id: null,
    parent_name: null,
    is_group: false,
    variant_count: 0,
    units: "5",
    revenue: "2350",
    operations: 3,
    total_cost: "1500",
    gross_margin: "850",
    gross_margin_pct: "36.17",
    cost_coverage_pct: "33.3",
    last_sale_date: "2026-08-31",
    total_count: 1,
    ...overrides,
  }
}

// ─── 8.1 / 8.3: tipos de exportación (una sola fuente) ───────────────────────

describe("EXPORT_TYPES / isExportType (8.1, 8.3)", () => {
  it("incluye los 5 tipos legacy y el 6º, product_ranking_csv", () => {
    expect([...EXPORT_TYPES].sort()).toEqual(
      ["expenses_csv", "full_report_xlsx", "product_ranking_csv", "purchases_csv", "sales_csv", "stock_csv"],
    )
    expect(isExportType("product_ranking_csv")).toBe(true)
    expect(isExportType("sales_csv")).toBe(true)
  })

  it("rechaza un tipo desconocido, vacío o no textual (sin generar archivo ni consumir cuota)", () => {
    expect(isExportType("ranking_csv")).toBe(false)
    expect(isExportType("")).toBe(false)
    expect(isExportType(undefined)).toBe(false)
    expect(isExportType(null)).toBe(false)
    expect(isExportType(42)).toBe(false)
  })
})

// ─── parámetros del ranking ──────────────────────────────────────────────────

describe("parseRankingExportParams", () => {
  it("sin body aplica los defaults de la pantalla: últimos 30 días (hoy incluido), unidades, agrupado, sin sucursal", () => {
    const r = parseRankingExportParams({}, TODAY)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.value).toEqual({ start: "2026-08-06", end: "2026-09-04", orderBy: "units", groupVariants: true, branchId: null })
  })

  it("toma período, orden, agrupación y sucursal del body tal cual la pantalla los manda", () => {
    const r = parseRankingExportParams(
      { start: "2026-08-01", end: "2026-08-31", order_by: "revenue", group_variants: false, branch_id: BRANCH },
      TODAY,
    )
    expect(r).toEqual({ ok: true, value: { start: "2026-08-01", end: "2026-08-31", orderBy: "revenue", groupVariants: false, branchId: BRANCH } })
  })

  it("rechaza un orden fuera de dominio", () => {
    const r = parseRankingExportParams({ order_by: "margin_pct" }, TODAY)
    expect(r.ok).toBe(false)
    if (r.ok) return
    expect(r.error).toMatch(/order_by/)
  })

  it("rechaza fechas mal formadas, inexistentes y el rango invertido", () => {
    expect(parseRankingExportParams({ start: "01/08/2026" }, TODAY).ok).toBe(false)
    expect(parseRankingExportParams({ end: "2026-02-30" }, TODAY).ok).toBe(false)
    expect(parseRankingExportParams({ start: "2026-08-31", end: "2026-08-01" }, TODAY).ok).toBe(false)
  })

  it("rechaza una sucursal que no es uuid y un group_variants que no es booleano", () => {
    expect(parseRankingExportParams({ branch_id: "casa-central" }, TODAY).ok).toBe(false)
    expect(parseRankingExportParams({ group_variants: "false" }, TODAY).ok).toBe(false)
    // null explícito de sucursal = sin filtro.
    const r = parseRankingExportParams({ branch_id: null }, TODAY)
    expect(r.ok && r.value.branchId).toBe(null)
  })
})

// ─── 8.4: filas del CSV desde el read-model, 1:1 y en orden ──────────────────

describe("rankingRowToCsvRow / buildRankingCsv (8.4, D11)", () => {
  it("mapea cada columna del read-model a su celda; el margen ausente es celda vacía, nunca 0", () => {
    const withMargin = rankingRowToCsvRow(rpcRow(1, { is_group: true, variant_count: 2 }))
    expect(withMargin).toEqual({
      puesto: 1,
      producto: "Producto 1",
      sku: "SKU-1",
      categoria: "Ropa",
      producto_padre: "",
      variantes: 2,
      unidades: "5",
      importe: "2350",
      operaciones: 3,
      costo: "1500",
      margen: "850",
      margen_pct: "36,17",
      cobertura_costo_pct: "33,3",
      ultima_venta: "2026-08-31",
    })

    const noMargin = rankingRowToCsvRow(rpcRow(2, { total_cost: null, gross_margin: null, gross_margin_pct: null, cost_coverage_pct: "0" }))
    expect(noMargin.margen).toBe("")
    expect(noMargin.margen_pct).toBe("")
    expect(noMargin.costo).toBe("")
    expect(noMargin.margen).not.toBe(0)
  })

  it("una variante sin agrupar lleva su padre como contexto", () => {
    const row = rankingRowToCsvRow(rpcRow(3, { parent_id: "p", parent_name: "Remera" }))
    expect(row.producto_padre).toBe("Remera")
  })

  it("decimales de unidades/importe/costo/margen/margen_pct/cobertura usan coma (Excel es-AR toma el punto como texto)", () => {
    const row = rankingRowToCsvRow(rpcRow(4, {
      units: "12.5",
      revenue: "2350.75",
      total_cost: "1500.3",
      gross_margin: "850.45",
      gross_margin_pct: "36.17",
      cost_coverage_pct: "33.33",
    }))
    expect(row.unidades).toBe("12,5")
    expect(row.importe).toBe("2350,75")
    expect(row.costo).toBe("1500,3")
    expect(row.margen).toBe("850,45")
    expect(row.margen_pct).toBe("36,17")
    expect(row.cobertura_costo_pct).toBe("33,33")
  })

  it("un margen negativo (pérdida) también convierte con coma, sin romper el signo", () => {
    const row = rankingRowToCsvRow(rpcRow(5, { gross_margin: "-120.50", gross_margin_pct: "-5.1" }))
    expect(row.margen).toBe("-120,50")
    expect(row.margen_pct).toBe("-5,1")
  })

  it("puesto, variantes y operaciones son enteros: nunca llevan coma decimal", () => {
    const row = rankingRowToCsvRow(rpcRow(6, { operations: 7, variant_count: 3, is_group: true }))
    expect(row.puesto).toBe(6)
    expect(row.variantes).toBe(3)
    expect(row.operaciones).toBe(7)
  })

  it("el CSV tiene una fila por fila del ranking, en el mismo orden, con las cabeceras declaradas, separado por ;", () => {
    const csv = buildRankingCsv([rpcRow(1, { product_name: "Gorra" }), rpcRow(2, { product_name: "Remera, lisa" }), rpcRow(3, { product_name: "Bufanda" })])
    const lines = csv.split("\r\n")
    expect(lines[0]).toBe(RANKING_CSV_HEADERS.join(";"))
    expect(lines).toHaveLength(4)
    expect(lines[1].startsWith("1;Gorra;")).toBe(true)
    // La coma del nombre se escapa igual (defensivo); el separador real es ;
    // así que la coma NO parte la fila en columnas de más.
    expect(lines[2].startsWith('2;"Remera, lisa";')).toBe(true)
    expect(lines[2].split(";")).toHaveLength(RANKING_CSV_HEADERS.length)
    expect(lines[3].startsWith("3;Bufanda;")).toBe(true)
  })

  it("rowsToCsv separa por ;, escapa comillas y saltos de línea, y deja vacías las celdas nulas", () => {
    const csv = rowsToCsv(["a", "b"], [{ a: 'di "hola"', b: null }, { a: "x\ny", b: 1 }])
    expect(csv).toBe('a;b\r\n"di ""hola""";\r\n"x\ny";1')
  })

  it("un campo con ; embebido queda entrecomillado", () => {
    const csv = rowsToCsv(["a"], [{ a: "uno; dos" }])
    expect(csv).toBe('a\r\n"uno; dos"')
  })

  it("un campo con coma (ya no es el separador) también queda entrecomillado, sin romper columnas", () => {
    const csv = rowsToCsv(["ciudad", "cp"], [{ ciudad: "Godoy Cruz, Mendoza", cp: "5501" }])
    expect(csv).toBe('ciudad;cp\r\n"Godoy Cruz, Mendoza";5501')
    // Exactamente 2 columnas (un solo ; de dato): la coma no partió la fila.
    const dataLine = csv.split("\r\n")[1]
    expect(dataLine.split(";")).toHaveLength(2)
  })
})

// ─── 8.4: paginación de la RPC con los mismos parámetros que la pantalla ─────

function makeClient(pages: ProductRankingRpcRow[][], error: { message: string } | null = null) {
  const calls: Array<Record<string, unknown>> = []
  const rpc = vi.fn(async (_fn: "rpc_product_ranking", args: Record<string, unknown>) => {
    calls.push(args)
    if (error) return { data: null, error }
    const page = pages[calls.length - 1] ?? []
    return { data: page, error: null }
  })
  return { client: { rpc } as unknown as RankingRpcClient, calls }
}

describe("fetchAllRankingRows (8.4 — nunca re-agrega, pagina la RPC de a 500)", () => {
  const params = { start: "2026-08-01", end: "2026-08-31", orderBy: "revenue" as const, groupVariants: false, branchId: BRANCH }

  it("pasa a la RPC exactamente los parámetros de la pantalla (cuenta, período, orden, agrupación, sucursal) y pagina de a 500", async () => {
    const first = Array.from({ length: RANKING_PAGE_SIZE }, (_, i) => rpcRow(i + 1, { total_count: RANKING_PAGE_SIZE + 1 }))
    const second = [rpcRow(RANKING_PAGE_SIZE + 1, { total_count: RANKING_PAGE_SIZE + 1 })]
    const { client, calls } = makeClient([first, second])

    const rows = await fetchAllRankingRows(client, ACCOUNT, params)

    expect(rows).toHaveLength(RANKING_PAGE_SIZE + 1)
    expect(rows.map((r) => r.rank)).toEqual(Array.from({ length: RANKING_PAGE_SIZE + 1 }, (_, i) => i + 1))
    expect(calls).toHaveLength(2)
    expect(calls[0]).toEqual({
      p_account_id: ACCOUNT, p_start: "2026-08-01", p_end: "2026-08-31", p_order_by: "revenue",
      p_group_variants: false, p_branch_id: BRANCH, p_canal: null, p_limit: RANKING_PAGE_SIZE, p_offset: 0,
    })
    expect(calls[1].p_offset).toBe(RANKING_PAGE_SIZE)
  })

  it("una sola página corta (menos de 500) termina sin pedir otra", async () => {
    const { client, calls } = makeClient([[rpcRow(1, { total_count: 2 }), rpcRow(2, { total_count: 2 })]])
    const rows = await fetchAllRankingRows(client, ACCOUNT, params)
    expect(rows).toHaveLength(2)
    expect(calls).toHaveLength(1)
  })

  it("un ranking vacío devuelve cero filas sin error", async () => {
    const { client } = makeClient([[]])
    expect(await fetchAllRankingRows(client, ACCOUNT, params)).toEqual([])
  })

  it("un error de la RPC se propaga (nunca un CSV vacío que parezca 'sin ventas')", async () => {
    const { client } = makeClient([], { message: "P0401 unauthorized" })
    await expect(fetchAllRankingRows(client, ACCOUNT, params)).rejects.toThrow(/P0401/)
  })

  it("se detiene en el tope de filas aunque total_count diga que hay más", async () => {
    const pagesNeeded = RANKING_MAX_ROWS / RANKING_PAGE_SIZE
    const pages = Array.from({ length: pagesNeeded + 1 }, (_, p) =>
      Array.from({ length: RANKING_PAGE_SIZE }, (_, i) => rpcRow(p * RANKING_PAGE_SIZE + i + 1, { total_count: RANKING_MAX_ROWS + RANKING_PAGE_SIZE })),
    )
    const { client, calls } = makeClient(pages)
    const rows = await fetchAllRankingRows(client, ACCOUNT, params)
    expect(rows).toHaveLength(RANKING_MAX_ROWS)
    expect(calls).toHaveLength(pagesNeeded)
  })
})
