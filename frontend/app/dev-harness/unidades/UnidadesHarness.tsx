"use client"

/**
 * ventas-unidades-conversion — pasada visual (task 6.4).
 *
 * `?view=stock` monta las columnas REALES de /stock (`buildColumns`, con la
 * misma `DataTable` y el mismo `mobileCard` que la página) y filas REALES del
 * historial (`MovementRow`) sobre productos en kilos y por unidades: la
 * cantidad tiene que salir como "0.550 kg" / "12 uds", nunca "uds" fijo.
 *
 * `?view=form` monta el formulario de venta REAL (`SaleForm`), `?view=pos` el
 * mostrador REAL (`/ventas/pos`, la página entera) y `?view=purchase` el
 * formulario de compra REAL (`PurchaseForm`), todos con un catálogo sintético
 * servido por intercept de `window.fetch`: `/products` (backend) y
 * `/rest/v1/units_of_measure` (Supabase REST, que `useUnitsOfMeasure` consulta
 * con supabase-js). Así el selector de unidad de los tres se deriva de
 * `compatibleUnits` con datos reales de la unidad base del producto, sin
 * sesión ni backend. Sin sesión, el POS muestra el aviso de "sin permiso de
 * escritura" y el botón "Agregar al carrito" deshabilitado: es lo esperado,
 * la pasada visual es del selector de unidad y de la cantidad.
 *
 * Las filas de `/products` llevan `stock` y `min_stock` como STRING decimal
 * ("0.5000"), igual que las serializa FastAPI (Decimal → str): con números el
 * arnés escondía el crash de /stock que corrigió el PR #584.
 *
 * El toggle de tema escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { useEffect, useMemo, useState } from "react"

import { buildColumns, buildMobileCard } from "@/app/(dashboard)/stock/page"
import { DataTable } from "@/components/data-table/data-table"
import { MovementRow } from "@/components/stock/stock-movements-panel"
import { SaleForm } from "@/components/forms/sale-form"
import { PurchaseForm } from "@/components/forms/purchase-form"
import PosPage from "@/app/(dashboard)/ventas/pos/page"
import type { Product, StockMovement } from "@/lib/types"

const U = {
  kg: "00000000-0000-0000-0001-000000000002",
  g:  "00000000-0000-0000-0001-000000000012",
  tn: "00000000-0000-0000-0001-000000000013",
  L:  "00000000-0000-0000-0001-000000000003",
  mL: "00000000-0000-0000-0001-000000000014",
  m:  "00000000-0000-0000-0001-000000000004",
  cm: "00000000-0000-0000-0001-000000000015",
  u:  "00000000-0000-0000-0001-000000000001",
  doc:"00000000-0000-0000-0001-000000000016",
  cj6:"00000000-0000-0000-0001-000000000017",
}

/** Las 10 unidades de sistema tal como las devuelve PostgREST (snake_case). */
const UNIT_ROWS = [
  { id: U.cm, name: "Centímetro", symbol: "cm",  type: "length", factor: "0.01",  base_unit_id: U.m,  is_system: true },
  { id: U.m,  name: "Metro",      symbol: "m",   type: "length", factor: "1",     base_unit_id: null, is_system: true },
  { id: U.u,  name: "Unidad",     symbol: "u",   type: "unit",   factor: "1",     base_unit_id: null, is_system: true },
  { id: U.cj6,name: "Caja x 6",   symbol: "cj6", type: "unit",   factor: "6",     base_unit_id: U.u,  is_system: true },
  { id: U.doc,name: "Docena",     symbol: "doc", type: "unit",   factor: "12",    base_unit_id: U.u,  is_system: true },
  { id: U.mL, name: "Mililitro",  symbol: "mL",  type: "volume", factor: "0.001", base_unit_id: U.L,  is_system: true },
  { id: U.L,  name: "Litro",      symbol: "L",   type: "volume", factor: "1",     base_unit_id: null, is_system: true },
  { id: U.g,  name: "Gramo",      symbol: "g",   type: "weight", factor: "0.001", base_unit_id: U.kg, is_system: true },
  { id: U.kg, name: "Kilogramo",  symbol: "kg",  type: "weight", factor: "1",     base_unit_id: null, is_system: true },
  { id: U.tn, name: "Tonelada",   symbol: "tn",  type: "weight", factor: "1000",  base_unit_id: U.kg, is_system: true },
]

const SYMBOL_BY_ID = new Map(UNIT_ROWS.map((u) => [u.id, u.symbol]))

/** Catálogo sintético tal como lo devuelve GET /products (fila de la vista). */
const PRODUCT_ROWS = [
  { id: "p-tomate",  user_id: "u1", account_id: "a1", name: "Tomate redondo", category: "Verdulería", price: "1800", cost: "900",  stock: "0.5500", min_stock: "0.5000", barcode: null, sku: "TOM-01", is_variant: false, stock_control_type: "tracked", created_at: "2026-09-24T00:00:00Z", base_unit_id: U.kg },
  { id: "p-zapallo", user_id: "u1", account_id: "a1", name: "Zapallo anco",   category: "Verdulería", price: "1200", cost: "500",  stock: "12.3750", min_stock: "2.0000", barcode: null, sku: "ZAP-01", is_variant: false, stock_control_type: "tracked", created_at: "2026-09-24T00:00:00Z", base_unit_id: U.kg },
  { id: "p-aceite",  user_id: "u1", account_id: "a1", name: "Aceite suelto",  category: "Almacén",    price: "3500", cost: "2000", stock: "8.2500", min_stock: "1.0000", barcode: null, sku: "ACE-01", is_variant: false, stock_control_type: "tracked", created_at: "2026-09-24T00:00:00Z", base_unit_id: U.L },
  { id: "p-huevo",   user_id: "u1", account_id: "a1", name: "Huevo (unidad)", category: "Almacén",    price: "250",  cost: "150",  stock: "12.0000", min_stock: "30.0000", barcode: null, sku: "HUE-01", is_variant: false, stock_control_type: "tracked", created_at: "2026-09-24T00:00:00Z", base_unit_id: null },
]

