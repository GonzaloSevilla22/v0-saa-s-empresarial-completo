"use client"

/**
 * productos-padre-variantes (task 12.2) — pasada visual de /productos.
 *
 * Monta la PÁGINA REAL (`/productos`: catálogo, diálogo de alta, formularios, «Corregir unidad» y
 * «Modificar precios») sin sesión ni backend. `window.fetch` se intercepta (patrón de
 * EdicionDineroHarness / OcrCuotaHarness; en CI el backend real responde 401 y el transporte
 * navegaría al login, por eso el intercept es obligatorio):
 *
 *   GET  /products                      → catálogo sintético (decimales como STRING, como FastAPI)
 *   POST /products                      → crea la fila y la suma al catálogo (con id nuevo)
 *   POST /products/{id}/relabel-unit    → vista previa / aplicación del relabel (Nike: una línea
 *                                         grabada en «u» → elegir otra unidad da conflicto)
 *   PATCH /products/bulk-price          → cálculo REAL de la regla (redondeo a pesos, piso 0,
 *                                         padres omitidos) sobre el catálogo sintético
 *   GET  /product-categories            → Ropa / Almacén
 *   GET  /rest/v1/units_of_measure      → unidades de sistema (Supabase REST)
 *
 * `?theme=light|dark` escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { Suspense, useEffect, useState } from "react"
import ProductosPage from "@/app/(dashboard)/productos/page"

const U = {
  u: "00000000-0000-0000-0001-000000000001",
  kg: "00000000-0000-0000-0001-000000000002",
  L: "00000000-0000-0000-0001-000000000003",
  g: "00000000-0000-0000-0001-000000000012",
}

const UNIT_ROWS = [
  { id: U.u, name: "Unidad", symbol: "u", type: "unit", factor: "1", base_unit_id: null, is_system: true },
  { id: U.kg, name: "Kilogramo", symbol: "kg", type: "weight", factor: "1", base_unit_id: null, is_system: true },
  { id: U.g, name: "Gramo", symbol: "g", type: "weight", factor: "0.001", base_unit_id: U.kg, is_system: true },
  { id: U.L, name: "Litro", symbol: "L", type: "volume", factor: "1", base_unit_id: null, is_system: true },
]

const CATEGORY_ROWS = [
  { id: "cat-ropa", account_id: "a1", name: "Ropa", is_active: true, sort_order: 1, created_at: "2026-01-01T00:00:00Z" },
  { id: "cat-almacen", account_id: "a1", name: "Almacén", is_active: true, sort_order: 2, created_at: "2026-01-01T00:00:00Z" },
]

interface Row {
  id: string
  account_id: string
  name: string
  category: string
  category_id: string
  price: string
  cost: string | null
  stock: string
  min_stock: string
  barcode: string | null
  sku: string | null
  is_variant: boolean
  stock_control_type: "tracked" | "untracked" | "variant_only"
  created_at: string
  parent_id: string | null
  base_unit_id: string | null
  scale_plu: number | null
}

function row(id: string, name: string, over: Partial<Row> = {}): Row {
  return {
    id, account_id: "a1", name, category: "Ropa", category_id: "cat-ropa", price: "0", cost: null,
    stock: "0.0000", min_stock: "0.0000", barcode: null, sku: null, is_variant: false,
    stock_control_type: "tracked", created_at: "2026-10-01T00:00:00Z", parent_id: null, base_unit_id: null,
    scale_plu: null, ...over,
  }
}

function seed(): Row[] {
  return [
    // Padre con variantes: sin precio ni costo (CHECK); la unidad es de la familia.
    row("p-nike", "Zapatillas Nike", { stock_control_type: "variant_only", base_unit_id: U.u }),
    row("v-nike-41", "Zapatillas Nike 41", { is_variant: true, parent_id: "p-nike", price: "12000", cost: "6000", stock: "3.0000", min_stock: "1.0000", sku: "NIKE-41" }),
    row("v-nike-42", "Zapatillas Nike 42", { is_variant: true, parent_id: "p-nike", price: "15000", cost: "7000", stock: "5.0000", min_stock: "1.0000", sku: "NIKE-42" }),
    // Segundo padre con stock en una variante: la unidad ya no se elige libre, se corrige.
    row("p-harina", "Harina 000", { category: "Almacén", category_id: "cat-almacen", stock_control_type: "variant_only", base_unit_id: U.u }),
    row("v-harina-1", "Harina 000 x 1 kg", { category: "Almacén", category_id: "cat-almacen", is_variant: true, parent_id: "p-harina", price: "900", cost: "500", stock: "12.0000", min_stock: "2.0000" }),
    // Producto simple.
    row("p-aceite", "Aceite suelto", { category: "Almacén", category_id: "cat-almacen", price: "3500", cost: "2000", stock: "8.2500", min_stock: "1.0000", base_unit_id: U.L, sku: "ACE-01" }),
    // Padre armado a mano antes del change (tracked con variantes, sin convertir).
    row("p-remera", "Remera armada a mano", { price: "8000", cost: "3000", stock: "5.0000", min_stock: "2.0000", barcode: "7790009", base_unit_id: U.u }),
    row("v-remera-m", "Remera armada a mano M", { is_variant: true, parent_id: "p-remera", price: "8000", cost: "3000", stock: "1.0000" }),
    // Padre sin variantes todavía.
    row("p-campera", "Campera sin variantes", { stock_control_type: "variant_only", base_unit_id: U.u }),
  ]
}

const roundPesos = (n: number) => Math.sign(n) * Math.round(Math.abs(n))

function installFetchIntercept(rows: Row[]) {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase()
    const json = (body: unknown, status = 200) =>
      new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })

    if (url.includes("/rest/v1/units_of_measure")) return json(UNIT_ROWS)
    if (!(url.startsWith(backend) || url.startsWith("/api/"))) return original(input, init)

    const path = url.slice(url.startsWith(backend) ? backend.length : 0).split("?")[0]
    const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : {}

    if (path === "/products" && method === "GET") return json(rows)
    if (path === "/products" && method === "POST") {
      const created = row(`new-${rows.length}`, String(body.name), {
        category_id: String(body.category_id ?? ""),
        category: CATEGORY_ROWS.find((c) => c.id === body.category_id)?.name ?? "Ropa",
        stock_control_type: body.stock_control_type as Row["stock_control_type"],
        parent_id: (body.parent_id as string | null) ?? null,
        is_variant: Boolean(body.is_variant),
        base_unit_id: (body.base_unit_id as string | null) ?? null,
        price: String(body.price ?? 0),
      })
      rows.push(created)
      return json(created, 201)
    }

    const relabel = path.match(/^\/products\/([^/]+)\/relabel-unit$/)
    if (relabel && method === "POST") {
      const rootId = relabel[1]
      const unit = String(body.base_unit_id)
      const variants = rows.filter((r) => r.parent_id === rootId).length
      const withStock = rows.filter((r) => r.parent_id === rootId && Number(r.stock) !== 0).length
      const base = {
        root_id: rootId, unit_before: U.u, unit_after: unit, variants, variants_with_own_unit: 0,
        products_with_stock: withStock, movements: rootId === "p-nike" ? 14 : 31, conflict_unit: null as string | null,
      }
      // Nike tiene una venta grabada en «Unidad»: cualquier otra unidad es conflicto.
      if (rootId === "p-nike" && unit !== U.u) return json({ ...base, changed: false, conflict_unit: U.u })
      return json({ ...base, changed: unit !== U.u })
    }

    if (path === "/products/bulk-price" && method === "PATCH") {
      const ids = new Set<string>((body.product_ids as string[]) ?? [])
      const sign = body.direction === "decrease" ? -1 : 1
      const value = Number(body.value)
      const family = rows.filter((r) => ids.has(r.id) || (r.parent_id && ids.has(r.parent_id)))
      const parents = family.filter((r) => r.stock_control_type === "variant_only")
      const eligible = family.filter((r) => r.stock_control_type !== "variant_only")
      let clamped = 0
      const sample = eligible.map((r) => {
        const before = Number(r.price)
        const raw = body.mode === "percent" ? before * (1 + (sign * value) / 100) : before + sign * value
        const after = Math.max(0, roundPesos(raw))
        if (after === 0 && raw < 0) clamped += 1
        return { id: r.id, name: r.name, price_before: String(before), price_after: String(after) }
      })
      const changedRows = sample.filter((s) => s.price_before !== s.price_after)
      return json({
        requested: ids.size, eligible: eligible.length, changed: changedRows.length,
        unchanged: sample.length - changedRows.length, skipped_parents: parents.length, clamped,
        sample: changedRows.slice(0, 10),
      })
    }

    if (path === "/product-categories") return json(CATEGORY_ROWS)
    if (path === "/sales" || path === "/purchases") return json({ items: [], total: 0, page: 0, pages: 0 })
    return json([])
  }
  return () => { window.fetch = original }
}

export function ProductosPadreHarness() {
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept(seed())
    const theme = new URLSearchParams(window.location.search).get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
    setReady(true)
    return uninstall
  }, [])

  // Sin el intercept ya instalado, el catálogo real consultaría el backend: se monta recién después.
  if (!ready) return null
  return (
    <div data-testid="harness-productos" className="min-h-screen bg-background p-4 sm:p-6">
      <Suspense fallback={null}>
        <ProductosPage />
      </Suspense>
    </div>
  )
}
