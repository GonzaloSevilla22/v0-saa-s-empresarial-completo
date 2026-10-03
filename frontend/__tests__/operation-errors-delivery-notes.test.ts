/**
 * remitos-venta (D11, tarea 4.5) — traducciones accionables de los literales del
 * remito en el MISMO mapa que ya usan venta, compra y presupuesto
 * (`humanizeOperationError`). Un caso por literal: el texto crudo de la RPC
 * nunca llega al usuario y cada mensaje nombra la salida.
 *
 * Los literales salen de `supabase/migrations/20261069000001_remitos_venta.sql`
 * (los de D11 más los que la tanda A sumó, tarea 1, "Desvíos menores") y de los
 * mapeos del backend (`concurrent_update_retry`).
 */
import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

const PID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"

describe("remito — estado y edición", () => {
  it("delivery_note_not_found: ajeno o inexistente, vuelve al listado", () => {
    const { message } = humanizeOperationError("delivery_note_not_found: 8f0c1f2e-1111-4a3b-9c1d-2f6b7a0c9d11")
    expect(message).toMatch(/no existe|otra cuenta/i)
    expect(message).toMatch(/listado de remitos/i)
    expect(message).not.toMatch(/delivery_note_not_found|8f0c1f2e/)
  })

  it("delivery_note_changed: otro usuario lo modificó mientras estaba abierto", () => {
    const { message } = humanizeOperationError(
      "delivery_note_changed: el remito cambió desde que lo abriste (versión 4 vs 3) — recargalo",
    )
    expect(message).toBe("El remito cambió mientras lo tenías abierto: recargalo y volvé a intentar.")
  })

  it("delivery_note_invalid_state: el estado ya no permite la acción", () => {
    const { message } = humanizeOperationError("delivery_note_invalid_state: el remito está canceled y no se puede editar")
    expect(message).toMatch(/ya no está en un estado/i)
    expect(message).toMatch(/actualizá/i)
    expect(message).not.toMatch(/canceled/)
  })

  it("delivery_note_locked_converted: ya es una venta, se corrige eliminando la venta", () => {
    const { message } = humanizeOperationError(
      "delivery_note_locked_converted: el remito ya se convirtió en venta: para corregirlo, eliminá la venta y el remito vuelve a quedar pendiente",
    )
    expect(message).toMatch(/ya se convirtió en una venta/i)
    expect(message).toMatch(/eliminá la venta/i)
    expect(message).toMatch(/vuelve a quedar pendiente/i)
  })

  it("delivery_note_revision_required: falta la versión (cliente viejo): recargar", () => {
    const { message } = humanizeOperationError("delivery_note_revision_required: falta la versión del remito que se editó")
    expect(message).toMatch(/recargá/i)
    expect(message).not.toMatch(/delivery_note_revision_required/)
  })
})

