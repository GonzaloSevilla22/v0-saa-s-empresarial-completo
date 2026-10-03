/**
 * remitos-compra (D11, tarea 4.5) — traducciones accionables de los literales del
 * remito de COMPRA en el MISMO mapa que ya usan venta, compra, presupuesto y el
 * remito de venta (`humanizeOperationError`). Un caso por literal: el texto crudo
 * de la RPC nunca llega al usuario y cada mensaje nombra la salida.
 *
 * Los literales salen de `supabase/migrations/20261071000001_remitos_compra.sql`
 * (los de la tanda A) y del diseño D8/D9 (los de la conversión, tanda B). El
 * sentido llega por `context.direction`: sin él, todo caller existente sigue
 * exactamente igual (los casos de `operation-errors-delivery-notes.test.ts`).
 * Los literales del borrado de la compra y del puente (`delivery_note_purchase_
 * delete_forbidden`, `delivery_note_source_protected`) se suman en la tarea 7.7.
 */
import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

const PURCHASE = { documentLabel: "remito", direction: "purchase" } as const
const SALE = { documentLabel: "remito", direction: "sale" } as const
const PID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"

describe("remito de compra — proveedor", () => {
  it("delivery_note_supplier_required: elegir el proveedor que entrega la mercadería", () => {
    const { message } = humanizeOperationError(
      "delivery_note_supplier_required: el remito de compra necesita un proveedor",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/elegí el proveedor/i)
    expect(message).not.toMatch(/delivery_note_supplier_required/)
  })

  it("delivery_note_supplier_unavailable: proveedor dado de baja, elegir uno vigente en el remito", () => {
    const { message } = humanizeOperationError(
      "delivery_note_supplier_unavailable: el proveedor del remito fue dado de baja",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/proveedor/i)
    expect(message).toMatch(/dado de baja/i)
    expect(message).toMatch(/editá el remito y elegí un proveedor vigente/i)
  })

  it("supplier_not_found en un remito: 'Proveedor dado de baja — elegí uno vigente'", () => {
    const { message } = humanizeOperationError(`supplier_not_found: ${PID}`, undefined, null, PURCHASE)
    expect(message).toBe("Proveedor dado de baja — elegí uno vigente")
  })

  it("supplier_not_found fuera de un remito sigue con su texto de siempre (compra directa)", () => {
    const { message } = humanizeOperationError(`supplier_not_found: ${PID}`)
    expect(message).toMatch(/proveedor seleccionado no existe o no pertenece a esta cuenta/i)
    expect(message).not.toMatch(/dado de baja — elegí/i)
  })

  it("delivery_note_supplier_reference_too_long: el tope del número del proveedor", () => {
    const { message } = humanizeOperationError(
      "delivery_note_supplier_reference_too_long: el número del remito del proveedor admite hasta 100 caracteres",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/100 caracteres/)
    expect(message).toMatch(/número del remito del proveedor/i)
    expect(message).not.toMatch(/delivery_note_supplier_reference_too_long/)
  })
})

