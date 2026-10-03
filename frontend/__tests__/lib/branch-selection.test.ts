/**
 * remitos-venta (D11, tarea 4.7) — `lib/branch-selection.ts`: la sucursal con la
 * que nace el formulario del remito.
 *
 * Mientras el PR #607 (`ventas-sucursal-por-defecto`, `lib/default-branch.ts`) no
 * esté en `main`, el criterio es el de `c26_default_branch` en el servidor: la
 * sucursal activa y NO cerrada más antigua (`created_at` ascendente). A
 * diferencia del servidor, sin fallback a una cerrada: un remito no puede salir
 * de una sucursal cerrada.
 */
import { describe, it, expect } from "vitest"
import { operativeBranches, pickOldestOperativeBranchId } from "@/lib/branch-selection"

type B = Parameters<typeof operativeBranches>[0][number]

function branch(id: string, createdAt: string, overrides: Partial<B> = {}): B {
  return { id, createdAt, isActive: true, status: "active", ...overrides }
}

describe("operativeBranches", () => {
  it("deja sólo las activas y abiertas, de la más antigua a la más nueva", () => {
    const result = operativeBranches([
      branch("nueva", "2026-05-01T00:00:00Z"),
      branch("vieja", "2026-01-01T00:00:00Z"),
      branch("cerrada", "2025-01-01T00:00:00Z", { status: "closed" }),
      branch("inactiva", "2025-06-01T00:00:00Z", { isActive: false }),
    ])
    expect(result.map((b) => b.id)).toEqual(["vieja", "nueva"])
  })

  it("no muta el arreglo recibido", () => {
    const input = [branch("b", "2026-02-01T00:00:00Z"), branch("a", "2026-01-01T00:00:00Z")]
    operativeBranches(input)
    expect(input.map((b) => b.id)).toEqual(["b", "a"])
  })

  it("sin sucursales: vacío", () => {
    expect(operativeBranches([])).toEqual([])
  })
})

describe("pickOldestOperativeBranchId", () => {
  it("elige la más antigua activa y abierta", () => {
    expect(
      pickOldestOperativeBranchId([
        branch("segunda", "2026-03-01T00:00:00Z"),
        branch("primera", "2026-01-01T00:00:00Z"),
      ]),
    ).toBe("primera")
  })

  it("salta la más antigua si está cerrada o desactivada", () => {
    expect(
      pickOldestOperativeBranchId([
        branch("cerrada", "2025-01-01T00:00:00Z", { status: "closed" }),
        branch("inactiva", "2025-02-01T00:00:00Z", { isActive: false }),
        branch("viva", "2026-01-01T00:00:00Z"),
      ]),
    ).toBe("viva")
  })

  it("con una sola sucursal operativa, es esa", () => {
    expect(pickOldestOperativeBranchId([branch("unica", "2026-01-01T00:00:00Z")])).toBe("unica")
  })

  it("sin ninguna operativa: null (el formulario no deja agregar líneas)", () => {
    expect(pickOldestOperativeBranchId([branch("c", "2026-01-01T00:00:00Z", { status: "closed" })])).toBeNull()
    expect(pickOldestOperativeBranchId([])).toBeNull()
  })

  it("empate de fecha: conserva el orden de llegada (estable)", () => {
    expect(
      pickOldestOperativeBranchId([
        branch("x", "2026-01-01T00:00:00Z"),
        branch("y", "2026-01-01T00:00:00Z"),
      ]),
    ).toBe("x")
  })
})