const PRODUCTS: Product[] = PRODUCT_ROWS.map((p) => ({
  id: p.id,
  name: p.name,
  category: p.category,
  categoryId: null,
  cost: Number(p.cost),
  price: Number(p.price),
  margin: 50,
  stock: Number(p.stock),
  minStock: Number(p.min_stock),
  sku: p.sku,
  isVariant: false,
  stockControlType: "tracked",
  baseUnitId: p.base_unit_id ?? undefined,
}))

const MOVEMENTS: StockMovement[] = [
  { id: "m1", userId: "u1", productId: "p-tomate",  productName: "Tomate redondo", type: "sale",        quantityDelta: -0.45, quantityBefore: 1,      quantityAfter: 0.55,   reason: "Venta 450 g",             createdAt: "2026-09-24T14:05:00Z" },
  { id: "m2", userId: "u1", productId: "p-zapallo", productName: "Zapallo anco",   type: "purchase",    quantityDelta: 2,     quantityBefore: 10.375, quantityAfter: 12.375, reason: "Compra 2000 g",           createdAt: "2026-09-24T11:20:00Z" },
  { id: "m3", userId: "u1", productId: "p-tomate",  productName: "Tomate redondo", type: "sale_return", quantityDelta: 0.45,  quantityBefore: 0.55,   quantityAfter: 1,      reason: "Reversa por edición",     createdAt: "2026-09-23T18:40:00Z" },
  { id: "m4", userId: "u1", productId: "p-huevo",   productName: "Huevo (unidad)", type: "sale",        quantityDelta: -6,    quantityBefore: 18,     quantityAfter: 12,     reason: "Venta media docena",      createdAt: "2026-09-23T10:00:00Z" },
]

function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    const json = (body: unknown) =>
      new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } })
    if (url.includes("/rest/v1/units_of_measure")) return json(UNIT_ROWS)
    if (url.startsWith(backend) || url.startsWith("/api/")) {
      if (url.includes("/products")) return json(PRODUCT_ROWS)
      if (url.includes("/sales")) return json({ items: [], total: 0, page: 0, pages: 0 })
      if (url.includes("/purchases")) return json({ items: [], total: 0, page: 0, pages: 0 })
      return json([])
    }
    return original(input, init)
  }
  return () => { window.fetch = original }
}

function StockView() {
  const unitSymbolFor = useMemo(() => (row: Product) => (row.baseUnitId ? SYMBOL_BY_ID.get(row.baseUnitId) : undefined), [])
  const columns = useMemo(() => buildColumns(false, unitSymbolFor), [unitSymbolFor])
  const symbolByProduct = useMemo(() => new Map(PRODUCTS.map((p) => [p.id, unitSymbolFor(p)])), [unitSymbolFor])
  return (
    <div className="flex flex-col gap-6" data-testid="harness-stock">
      <DataTable
        data={PRODUCTS}
        columns={columns}
        searchPlaceholder="Buscar productos..."
        searchKey={(row) => `${row.name} ${row.category}`}
        getId={(row) => row.id}
        mobileCard={buildMobileCard(unitSymbolFor)}
      />
      <section className="rounded-lg border border-border bg-card p-3" data-testid="harness-movements">
        <h2 className="mb-2 text-sm font-semibold text-foreground">Historial de movimientos</h2>
        {MOVEMENTS.map((m) => (
          <MovementRow key={m.id} m={m} unitSymbol={symbolByProduct.get(m.productId)} />
        ))}
      </section>
    </div>
  )
}

type HarnessView = "stock" | "form" | "pos" | "purchase"

const VIEW_TITLES: Record<HarnessView, string> = {
  stock: "stock e historial",
  form: "formulario de venta",
  pos: "mostrador (POS)",
  purchase: "formulario de compra",
}

function parseView(raw: string | null): HarnessView {
  return raw === "form" || raw === "pos" || raw === "purchase" ? raw : "stock"
}

export function UnidadesHarness() {
  const [view, setView] = useState<HarnessView>("stock")
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
    const params = new URLSearchParams(window.location.search)
    const theme = params.get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
    setView(parseView(params.get("view")))
    setReady(true)
    return uninstall
  }, [])

  if (!ready) return null

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground" data-testid="harness-title">
        Arnés — Unidades de medida ({VIEW_TITLES[view]})
      </h1>
      {view === "stock" && <StockView />}
      {view === "form" && (
        <div data-testid="harness-form" className="max-w-3xl">
          <SaleForm onSuccess={() => {}} />
        </div>
      )}
      {view === "pos" && (
        <div data-testid="harness-pos">
          <PosPage />
        </div>
      )}
      {view === "purchase" && (
        <div data-testid="harness-purchase" className="max-w-3xl">
          <PurchaseForm onSuccess={() => {}} />
        </div>
      )}
    </main>
  )
}
