/**
 * venta-editable-vs-promocion-legacy — mensajes de "Facturar" (paso 1: preparar
 * la venta para facturar, POST /sales/{op}/promote-to-order).
 *
 * Dos defectos que este archivo fija:
 *   1. `translatePromoteError` trataba CUALQUIER "Conflicto" como "no hay
 *      sucursal activa": el 409 nuevo de filas mezcladas (operation_inconsistent)
 *      habría mandado al usuario a Ajustes a buscar una sucursal que sí tiene.
 *   2. El fallback devolvía el texto CRUDO: el 42883 de min(uuid) que vivió tres
 *      meses llegaba al toast tal cual ("function min(uuid) does not exist").
 */
import { describe, it, expect, vi } from "vitest"

vi.mock("@/lib/api/python-client", () => ({ pythonClient: { post: vi.fn() } }))

import { translatePromoteError } from "@/hooks/data/use-promote-to-order"

describe("translatePromoteError", () => {
  it("operation_inconsistent (409 'Conflicto: …') pide unificar la venta — NO habla de sucursales", () => {
    const msg = translatePromoteError(
      "Conflicto: operation_inconsistent: las líneas de la operación x tienen distinto cliente — editá la venta para unificarlo antes de facturar",
    )
    expect(msg).toBe("Esta venta tiene ítems con distinto cliente o sucursal. Editala para unificarlos y después facturala.")
  })

  it("no_branch_found sigue mandando a Ajustes", () => {
    expect(translatePromoteError("Conflicto: no_branch_found: la cuenta no tiene sucursal activa")).toBe(
      "No encontramos una sucursal activa en la cuenta. Configurá una en Ajustes y volvé a intentar.",
    )
  })

  it("un 409 que no es de sucursal NO se confunde con no_branch_found", () => {
    expect(translatePromoteError("Conflicto: algo_nuevo_del_servidor")).not.toMatch(/sucursal/)
  })

  it("operation_not_found: la venta ya no existe o cambió mientras se preparaba", () => {
    expect(translatePromoteError("No encontrado: operation_not_found: operación x no encontrada o ajena")).toBe(
      "Esta venta ya no existe o cambió mientras la preparábamos. Actualizá la lista y volvé a intentar.",
    )
  })

  it("operation_empty: no hay nada que facturar", () => {
    expect(translatePromoteError("Payload inválido: operation_empty: la operación x no tiene líneas")).toBe(
      "Esta venta no tiene ítems: no hay nada que facturar.",
    )
  })

  it("sin permiso (P0401 'Sin permiso' o el 403 de rol)", () => {
    const expected = "No tenés permiso para facturar ventas en esta cuenta."
    expect(translatePromoteError("Sin permiso: unauthorized: sin permiso de escritura sobre la cuenta")).toBe(expected)
    expect(translatePromoteError("Rol insuficiente: se requiere user o admin")).toBe(expected)
  })

  it("el texto crudo de Postgres NUNCA llega al usuario (el 42883 de min(uuid))", () => {
    const msg = translatePromoteError("Error de base de datos: function min(uuid) does not exist")
    expect(msg).toBe("No pudimos preparar la venta para facturar. Probá de nuevo en unos minutos.")
    expect(msg).not.toMatch(/min\(uuid\)|does not exist|base de datos/)
  })

  it("el 500 genérico del backend también cae en el texto genérico", () => {
    expect(translatePromoteError("Error interno de base de datos.")).toBe(
      "No pudimos preparar la venta para facturar. Probá de nuevo en unos minutos.",
    )
  })

  it("los avisos de sesión (401) se respetan: le dicen al usuario qué hacer", () => {
    expect(translatePromoteError("Tu sesión venció. Te llevamos al inicio de sesión.")).toBe(
      "Tu sesión venció. Te llevamos al inicio de sesión.",
    )
  })
})
