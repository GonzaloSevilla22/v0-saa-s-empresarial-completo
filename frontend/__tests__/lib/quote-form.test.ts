/**
 * presupuestos-modulo (D12, tarea 5.3/5.4) — helpers puros del formulario de
 * presupuesto, en la capa canónica (`lib/quote-form.ts`):
 *
 *  - `rehydrateQuoteLines`: edición y duplicado. La edición vuelve a cargar el
 *    precio EFECTIVO persistido con descuento 0 (como `sale-form`); el duplicado
 *    toma el precio de HOY del catálogo, reexpresado a la unidad de la línea,
 *    y avisa las líneas cuyo precio cambió. Una línea cuyo producto ya no está
 *    vivo se marca (no se descarta) para bloquear el guardado.
 *  - `defaultQuoteValidUntil` y `validateQuoteDraft`.
 */
import { describe, it, expect } from "vitest"
import {
  defaultQuoteValidUntil,
  rehydrateQuoteLines,
  validateQuoteDraft,
  QUOTE_NOTES_MAX,
} from "@/lib/quote-form"
import type { QuoteItemApiRow } from "@/lib/quote-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const G: UnitOfMeasure = { id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS_BY_ID = new Map([KG, G, UN].map((u) => [u.id, u]))

function product(overrides: Partial<Product> & { id: string; name: string; price: number }): Product {
  return {
    category: "Otros",
    cost: null,
    margin: null,
    stock: 10,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    baseUnitId: "u-un",
    ...overrides,
  }
}

const REMERA = product({ id: "p-remera", name: "Remera", price: 1500 })
const PAPA = product({ id: "p-papa", name: "Papa", price: 1800, baseUnitId: "u-kg", stock: 5 })
const CTX = { unitsById: UNITS_BY_ID, products: [REMERA, PAPA] }

function row(overrides: Partial<QuoteItemApiRow> & { id: string }): QuoteItemApiRow {
  return {
    quote_id: "q-1",
    product_id: "p-remera",
    unit_id: "u-un",
    quantity: "2.0000",
    price: "1000",
    subtotal: "2000",
    name_snapshot: "Remera",
    sku_snapshot: null,
    line_no: 1,
    ...overrides,
  }
}

describe("rehydrateQuoteLines — edición", () => {
  it("vuelve a cargar el precio efectivo persistido con descuento 0 y el subtotal por precio × cantidad", () => {
    const out = rehydrateQuoteLines([row({ id: "i1", price: "900", quantity: "3", subtotal: "2700" })], CTX, "edit")

    expect(out.cartItems).toHaveLength(1)
    expect(out.cartItems[0]).toMatchObject({
      productId: "p-remera",
      unitPrice: 900, // el persistido, NO el de hoy del catálogo (1500)
      quantity: 3,
      discount: 0,
      subtotal: 2700,
      unitId: "u-un",
      unitSymbol: "u",
    })
    expect(out.cartItems[0].source).toBeUndefined() // se fusiona y cuenta contra el stock como una alta nueva
    expect(out.unavailableIds).toEqual([])
    expect(out.priceChanges).toEqual([]) // en edición no se compara con el catálogo
  })

  it("una línea de servicio vuelve como concepto con su descripción", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i2", product_id: null, unit_id: null, name_snapshot: "Flete a domicilio", quantity: "1", price: "3500", subtotal: "3500" })],
      CTX,
      "edit",
    )

    expect(out.cartItems).toEqual([])
    expect(out.serviceLines).toHaveLength(1)
    expect(out.serviceLines[0]).toMatchObject({ description: "Flete a domicilio", quantity: 1, unitPrice: 3500, subtotal: 3500 })
  })

  it("respeta el orden de carga (line_no) intercalando productos y servicios", () => {
    const out = rehydrateQuoteLines(
      [
        row({ id: "i-b", product_id: null, unit_id: null, name_snapshot: "Flete", line_no: 2, price: "100", subtotal: "100", quantity: "1" }),
        row({ id: "i-a", line_no: 1 }),
        row({ id: "i-c", product_id: "p-papa", unit_id: "u-kg", line_no: 3, quantity: "1.5", price: "1800", subtotal: "2700" }),
      ],
      CTX,
      "edit",
    )

    const byOrder = out.loadOrder.map(
      (id) =>
        out.cartItems.find((c) => c.id === id)?.productName ?? out.serviceLines.find((s) => s.id === id)?.description,
    )
    expect(byOrder[0]).toMatch(/remera/i)
    expect(byOrder[1]).toBe("Flete")
    expect(byOrder[2]).toMatch(/papa/i)
  })

  it("un producto que ya no está en el catálogo vivo queda marcado como no disponible (no se descarta)", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i3", product_id: "p-baja", name_snapshot: "Buzo viejo", price: "2000", subtotal: "2000", quantity: "1" })],
      CTX,
      "edit",
    )

    expect(out.cartItems).toHaveLength(1)
    expect(out.cartItems[0].productName).toBe("Buzo viejo")
    expect(out.unavailableIds).toEqual([out.cartItems[0].id])
  })

  it("los pasos de la línea salen de su unidad (un medible baja de 1 sin subirse a 1)", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i4", product_id: "p-papa", unit_id: "u-g", quantity: "450", price: "1.8", subtotal: "810" })],
      CTX,
      "edit",
    )

    expect(out.cartItems[0]).toMatchObject({ unitId: "u-g", step: 0.001, minQty: 0.001, quantityBase: 0.45 })
  })
})