describe("remito de compra — faltante de mercadería al restar (delivery_note_stock_consumed)", () => {
  const RAW = "delivery_note_stock_consumed: de Producto A en la sucursal quedan 3, el remito necesita restar 5"

  it("nombra el producto, lo que queda y lo que hay que restar, y dice qué hacer", () => {
    const { message } = humanizeOperationError(RAW, undefined, null, PURCHASE)
    expect(message).toContain("Producto A")
    expect(message).toMatch(/quedan 3\b/)
    expect(message).toMatch(/restar 5\b/)
    expect(message).toMatch(/editá el remito/i)
    expect(message).toMatch(/ajustá el stock/i)
    expect(message).not.toMatch(/delivery_note_stock_consumed/)
  })

  it("no atribuye origen a la diferencia: el stock de la sucursal mezcla otras entradas", () => {
    const { message } = humanizeOperationError(RAW, undefined, null, PURCHASE)
    expect(message).not.toMatch(/vendi|salieron|consumi|ya salió/i)
  })

  it("trae la acción de ajustar el stock hacia /stock", () => {
    const { action } = humanizeOperationError(RAW, undefined, null, PURCHASE)
    expect(action).toEqual({ label: "Ajustar stock", href: "/stock" })
  })

  it("cantidades fraccionarias en formato es-AR (0,45 y no 0.45)", () => {
    const { message } = humanizeOperationError(
      "delivery_note_stock_consumed: de Harina en la sucursal quedan 0.45, el remito necesita restar 1.5",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/quedan 0,45\b/)
    expect(message).toMatch(/restar 1,5\b/)
  })

  it("si el servidor mandó el uuid en vez del nombre, resuelve el nombre o dice 'uno de los productos'", () => {
    const raw = `delivery_note_stock_consumed: de ${PID} en la sucursal quedan 0, el remito necesita restar 2`
    const resolved = humanizeOperationError(raw, (id) => (id === PID ? "Yerba 1 kg" : undefined), null, PURCHASE)
    expect(resolved.message).toContain("Yerba 1 kg")
    expect(resolved.message).not.toContain(PID)

    const unresolved = humanizeOperationError(raw, undefined, null, PURCHASE)
    expect(unresolved.message).toMatch(/uno de los productos/i)
    expect(unresolved.message).not.toContain(PID)
  })
})

describe("remito de compra — conversión en compra (tanda B)", () => {
  it("delivery_note_price_required: cargar el precio de todas las líneas antes de convertir", () => {
    const { message } = humanizeOperationError(
      "delivery_note_price_required: cargá el precio de compra de todas las líneas antes de convertir el remito",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/precio de compra de todas las líneas/i)
    expect(message).toMatch(/editá el remito/i)
  })

  it("delivery_note_purchase_date_before_receipt: la compra no puede preceder a la recepción", () => {
    const { message } = humanizeOperationError(
      "delivery_note_purchase_date_before_receipt: la fecha de la compra no puede ser anterior a la del remito",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/fecha de la compra/i)
    expect(message).toMatch(/anterior/i)
    expect(message).toMatch(/recepci[óo]n|remito/i)
    expect(message).not.toMatch(/delivery_note_purchase_date_before_receipt/)
    expect(message).toMatch(/elegí/i)
  })

  it("delivery_note_purchase_mismatch: la compra no coincide con el remito, no se registró nada", () => {
    const { message } = humanizeOperationError(
      "delivery_note_purchase_mismatch: el remito no coincide con la compra",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/no coincide con el remito/i)
    expect(message).toMatch(/no se registr[óo] nada/i)
    expect(message).toMatch(/actualizá el remito y volvé a convertirlo/i)
  })

  it("delivery_note_items_from_source: las líneas salen del remito, no del pedido", () => {
    const { message } = humanizeOperationError(
      "delivery_note_items_from_source: las líneas de la compra salen del remito",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/líneas/i)
    expect(message).toMatch(/del remito/i)
    expect(message).not.toMatch(/delivery_note_items_from_source/)
  })

  it("delivery_note_purchase_locked (P0423): la compra nació del remito; se corrige eliminándola", () => {
    const { message } = humanizeOperationError(
      "delivery_note_purchase_locked: la compra nació del remito RC-00000012",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/nació de un remito/i)
    expect(message).toMatch(/eliminá la compra, editá el remito y volvé a convertirlo/i)
    expect(message).toMatch(/el stock ya se sumó/i)
  })
})

