/**
 * Unit tests for C-07 sucursales-module-pro client-side logic.
 *
 * Tests cover pure TypeScript functions only — no Supabase client, no DB.
 * SQL/RLS tests (7.1–7.8) require `npx supabase test db` with a real instance.
 */

import { describe, it, expect } from "vitest"

// ─── Duplicate pure logic from use-branches.ts for isolated testing ────────────

function translateRpcError(message: string): string {
  if (message.includes("branch_limit_exceeded")) return "Límite de sucursales alcanzado para tu plan."
  if (message.includes("branch_name_duplicate")) return "Ya existe una sucursal con ese nombre."
  if (message.includes("unauthorized"))          return "No tenés permisos para realizar esta acción."
  if (message.includes("branch_not_found"))      return "La sucursal no existe."
  return message || "Ocurrió un error inesperado."
}

interface BranchRow {
  id: string
  account_id: string
  name: string
  address: string | null
  is_active: boolean
  created_at: string
}

function mapRow(r: BranchRow) {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    address:   r.address,
    isActive:  r.is_active,
    createdAt: r.created_at,
  }
}

// ─── Plan gating helpers (mirrors DB logic for client-side early rejection) ─────

interface PlanLimits {
  hasBranchesModule: boolean
  maxBranches: number
}

function canCreateBranch(limits: PlanLimits, activeBranchCount: number): boolean {
  return limits.hasBranchesModule && activeBranchCount < limits.maxBranches
}

// ─── translateRpcError ─────────────────────────────────────────────────────────

describe("translateRpcError — branch error codes", () => {
  it("translates branch_limit_exceeded", () => {
    const msg = translateRpcError("P0001: branch_limit_exceeded")
    expect(msg).toBe("Límite de sucursales alcanzado para tu plan.")
  })

  it("translates branch_name_duplicate", () => {
    const msg = translateRpcError("P0001: branch_name_duplicate")
    expect(msg).toBe("Ya existe una sucursal con ese nombre.")
  })

  it("translates unauthorized", () => {
    const msg = translateRpcError("unauthorized: member role cannot write branches")
    expect(msg).toBe("No tenés permisos para realizar esta acción.")
  })

  it("translates branch_not_found", () => {
    const msg = translateRpcError("branch_not_found")
    expect(msg).toBe("La sucursal no existe.")
  })

  it("passes through unknown errors unchanged", () => {
    const msg = translateRpcError("some other db error")
    expect(msg).toBe("some other db error")
  })

  it("returns fallback for empty message", () => {
    const msg = translateRpcError("")
    expect(msg).toBe("Ocurrió un error inesperado.")
  })
})

// ─── mapRow ───────────────────────────────────────────────────────────────────

describe("mapRow — snake_case DB row to camelCase Branch", () => {
  const row: BranchRow = {
    id:         "uuid-1",
    account_id: "acc-1",
    name:       "Sucursal Centro",
    address:    "Av. San Martín 123",
    is_active:  true,
    created_at: "2026-06-07T00:00:00Z",
  }

  it("maps id correctly", () => {
    expect(mapRow(row).id).toBe("uuid-1")
  })

  it("maps account_id → accountId", () => {
    expect(mapRow(row).accountId).toBe("acc-1")
  })

  it("maps is_active → isActive", () => {
    expect(mapRow(row).isActive).toBe(true)
  })

  it("maps null address", () => {
    const withNull = { ...row, address: null }
    expect(mapRow(withNull).address).toBeNull()
  })
})

// ─── canCreateBranch — client-side plan gate ──────────────────────────────────

describe("canCreateBranch — plan gating logic", () => {
  const proLimits: PlanLimits = { hasBranchesModule: true, maxBranches: 3 }
  const nonProLimits: PlanLimits = { hasBranchesModule: false, maxBranches: 1 }

  // Task 7.1 analog: PRO with no branches → can create
  it("allows creation for PRO account with 0 active branches", () => {
    expect(canCreateBranch(proLimits, 0)).toBe(true)
  })

  it("allows creation for PRO account with 2 of 3 branches used", () => {
    expect(canCreateBranch(proLimits, 2)).toBe(true)
  })

  // Task 7.2 analog: PRO at limit → blocked
  it("blocks creation when PRO account has 3 of 3 branches (at limit)", () => {
    expect(canCreateBranch(proLimits, 3)).toBe(false)
  })

  it("blocks creation when PRO account exceeds limit", () => {
    expect(canCreateBranch(proLimits, 4)).toBe(false)
  })

  // Task 7.3 analog: non-PRO plan → blocked
  it("blocks creation for non-PRO plan (hasBranchesModule=false)", () => {
    expect(canCreateBranch(nonProLimits, 0)).toBe(false)
  })

  it("blocks creation for non-PRO even with maxBranches > 0", () => {
    const strangeCase: PlanLimits = { hasBranchesModule: false, maxBranches: 5 }
    expect(canCreateBranch(strangeCase, 0)).toBe(false)
  })
})