describe("rehydrateQuoteLines — duplicado", () => {
  it("toma el precio de HOY del catálogo (sin descuento) y avisa las líneas que cambiaron", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i1", price: "1000", quantity: "2", subtotal: "2000" })],
      CTX,
      "duplicate",
    )

    expect(out.cartItems[0]).toMatchObject({ unitPrice: 1500, discount: 0, subtotal: 3000 })
    expect(out.priceChanges).toEqual([{ name: "Remera", previous: 1000, current: 1500 }])
  })

  it("una línea cuyo precio no cambió no genera aviso", () => {
    const out = rehydrateQuoteLines([row({ id: "i1", price: "1500", quantity: "1", subtotal: "1500" })], CTX, "duplicate")

    expect(out.cartItems[0].unitPrice).toBe(1500)
    expect(out.priceChanges).toEqual([])
  })

  it("reexpresa el precio de catálogo a la unidad de la línea (gramos a partir de $/kg)", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i5", product_id: "p-papa", name_snapshot: "Papa", unit_id: "u-g", quantity: "500", price: "1.5", subtotal: "750" })],
      CTX,
      "duplicate",
    )

    expect(out.cartItems[0].unitPrice).toBeCloseTo(1.8, 10) // $1.800/kg = $1,8/g
    expect(out.cartItems[0].subtotal).toBeCloseTo(900, 4)
    expect(out.priceChanges[0]).toMatchObject({ name: "Papa", previous: 1.5 })
  })

  it("las líneas de servicio conservan su precio y nunca figuran como cambiadas", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i2", product_id: null, unit_id: null, name_snapshot: "Instalación", quantity: "1", price: "5000", subtotal: "5000" })],
      CTX,
      "duplicate",
    )

    expect(out.serviceLines[0].unitPrice).toBe(5000)
    expect(out.priceChanges).toEqual([])
  })

  it("un producto dado de baja se marca no disponible y conserva el precio cotizado", () => {
    const out = rehydrateQuoteLines(
      [row({ id: "i3", product_id: "p-baja", name_snapshot: "Buzo viejo", price: "2000", subtotal: "2000", quantity: "1" })],
      CTX,
      "duplicate",
    )

    expect(out.unavailableIds).toEqual([out.cartItems[0].id])
    expect(out.cartItems[0].unitPrice).toBe(2000)
    expect(out.priceChanges).toEqual([])
  })
})

describe("defaultQuoteValidUntil", () => {
  it("es hoy más los días de validez de la cuenta", () => {
    expect(defaultQuoteValidUntil("2026-10-01", 15)).toBe("2026-10-16")
  })

  it("cruza fin de mes y de año", () => {
    expect(defaultQuoteValidUntil("2026-12-20", 15)).toBe("2027-01-04")
    expect(defaultQuoteValidUntil("2026-01-31", 1)).toBe("2026-02-01")
  })
})

describe("validateQuoteDraft", () => {
  const ok = {
    clientId: "c-1",
    itemCount: 1,
    validUntil: "2026-10-16",
    today: "2026-10-01",
    notes: "",
    unavailableCount: 0,
  }

  it("un presupuesto completo no tiene error", () => {
    expect(validateQuoteDraft(ok)).toBeNull()
  })

  it("el cliente es obligatorio", () => {
    expect(validateQuoteDraft({ ...ok, clientId: "" })).toMatch(/cliente/i)
  })

  it("necesita al menos una línea (de producto o de servicio)", () => {
    expect(validateQuoteDraft({ ...ok, itemCount: 0 })).toMatch(/al menos/i)
  })

  it("la validez no puede estar vacía ni ser anterior a hoy", () => {
    expect(validateQuoteDraft({ ...ok, validUntil: "" })).toMatch(/validez/i)
    expect(validateQuoteDraft({ ...ok, validUntil: "2026-09-30" })).toMatch(/hoy/i)
    expect(validateQuoteDraft({ ...ok, validUntil: "2026-10-01" })).toBeNull() // hoy sirve
  })

  it("un producto no disponible bloquea el guardado con el motivo accionable", () => {
    expect(validateQuoteDraft({ ...ok, unavailableCount: 1 })).toMatch(/no disponible/i)
    expect(validateQuoteDraft({ ...ok, unavailableCount: 1 })).toMatch(/quitalo/i)
  })

  it("las notas tienen tope", () => {
    expect(validateQuoteDraft({ ...ok, notes: "x".repeat(QUOTE_NOTES_MAX) })).toBeNull()
    expect(validateQuoteDraft({ ...ok, notes: "x".repeat(QUOTE_NOTES_MAX + 1) })).toMatch(/notas/i)
  })
})
