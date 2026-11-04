/**
 * multiusuario-operativo TANDA B (10.4) — los rechazos de rol y de autor de las RPCs de ventas y
 * compras se humanizan: el usuario lee QUÉ rol hace falta o QUIÉN puede modificar lo ajeno, nunca
 * el token `insufficient_role` ni el literal `unauthorized`.
 */
import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

describe("humanizeOperationError — capacidad de rol de ventas y compras (P0403 / P0401)", () => {
  it.each([
    ["insufficient_role: tu rol no permite registrar ventas (requiere vendedor, cajero, administrador o dueño)", /registrar ventas/i, /vendedor, cajero, administrador o dueño/i],
    ["insufficient_role: tu rol no permite editar ventas (requiere vendedor, cajero, administrador o dueño)", /editar ventas/i, /vendedor, cajero/i],
    ["insufficient_role: tu rol no permite eliminar ventas (requiere vendedor, cajero, administrador o dueño)", /eliminar ventas/i, /vendedor, cajero/i],
    ["insufficient_role: tu rol no permite registrar compras (requiere compras, administrador o dueño)", /registrar compras/i, /compras, administrador o dueño/i],
    ["insufficient_role: tu rol no permite editar compras (requiere compras, administrador o dueño)", /editar compras/i, /compras, administrador o dueño/i],
    ["insufficient_role: tu rol no permite eliminar compras (requiere compras, administrador o dueño)", /eliminar compras/i, /compras, administrador o dueño/i],
  ])("%s", (raw, action, roles) => {
    const { message } = humanizeOperationError(raw)
    expect(message).toMatch(action)
    expect(message).toMatch(roles)
    expect(message).not.toContain("insufficient_role")
    // la compra NO le sugiere al usuario "el rol de vendedor"
    if (/compras/.test(raw)) expect(message).not.toMatch(/rol de vendedor/i)
  })

  it("la regla de autor: sobre lo de otro miembro sólo dueño o administrador", () => {
    for (const what of ["ventas", "compras"]) {
      const { message } = humanizeOperationError(
        `insufficient_role: solo el dueño o un administrador modifican las ${what} que cargó otro miembro`,
      )
      expect(message).toMatch(new RegExp(`dueño o un administrador modifican las ${what} que cargó otro miembro`, "i"))
      expect(message).not.toContain("insufficient_role")
    }
  })

  it("el observador (P0401 unauthorized) lee que su usuario sólo puede ver", () => {
    const { message } = humanizeOperationError("unauthorized")
    expect(message).toMatch(/solo puede ver|sólo puede ver|solo lectura|sólo lectura/i)
    expect(message).not.toBe("unauthorized")
  })

  it("el producto de otra cuenta (P0404) se explica sin revelar que existe", () => {
    const { message } = humanizeOperationError("Product not found: 0a7b0f81-230a-4957-a688-6373cd61ad00")
    expect(message).toMatch(/no existe o no pertenece a esta cuenta/i)
    expect(message).not.toMatch(/0a7b0f81/)
  })

  it("CONTROLES: el resto del mapa no cambia", () => {
    expect(humanizeOperationError("insufficient_role").message).toMatch(/rol de vendedor/i)
    expect(humanizeOperationError("Rol de cuenta insuficiente: se requiere admin o owner").message).toMatch(/Tu rol no permite/i)
  })
})