describe("remito — cliente, sucursal y líneas", () => {
  it("delivery_note_client_unavailable: cliente dado de baja, elegir uno vigente", () => {
    const { message } = humanizeOperationError("delivery_note_client_unavailable: el cliente fue dado de baja")
    expect(message).toMatch(/cliente/i)
    expect(message).toMatch(/dado de baja/i)
    expect(message).toMatch(/elegí un cliente vigente/i)
  })

  it("delivery_note_client_required: el remito necesita un cliente", () => {
    const { message } = humanizeOperationError("delivery_note_client_required: el remito necesita un cliente")
    expect(message).toMatch(/elegí el cliente/i)
  })

  it("delivery_note_branch_required: la sucursal de la que sale la mercadería", () => {
    const { message } = humanizeOperationError(
      "delivery_note_branch_required: el remito necesita la sucursal de la que sale la mercadería",
    )
    expect(message).toMatch(/sucursal de la que sale la mercadería/i)
  })

  it("delivery_note_branch_inactive (P0422): reactivar la sucursal para editar o anular", () => {
    const { message } = humanizeOperationError(
      "delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para anular el remito",
    )
    expect(message).toMatch(/desactivada o cerrada/i)
    expect(message).toMatch(/reactivala/i)
    expect(message).toMatch(/no se (guardó|registró) (nada|ningún cambio)/i)
  })

  it("delivery_note_product_required: no hay líneas sueltas", () => {
    const { message } = humanizeOperationError("delivery_note_product_required: cada línea del remito necesita un producto (línea 2)")
    expect(message).toMatch(/cada línea/i)
    expect(message).toMatch(/producto/i)
    expect(message).not.toMatch(/delivery_note_product_required/)
  })

  it("delivery_note_items_required: al menos una línea", () => {
    const { message } = humanizeOperationError("delivery_note_items_required: el remito necesita al menos una línea")
    expect(message).toMatch(/al menos un producto/i)
  })

  it("delivery_note_too_many_items: el tope de 500 líneas", () => {
    const { message } = humanizeOperationError("delivery_note_too_many_items: máximo 500 líneas por remito")
    expect(message).toMatch(/500/)
    expect(message).toMatch(/dividilo|más de un remito/i)
  })

  it.each([
    ["delivery_note_line_invalid_quantity: la cantidad debe ser mayor que 0 (línea 3)", /cantidad.*mayor que 0/i, /línea 3/],
    ["delivery_note_line_invalid_price: el precio no puede ser negativo (línea 1)", /precio.*negativo/i, /línea 1/],
    ["delivery_note_line_invalid_subtotal: el subtotal no puede ser negativo (línea 5)", /subtotal.*negativo/i, /línea 5/],
  ])("línea inválida (%s) nombra el problema y la línea", (raw, what, line) => {
    const { message } = humanizeOperationError(raw)
    expect(message).toMatch(what)
    expect(message).toMatch(line)
  })

  it("delivery_note_address_too_long y delivery_note_notes_too_long nombran el tope", () => {
    expect(humanizeOperationError("delivery_note_address_too_long: el domicilio admite hasta 500 caracteres").message).toMatch(/500/)
    expect(humanizeOperationError("delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres").message).toMatch(/2\.000/)
  })
})

describe("remito — producto dado de baja después de emitir (D5)", () => {
  const raw = `delivery_note_product_unavailable: el producto ${PID} fue dado de baja: se puede conservar o reducir lo entregado (3.0000), no aumentarlo (5.0000)`

  it("con el nombre resuelto: lo entregado y lo pedido, sin el uuid", () => {
    const { message } = humanizeOperationError(raw, (id) => (id === PID ? "Remera lisa M" : undefined))
    expect(message).toMatch(/«Remera lisa M»/)
    expect(message).toMatch(/dado de baja/i)
    expect(message).toMatch(/\b3\b/)
    expect(message).toMatch(/\b5\b/)
    expect(message).toMatch(/conservar o reducir|no aumentarlo|no se puede aumentar/i)
    expect(message).not.toContain(PID)
  })

  it("sin nombre resoluble: 'uno de los productos', nunca el uuid", () => {
    const { message } = humanizeOperationError(raw)
    expect(message).toMatch(/uno de los productos/i)
    expect(message).not.toContain(PID)
  })
})

describe("remito — anulación", () => {
  it("delivery_note_cancel_reason_required: hay que escribir el motivo", () => {
    const { message } = humanizeOperationError("delivery_note_cancel_reason_required: anular un remito exige un motivo")
    expect(message).toMatch(/motivo de la anulación/i)
  })

  it("delivery_note_cancel_reason_too_long: el tope de 500", () => {
    const { message } = humanizeOperationError("delivery_note_cancel_reason_too_long: el motivo admite hasta 500 caracteres")
    expect(message).toMatch(/500/)
  })
})

describe("remito — tanda B (conversión, borrado y edición de la venta)", () => {
  it("delivery_note_sale_locked (P0423): la venta nació del remito, se corrige eliminándola", () => {
    const { message } = humanizeOperationError(
      "delivery_note_sale_locked: la venta nació del remito R-00000012: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo",
    )
    expect(message).toMatch(/nació de un remito/i)
    expect(message).toMatch(/eliminá la venta/i)
    expect(message).toMatch(/volvé a convertirlo/i)
  })

  it("delivery_note_order_mismatch: la orden no coincide con el remito, no se registró nada", () => {
    const { message } = humanizeOperationError("delivery_note_order_mismatch: las líneas de la orden no coinciden con el remito")
    expect(message).toMatch(/no coincide/i)
    expect(message).toMatch(/no se registró nada/i)
  })
})