describe("delivery_note_locked_converted — según el sentido", () => {
  const SALE_RAW =
    "delivery_note_locked_converted: el remito ya se convirtió en venta: para corregirlo, eliminá la venta y el remito vuelve a quedar pendiente"
  const PURCHASE_RAW =
    "delivery_note_locked_converted: el remito ya se convirtió en compra: para corregirlo, eliminá la compra y el remito vuelve a quedar pendiente"

  it("compra: 'se convirtió en una compra' y 'eliminá la compra'", () => {
    const { message } = humanizeOperationError(PURCHASE_RAW, undefined, null, PURCHASE)
    expect(message).toMatch(/ya se convirtió en una compra/i)
    expect(message).toMatch(/eliminá la compra/i)
    expect(message).toMatch(/vuelve a quedar pendiente/i)
    expect(message).not.toMatch(/venta/i)
  })

  it("venta con el sentido explícito y sin contexto: el texto de siempre", () => {
    for (const ctx of [SALE, undefined]) {
      const { message } = humanizeOperationError(SALE_RAW, undefined, null, ctx)
      expect(message).toMatch(/ya se convirtió en una venta/i)
      expect(message).toMatch(/eliminá la venta/i)
    }
  })

  it("sin contexto de sentido, el del propio literal del servidor decide (la anulación dice 'compra')", () => {
    const { message } = humanizeOperationError(PURCHASE_RAW, undefined, null, { documentLabel: "remito" })
    expect(message).toMatch(/ya se convirtió en una compra/i)
  })
})

describe("remito de compra — los literales compartidos hablan de compra y de entrada de mercadería", () => {
  it("delivery_note_branch_required: la sucursal a la que entra la mercadería", () => {
    const { message } = humanizeOperationError(
      "delivery_note_branch_required: el remito de compra necesita la sucursal a la que entra la mercadería",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/sucursal a la que entra la mercadería/i)
    expect(message).not.toMatch(/sale la mercadería/i)
  })

  it("delivery_note_branch_required en venta no cambia", () => {
    const { message } = humanizeOperationError(
      "delivery_note_branch_required: el remito necesita la sucursal de la que sale la mercadería",
      undefined,
      null,
      SALE,
    )
    expect(message).toMatch(/sucursal de la que sale la mercadería/i)
  })

  it("delivery_note_invalid_state: puede que ya se haya convertido en compra o anulado", () => {
    const { message } = humanizeOperationError("delivery_note_invalid_state: el remito está canceled", undefined, null, PURCHASE)
    expect(message).toMatch(/convertido en compra/i)
    expect(message).not.toMatch(/convertido en venta/i)
  })

  it("delivery_note_branch_inactive: reactivar la sucursal para editar o anular, o eliminar su compra", () => {
    const { message } = humanizeOperationError(
      "delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada",
      undefined,
      null,
      PURCHASE,
    )
    expect(message).toMatch(/reactivala/i)
    expect(message).toMatch(/eliminar su compra/i)
    expect(message).not.toMatch(/su venta/i)
  })

  it("insufficient_role: recepción = depósito, administrador o dueño; sin 'vendedor'", () => {
    const { message } = humanizeOperationError("insufficient_role", undefined, null, PURCHASE)
    expect(message).toMatch(/depósito, administrador o dueño/i)
    expect(message).toMatch(/anular: administrador o dueño/i)
    expect(message).not.toMatch(/vendedor/i)
  })

  it("branch_closed: no se guardó nada (no se registró 'la venta')", () => {
    const { message } = humanizeOperationError("branch_closed", undefined, null, PURCHASE)
    expect(message).toMatch(/sucursal del remito/i)
    expect(message).not.toMatch(/venta/i)
  })

  it("delivery_note_product_required: la mercadería ENTRA al depósito", () => {
    const { message } = humanizeOperationError("delivery_note_product_required: cada línea necesita un producto", undefined, null, PURCHASE)
    expect(message).toMatch(/entra al depósito/i)
    expect(message).not.toMatch(/sale del depósito/i)
  })

  it("producto dado de baja: se conserva o reduce lo RECIBIDO, no lo entregado", () => {
    const raw = `delivery_note_product_unavailable: el producto ${PID} fue dado de baja: se puede conservar o reducir lo recibido (3.0000), no aumentarlo (5.0000)`
    const { message } = humanizeOperationError(raw, (id) => (id === PID ? "Yerba" : undefined), null, PURCHASE)
    expect(message).toContain("Yerba")
    expect(message).toMatch(/lo recibido \(3\)/i)
    expect(message).not.toMatch(/entregado/i)
  })
})
