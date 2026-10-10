/**
 * ventas-sucursal-por-defecto (D10, tarea 5.1) — `lib/default-branch.ts`: UNA
 * sola definición de "la principal" en el cliente, espejo exacto de
 * `c26_default_branch` del servidor: la primera sucursal activa Y operativa
 * (`status = 'active'`) por antigüedad; sin ninguna operativa, la más antigua a
 * secas. Recibe las sucursales como las devuelve `useBranches`
 * (`created_at` ascendente) y respeta ese orden.
 */
import { describe, it, expect } from "vitest"
import { resolveDefaultBranch } from "@/lib/default-branch"
import type { Branch } from "@/lib/types"

function branch(id: string, overrides: Partial<Branch> = {}): Branch {
  return {
    id,
    accountId: "acc-1",
    name: `Sucursal ${id}`,
    address: null,
    isActive: true,
    createdAt: "2026-01-01T00:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...overrides,
  }
}

describe("resolveDefaultBranch — espejo de c26_default_branch", () => {
  it("lista vacía: no hay principal", () => {
    expect(resolveDefaultBranch([])).toBeNull()
  })

  it("devuelve la primera sucursal activa de la lista", () => {
    const a = branch("a", { createdAt: "2026-01-01T00:00:00Z" })
    const b = branch("b", { createdAt: "2026-02-01T00:00:00Z" })
    expect(resolveDefaultBranch([a, b])).toBe(a)
  })

  it("una sola sucursal: es la principal", () => {
    const only = branch("solo")
    expect(resolveDefaultBranch([only])).toBe(only)
  })

  it("saltea la más antigua si está CERRADA: la principal es la siguiente operativa", () => {
    const cerrada = branch("cerrada", { status: "closed", createdAt: "2026-01-01T00:00:00Z" })
    const b = branch("b", { createdAt: "2026-02-01T00:00:00Z" })
    const c = branch("c", { createdAt: "2026-03-01T00:00:00Z" })
    expect(resolveDefaultBranch([cerrada, b, c])).toBe(b)
  })

  it("saltea varias cerradas seguidas hasta la primera operativa", () => {
    const x = branch("x", { status: "closed" })
    const y = branch("y", { status: "closed" })
    const z = branch("z")
    expect(resolveDefaultBranch([x, y, z])).toBe(z)
  })

  it("todas cerradas: cae en la primera de la lista (el fallback de c26_default_branch)", () => {
    const x = branch("x", { status: "closed", createdAt: "2026-01-01T00:00:00Z" })
    const y = branch("y", { status: "closed", createdAt: "2026-02-01T00:00:00Z" })
    expect(resolveDefaultBranch([x, y])).toBe(x)
  })

  it("respeta el orden de entrada (el de useBranches): no reordena por su cuenta", () => {
    const tarde = branch("tarde", { createdAt: "2026-09-01T00:00:00Z" })
    const temprano = branch("temprano", { createdAt: "2026-01-01T00:00:00Z" })
    // El contrato es que la lista ya viene por antigüedad; el helper devuelve la primera operativa que ve.
    expect(resolveDefaultBranch([tarde, temprano])).toBe(tarde)
  })

  it("una sucursal inactiva (is_active = false) tampoco es operativa", () => {
    const inactiva = branch("inactiva", { isActive: false })
    const activa = branch("activa")
    expect(resolveDefaultBranch([inactiva, activa])).toBe(activa)
  })
})
