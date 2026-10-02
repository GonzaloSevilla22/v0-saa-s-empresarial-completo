/**
 * presupuestos-modulo (D10, task 4.7) — traducciones accionables de los literales
 * nuevos del presupuesto y de la conversión en venta, en el MISMO mapa que ya
 * usan venta y compra (`humanizeOperationError`). Un test por literal: el texto
 * crudo de la RPC nunca llega al usuario y cada mensaje nombra la salida.
 */
import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

describe("presupuesto — literales de estado y edición", () => {
  it("quote_locked_converted: ya es una venta, los cambios van sobre la venta", () => {
    const { message } = humanizeOperationError(
      "quote_locked_converted: el presupuesto P-00000012 ya se convirtió en la venta 5; los cambios se hacen sobre la venta",
    )
    expect(message).toMatch(/ya se convirtió en una venta/i)
    expect(message).toMatch(/sobre la venta/i)
    expect(message).toMatch(/duplicalo/i)
    expect(message).not.toMatch(/quote_locked_converted/)
  })

  it("quote_expired: vencido, se amplía la validez o se duplica", () => {
    const { message } = humanizeOperationError("quote_expired: el presupuesto venció el 2026-09-30")
    expect(message).toMatch(/vencido/i)
    expect(message).toMatch(/ampliar la validez/i)
    expect(message).toMatch(/duplicalo/i)
  })

  it("quote_invalid_state: el estado ya no permite la acción", () => {
    const { message } = humanizeOperationError("quote_invalid_state: estado actual accepted")
    expect(message).toMatch(/ya no está en un estado/i)
    expect(message).toMatch(/actualizá/i)
  })

  it("quote_not_deletable: sólo se borra un borrador nunca enviado", () => {
    const { message } = humanizeOperationError("quote_not_deletable: el presupuesto ya salió al cliente")
    expect(message).toMatch(/borrador que nunca se envió/i)
    expect(message).toMatch(/rechazalo|duplicalo/i)
  })

  it("quote_valid_until_in_past: la fecha de validez no puede ser anterior a hoy", () => {
    const { message } = humanizeOperationError("quote_valid_until_in_past: 2026-09-01")
    expect(message).toMatch(/fecha de validez/i)
    expect(message).toMatch(/hoy o una fecha posterior/i)
  })

  it("quote_valid_until_required: la edición exige la validez", () => {
    const { message } = humanizeOperationError("quote_valid_until_required")
    expect(message).toMatch(/hasta qué fecha/i)
  })

  it("quote_changed: otro usuario lo modificó mientras estaba abierto", () => {
    const { message } = humanizeOperationError("quote_changed: revision 4, esperada 3")
    expect(message).toBe("El presupuesto cambió mientras lo tenías abierto: revisalo y volvé a intentar.")
  })
})

describe("presupuesto — líneas, producto y cliente", () => {
  it("quote_product_unavailable con nombre: pide editar y quitar o reemplazar ESE producto", () => {
    const { message } = humanizeOperationError("quote_product_unavailable: Remera lisa M")
    expect(message).toMatch(/«Remera lisa M»/)
    expect(message).toMatch(/editá el presupuesto/i)
    expect(message).toMatch(/quitá o reemplazá/i)
  })

  it("quote_product_unavailable sin nombre usa un genérico en vez de 'undefined'", () => {
    const { message } = humanizeOperationError("quote_product_unavailable")
    expect(message).toMatch(/uno de los productos/i)
    expect(message).not.toMatch(/undefined|«»/)
  })

  it("quote_client_unavailable: el cliente fue dado de baja", () => {
    const { message } = humanizeOperationError("quote_client_unavailable: el cliente fue dado de baja")
    expect(message).toMatch(/cliente.*dado de baja/i)
    expect(message).toMatch(/elegí un cliente vigente/i)
  })

  it("product_not_found: un producto no existe o no es de la cuenta", () => {
    const { message } = humanizeOperationError("product_not_found: 0dd2e5bb-2b93-4470-b4b6-52f008046112")
    expect(message).toMatch(/no existe o no pertenece a esta cuenta/i)
    expect(message).not.toMatch(/0dd2e5bb/) // el uuid no le dice nada al usuario
  })

  it("product_is_parent: hay que elegir una variante", () => {
    const { message } = humanizeOperationError("product_is_parent: 0dd2e5bb-2b93-4470-b4b6-52f008046112")
    expect(message).toMatch(/variantes/i)
    expect(message).toMatch(/elegí la variante/i)
  })
})

describe("permisos y conversión en venta", () => {
  it("insufficient_role (P0403 de la RPC) -> 'Tu rol no permite …'", () => {
    const { message } = humanizeOperationError("insufficient_role")
    expect(message.startsWith("Tu rol no permite")).toBe(true)
    expect(message).toMatch(/administrador/i)
  })

  it("el 403 del backend (require_account_role) dice lo mismo", () => {
    const { message } = humanizeOperationError("Rol de cuenta insuficiente: se requiere admin o owner o seller")
    expect(message.startsWith("Tu rol no permite")).toBe(true)
  })

  it("cash_requires_session: pide abrir la caja y ofrece ir a /caja", () => {
    const { message, action } = humanizeOperationError("cash_requires_session: la forma de pago es efectivo")
    expect(message).toMatch(/caja abierta/i)
    expect(message).toMatch(/otra forma de pago/i)
    expect(action).toEqual({ label: "Ir a Caja", href: "/caja" })
  })

  it("idempotency_key_conflict: la clave ya se usó con otro documento", () => {
    const { message } = humanizeOperationError("idempotency_key_conflict")
    expect(message).toMatch(/ya se usó|ya se registró/i)
    expect(message).toMatch(/volvé a intentar/i)
  })

  it("payment_method_required: hay que elegir la forma de pago", () => {
    const { message } = humanizeOperationError("payment_method_required")
    expect(message).toMatch(/forma de pago/i)
  })
})

describe("sin regresiones sobre el mapa existente", () => {
  it("el stock insuficiente de la conversión sigue su camino (producto + transferir)", () => {
    const { message, action } = humanizeOperationError(
      "stock_insuficiente para producto 0dd2e5bb-2b93-4470-b4b6-52f008046112: disponible 1, solicitado 3",
      () => "Remera",
    )
    expect(message).toMatch(/«Remera»/)
    expect(action?.href).toBe("/stock?product=0dd2e5bb-2b93-4470-b4b6-52f008046112")
  })

  it("un cliente inexistente sigue con su texto propio (no lo pisa quote_client_unavailable)", () => {
    expect(humanizeOperationError("client_not_found: x").message).toMatch(/no existe o no pertenece/i)
  })

  it("un mensaje desconocido vuelve tal cual, sin acción", () => {
    expect(humanizeOperationError("algo raro del servidor")).toEqual({ message: "algo raro del servidor" })
  })
})
