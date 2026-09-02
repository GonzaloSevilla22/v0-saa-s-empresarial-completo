/**
 * Regresión prod 2026-08-24: el PO vio
 * `Insufficient stock for product 0dd2e5bb-...` con el producto SÍ en stock
 * (estaba en otra sucursal — la venta descuenta de la sucursal de la operación).
 */
import { describe, expect, it } from "vitest"

import { humanizeOperationError } from "@/lib/operation-errors"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"
const lookup = (id: string) =>
  id === PRODUCT_ID ? "Top Pupera Liso Talle 1 Violeta" : undefined

describe("humanizeOperationError — stock por sucursal", () => {
  it("EL CASO DEL PO: nombra el producto y explica que es por sucursal", () => {
    const out = humanizeOperationError(
      `Insufficient stock for product ${PRODUCT_ID}`,
      lookup,
      "Showroom",
    )

    expect(out.message).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out.message).toContain("Showroom")
    expect(out.message).toContain("otra sucursal")
    expect(out.message).not.toContain(PRODUCT_ID) // el UUID no le sirve a nadie
  })

  it("traduce también la variante con sucursal explícita", () => {
    const out = humanizeOperationError(
      `insufficient_branch_stock for product ${PRODUCT_ID}`,
      lookup,
      "Principal",
    )

    expect(out.message).toContain("Top Pupera Liso Talle 1 Violeta")
    expect(out.message).toContain("Principal")
  })

  it("sin nombre resoluble, no inventa: habla de 'uno de los productos'", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, () => undefined)

    expect(out.message).toContain("uno de los productos")
    expect(out.message).toContain("sucursal")
  })

  it("sin sucursal conocida usa una redacción neutra", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, lookup, null)

    expect(out.message).toContain("la sucursal de esta operación")
  })

  it("un error que no reconoce se devuelve intacto y SIN acción (nunca oculta información)", () => {
    const original = "credit_requires_client: la venta a cuenta corriente exige un cliente"
    const out = humanizeOperationError(original, lookup)
    expect(out.message).toBe(original)
    expect(out.action).toBeUndefined()
  })

  it("mensaje vacío degrada a texto genérico, sin acción", () => {
    const out = humanizeOperationError("", lookup)
    expect(out.message).toBe("Error desconocido")
    expect(out.action).toBeUndefined()
  })

  // sucursal-guard-vaciado-auditoria (G3, task 7.4): el error de stock ofrece
  // un camino directo a transferir el producto involucrado.
  it("el error de stock por sucursal trae una acción hacia /stock con el producto preseleccionado", () => {
    const out = humanizeOperationError(`Insufficient stock for product ${PRODUCT_ID}`, lookup, "Showroom")

    expect(out.action).toEqual({
      label: "Transferir stock",
      href: `/stock?product=${PRODUCT_ID}`,
    })
  })
})

// qa-integral-modulos G10 (H21a): tres details crudos del backend que el QA
// vio impresos tal cual al microemprendedor — se traducen en el MISMO mapa
// (regla del proyecto: no crear otro).
describe("humanizeOperationError — details crudos del servidor (G10/H21a)", () => {
  it("RN-B4 (borrar producto con stock): sin el código interno ni los 4 decimales", () => {
    const out = humanizeOperationError(
      'RN-B4: el producto "QAT676743" tiene stock (6.0000) — ajustá el stock a 0 antes de borrarlo',
    )

    expect(out.message).not.toContain("RN-B4")
    expect(out.message).not.toContain("6.0000")
    expect(out.message).toContain("«QAT676743»")
    expect(out.message).toContain("6")
    expect(out.message).toMatch(/stock/i)
    expect(out.message).toMatch(/lleg(á|ue)|llev(á|a)|ajust(á|a)/i)
  })

  it("amounts_mismatch (conciliación): explica los dos totales en formato moneda", () => {
    const out = humanizeOperationError(
      "amounts_mismatch: Σ líneas (420000.00) ≠ Σ movimientos (-64000.00)",
    )

    expect(out.message).not.toContain("amounts_mismatch")
    expect(out.message).not.toContain("Σ")
    expect(out.message).toContain("420.000")
    expect(out.message).toContain("64.000")
    expect(out.message).toMatch(/no coinciden|coincidir/i)
    expect(out.message).toMatch(/selecci/i)
  })

  it("amounts_mismatch sin los montos parseables igual se traduce (degrada sin números)", () => {
    const out = humanizeOperationError("amounts_mismatch")
    expect(out.message).not.toContain("amounts_mismatch")
    expect(out.message).toMatch(/no coinciden|coincidir/i)
  })

  it("periodo_invalido (nueva conciliación): habla de Desde/Hasta, no de period_from", () => {
    const out = humanizeOperationError("periodo_invalido: period_from debe ser <= period_to")

    expect(out.message).not.toContain("periodo_invalido")
    expect(out.message).not.toContain("period_from")
    expect(out.message).toMatch(/Desde/)
    expect(out.message).toMatch(/Hasta/)
  })

  // cobranzas-reverso (task 11.4): errores propios de la anulación de un
  // cobro/pago de cuenta corriente.
  it("no_open_session_for_reversal (P0426): explica que hay que abrir la caja", () => {
    const out = humanizeOperationError(
      "no_open_session_for_reversal: abrí la caja para poder anular este cobro",
    )
    expect(out.message).not.toContain("no_open_session_for_reversal")
    expect(out.message).toMatch(/caja/i)
    expect(out.message).toMatch(/cerrada|abrir|abrí/i)
  })

  it("payment_not_found (P0404): dice que ya no existe, sin exponer el detalle técnico", () => {
    const out = humanizeOperationError(
      "payment_not_found: el cobro no existe o no pertenece a esta cuenta",
    )
    expect(out.message).not.toContain("payment_not_found")
    expect(out.message).toMatch(/no existe|anuló/i)
  })

  it("journal_entry_original_not_found (P0451): no es un error fatal, explica que se completa solo", () => {
    const out = humanizeOperationError(
      "journal_entry_original_not_found: no se encontró el asiento vigente para el cobro anulado",
    )
    expect(out.message).not.toContain("journal_entry_original_not_found")
    expect(out.message).toMatch(/asiento/i)
  })
})