describe("remito — concurrencia", () => {
  it("concurrent_update_retry (409): otra operación tocó los mismos productos, reintentar es seguro", () => {
    const { message } = humanizeOperationError("concurrent_update_retry")
    expect(message).toMatch(/mismos productos al mismo tiempo/i)
    expect(message).toMatch(/volvé a intentarlo/i)
  })
})

describe("contexto documentLabel — el remito no habla de 'la venta'", () => {
  const stockError = `stock_insuficiente para producto ${PID}: disponible 2.0000, solicitado 3.0000`

  it("por defecto (venta) el texto de stock no cambia: 'la sucursal de esta operación' y 'de la venta'", () => {
    const { message } = humanizeOperationError(stockError)
    expect(message).toContain("la sucursal de esta operación")
    expect(message).toContain("cambiá la sucursal de la venta")
  })

  it("con documentLabel 'venta' explícito da exactamente lo mismo que el default", () => {
    expect(humanizeOperationError(stockError, undefined, "Centro", { documentLabel: "venta" })).toEqual(
      humanizeOperationError(stockError, undefined, "Centro"),
    )
  })

  it("stock_insuficiente en un remito: dice 'remito' y nunca 'la venta'; conserva la acción de transferir", () => {
    const result = humanizeOperationError(stockError, (id) => (id === PID ? "Yerba 1kg" : undefined), "Centro", {
      documentLabel: "remito",
    })
    expect(result.message).toMatch(/«Yerba 1kg»/)
    expect(result.message).toMatch(/sucursal Centro/)
    expect(result.message).toMatch(/remito/i)
    expect(result.message).not.toMatch(/la venta/i)
    expect(result.message).not.toMatch(/esta operación/i)
    expect(result.action).toEqual({ label: "Transferir stock", href: `/stock?product=${PID}` })
  })

  it("stock_insuficiente en un remito sin sucursal conocida: 'la sucursal del remito'", () => {
    const { message } = humanizeOperationError(stockError, undefined, null, { documentLabel: "remito" })
    expect(message).toContain("la sucursal del remito")
    expect(message).not.toMatch(/la venta/i)
  })

  it("client_not_found en un remito: 'Cliente dado de baja — elegí uno vigente'", () => {
    const { message } = humanizeOperationError("client_not_found: 8f0c1f2e-1111-4a3b-9c1d-2f6b7a0c9d11", undefined, null, {
      documentLabel: "remito",
    })
    expect(message).toBe("Cliente dado de baja — elegí uno vigente")
  })

  it("client_not_found en una venta sigue con su texto de siempre", () => {
    const { message } = humanizeOperationError("client_not_found: 8f0c1f2e-1111-4a3b-9c1d-2f6b7a0c9d11")
    expect(message).toMatch(/no existe o no pertenece a esta cuenta/i)
  })

  it("insufficient_role en un remito: nombra quién emite y quién anula, no 'rol de vendedor'", () => {
    const { message } = humanizeOperationError("insufficient_role: tu rol no permite anular", undefined, null, {
      documentLabel: "remito",
    })
    expect(message).toMatch(/anular/i)
    expect(message).toMatch(/administrador|dueño/i)
    expect(message).not.toMatch(/rol de vendedor/i)
  })

  it("insufficient_role en una venta sigue igual", () => {
    expect(humanizeOperationError("insufficient_role").message).toMatch(/rol de vendedor/i)
  })
})

describe("remito — reutiliza el vocabulario existente sin duplicarlo", () => {
  it("branch_closed: la emisión con la sucursal cerrada ya está traducida", () => {
    const { message } = humanizeOperationError("branch_closed: la sucursal está cerrada")
    expect(message).toMatch(/sucursal está cerrada/i)
  })

  it("idempotency_key_conflict, insufficient_role y payment_method_required siguen traduciendo", () => {
    expect(humanizeOperationError("idempotency_key_conflict: la clave ya se usó para otra operación").message).toMatch(/otro documento/i)
    expect(humanizeOperationError("payment_method_required").message).toMatch(/forma de pago/i)
  })

  it("un mensaje desconocido vuelve tal cual (nunca se oculta)", () => {
    expect(humanizeOperationError("algo raro", undefined, null, { documentLabel: "remito" }).message).toBe("algo raro")
  })
})
