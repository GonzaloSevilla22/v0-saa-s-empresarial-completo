/**
 * C-21 v20-inventory-unification — Group 6 tests for importer branch_stock,
 * REESCRITO por importador-productos-fastapi (task 8.9).
 *
 * El INVARIANTE que este archivo assertea NO CAMBIA desde C-21: "el stock
 * del CSV llega a `branch_stock`". Lo que cambia es DÓNDE se puede observar
 * ese invariante desde el frontend, porque el transporte cambió de raíz:
 *
 *   ANTES (C-21):  parseImportFile → resolveHierarchy → UNA función
 *                  (`importProductsFromFile`) armaba el payload Y llamaba
 *                  `supabase.rpc("rpc_bulk_upsert_products", {p_rows, ...})`
 *                  en el MISMO módulo — el mock era `supabase.rpc`.
 *
 *   AHORA (importador-productos-fastapi): la responsabilidad se partió en
 *   dos módulos, cada uno con su propia frontera observable:
 *
 *     1. `prepareProductImport` (lib/import/importer.ts) — parsea, valida y
 *        resuelve jerarquía, SIN llamar a ningún transporte. Produce
 *        `apiRows`, la forma que el servidor espera.
 *     2. `useImportProducts()` (hooks/data/use-products.ts) — el hook de
 *        TanStack Query cuyo `mutationFn` llama `pythonClient.post(
 *        "/products/import", ...)`. Es el ÚNICO lugar que sabe de HTTP.
 *
 *   El mock deja de ser `supabase.rpc` y pasa a ser `pythonClient` (task
 *   8.9) — pero como el stock ahora se observa en DOS fronteras distintas
 *   (la salida de `prepareProductImport` y el body que `useImportProducts`
 *   arma para `pythonClient.post`), este archivo cubre las DOS, para que el
 *   invariante siga demostrado de punta a punta y no sólo a mitad de camino.
 *
 * Aserciones que CAMBIAN y por qué:
 *   - Ya no se assertea `mockRpc.mock.calls[0][0] === "rpc_bulk_upsert_products"`
 *     ni `payload.p_user_id`: el user_id/account_id YA NO viaja desde el
 *     cliente (D1 del design) — el servidor lo deriva del JWT.
 *   - "6.3 — re-importing" (upsert por SKU en dos llamadas separadas) se
 *     retira: con el todo-o-nada de este change, "reimportar" ya no es un
 *     segundo lote arbitrario sino un REPLAY por idempotencia — un
 *     escenario distinto, cubierto por los tests de servidor (gate SQL,
 *     bloque 11) y no por este archivo, cuyo alcance es sólo el transporte
 *     del stock.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

// ── HTTP client mock (task 8.9: reemplaza a supabase.rpc) ──────────────────
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn(),
  },
}))
import { pythonClient } from "@/lib/api/python-client"

// ── File parser mock ─────────────────────────────────────────────────────────
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn().mockResolvedValue({
    ok: true,
    rows: [
      {
        lineNumber: 2,
        tipo:       "Producto",
        nombre:     "Yerba Mate",
        precio:     "850",
        costo:      "400",
        stock:      "25",
        stock_minimo: "5",
        sku:        "YM-001",
        sku_padre:  "",
        producto_padre: "",
        categoria:  "Alimentos",
        codigo:     "",
        attributes: {},
      },
    ],
  }),
}))

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

beforeEach(() => {
  vi.clearAllMocks()
})

// ══════════════════════════════════════════════════════════════════════════
// Frontera 1 — prepareProductImport: el CSV produce apiRows con el stock
// correcto, SIN llamar a ningún transporte.
// ══════════════════════════════════════════════════════════════════════════

describe("prepareProductImport — stock reaches apiRows", () => {
  it("6.1 — a Producto row carries its CSV stock value (25) into apiRows", async () => {
    const { prepareProductImport } = await import("@/lib/import/importer")

    const mockFile = new File(["fake-csv"], "products.csv", { type: "text/csv" })
    const prepared = await prepareProductImport(mockFile)

    expect(prepared.apiRows).toHaveLength(1)
    expect(prepared.apiRows[0].stock).toBe(25)
    expect(prepared.apiRows[0].name).toBe("Yerba Mate")
    // El punto entero del change: NADA de tenencia sale de este módulo — no
    // hay user_id ni account_id en la fila que viaja al servidor.
    expect(prepared.apiRows[0]).not.toHaveProperty("user_id")
    expect(prepared.apiRows[0]).not.toHaveProperty("account_id")
  })

  it("6.2 — a Padre row always carries stock=0 (parent products have no direct stock)", async () => {
    const { parseImportFile } = await import("@/lib/import/parser")
    vi.mocked(parseImportFile).mockResolvedValueOnce({
      ok: true,
      rows: [
        {
          lineNumber: 2,
          tipo:       "Padre",
          nombre:     "Yerba Mate Padre",
          precio:     "0",
          costo:      "0",
          stock:      "10", // ignored for Padre rows
          stock_minimo: "0",
          sku:        "YM-PAD",
          sku_padre:  "",
          producto_padre: "",
          categoria:  "Alimentos",
          codigo:     "",
          attributes: {},
        },
      ],
    })

    const { prepareProductImport } = await import("@/lib/import/importer")
    const mockFile = new File(["fake-csv"], "products.csv", { type: "text/csv" })
    const prepared = await prepareProductImport(mockFile)

    expect(prepared.apiRows[0].stock).toBe(0)
  })
})

// ══════════════════════════════════════════════════════════════════════════
// Frontera 2 — useImportProducts(): el stock numérico de apiRows llega al
// BODY que se manda por `pythonClient.post`, preservado como string (D12,
// contrato null-preserving/precisión exacta — mismo criterio que el resto
// del transporte de importes de este repo).
// ══════════════════════════════════════════════════════════════════════════

describe("useImportProducts — stock reaches the HTTP transport", () => {
  it("forwards apiRows[].stock into the POST /products/import body", async () => {
    const { useImportProducts } = await import("@/hooks/data/use-products")

    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      committed: true,
      import_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      inserted: 1,
      updated: 0,
      errors: [],
      new_categories: [],
      // importador-gate-plan (OQ-1, sign-off PO 2026-09-11): siempre presente.
      plan: { plan: "gratis", limit: 100, before: 0, after: 1, added: 1, exceeded: false },
      replayed: false,
      dry_run: false,
    })

    const { result } = renderHook(() => useImportProducts(), { wrapper: makeWrapper() })

    await act(async () => {
      await result.current.importMutation.mutateAsync({
        fileName: "products.csv",
        fileHash: "hash-1",
        dryRun: false,
        idempotencyKey: "key-1",
        rows: [{ rowNo: 1, name: "Yerba Mate", stock: 25, attributes: [] }],
      })
    })

    expect(pythonClient.post).toHaveBeenCalledOnce()
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    const typedBody = body as { rows: Array<{ stock: unknown }> }
    expect(path).toBe("/products/import")
    expect(typedBody.rows[0].stock).toBe("25")
    expect(headers).toEqual({ "Idempotency-Key": "key-1" })
  })
})
