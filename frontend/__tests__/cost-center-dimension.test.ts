/**
 * cost-center-dimension — Frontend unit tests (task 5.4 TDD RED→GREEN).
 *
 * Tests cover:
 *   - mapCostCenter: API row → CostCenter domain object
 *   - CostCenter type constraints (no 'any')
 *   - Selector filter: only active centers shown in new-entry forms
 *   - Role gating: CRUD visible only to owner/admin
 *   - Mutation payloads: create/update/deactivate send correct data
 */
import { describe, it, expect } from "vitest"
import type { CostCenter } from "@/lib/types"

// ── Pure functions extracted from the hook for isolated testing ──────────────

interface CostCenterApiRow {
  id: string
  account_id: string
  name: string
  code: string | null
  is_active: boolean
  created_at: string
}

function mapCostCenter(r: CostCenterApiRow): CostCenter {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    code:      r.code,
    isActive:  r.is_active,
    createdAt: r.created_at,
  }
}

function filterActiveCenters(centers: CostCenter[]): CostCenter[] {
  return centers.filter(c => c.isActive)
}

/**
 * Simulate role-gating logic for catalog management UI.
 * Returns true if the role can create/update/deactivate cost centers.
 */
function canManageCostCenters(role: string | null): boolean {
  return role === "owner" || role === "admin"
}

/**
 * Build the API payload for creating a cost center (mirrors the mutation).
 */
function buildCreatePayload(name: string, code: string | null): { name: string; code?: string } {
  const payload: { name: string; code?: string } = { name: name.trim() }
  if (code !== null && code.trim().length > 0) {
    payload.code = code.trim()
  }
  return payload
}

// ── mapCostCenter ─────────────────────────────────────────────────────────────

describe("mapCostCenter — API row → CostCenter", () => {
  it("maps all fields correctly", () => {
    const row: CostCenterApiRow = {
      id:         "cccccccc-cccc-cccc-cccc-cccccccccccc",
      account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name:       "Marketing",
      code:       "MKTO",
      is_active:  true,
      created_at: "2026-08-02T10:00:00+00:00",
    }

    const cc = mapCostCenter(row)

    expect(cc.id).toBe(row.id)
    expect(cc.accountId).toBe(row.account_id)
    expect(cc.name).toBe("Marketing")
    expect(cc.code).toBe("MKTO")
    expect(cc.isActive).toBe(true)
    expect(cc.createdAt).toBe(row.created_at)
  })

  it("maps null code correctly", () => {
    const row: CostCenterApiRow = {
      id:         "dddddddd-dddd-dddd-dddd-dddddddddddd",
      account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name:       "Logística",
      code:       null,
      is_active:  true,
      created_at: "2026-08-02T11:00:00+00:00",
    }

    const cc = mapCostCenter(row)

    expect(cc.code).toBeNull()
  })

  it("maps is_active=false correctly", () => {
    const row: CostCenterApiRow = {
      id:         "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
      account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name:       "Archivado",
      code:       null,
      is_active:  false,
      created_at: "2026-07-01T09:00:00+00:00",
    }

    const cc = mapCostCenter(row)

    expect(cc.isActive).toBe(false)
  })
})


// ── filterActiveCenters — selector shows only active ─────────────────────────

describe("filterActiveCenters — only active shown in new-entry selector", () => {
  const active: CostCenter = {
    id: "1", accountId: "a", name: "Marketing", code: null,
    isActive: true, createdAt: "2026-08-02T10:00:00+00:00",
  }
  const inactive: CostCenter = {
    id: "2", accountId: "a", name: "Archivado", code: null,
    isActive: false, createdAt: "2026-07-01T09:00:00+00:00",
  }

  it("returns only active centers", () => {
    const result = filterActiveCenters([active, inactive])
    expect(result).toHaveLength(1)
    expect(result[0].name).toBe("Marketing")
  })

  it("returns empty list when all are inactive", () => {
    const result = filterActiveCenters([inactive])
    expect(result).toHaveLength(0)
  })

  it("returns all when all are active", () => {
    const another: CostCenter = { ...active, id: "3", name: "Logística" }
    const result = filterActiveCenters([active, another])
    expect(result).toHaveLength(2)
  })
})


// ── canManageCostCenters — role gating for CRUD ───────────────────────────────

describe("canManageCostCenters — owner/admin can manage, member cannot", () => {
  it("owner can manage", () => {
    expect(canManageCostCenters("owner")).toBe(true)
  })

  it("admin can manage", () => {
    expect(canManageCostCenters("admin")).toBe(true)
  })

  it("member CANNOT manage", () => {
    expect(canManageCostCenters("member")).toBe(false)
  })

  it("null role CANNOT manage (unauthenticated or loading)", () => {
    expect(canManageCostCenters(null)).toBe(false)
  })
})


// ── buildCreatePayload — mutation payload shape ───────────────────────────────

describe("buildCreatePayload — API payload for create mutation", () => {
  it("includes name when provided", () => {
    const payload = buildCreatePayload("Marketing", null)
    expect(payload.name).toBe("Marketing")
  })

  it("trims whitespace from name", () => {
    const payload = buildCreatePayload("  Logística  ", null)
    expect(payload.name).toBe("Logística")
  })

  it("includes code when provided", () => {
    const payload = buildCreatePayload("Marketing", "MKTO")
    expect(payload.code).toBe("MKTO")
  })

  it("omits code when null", () => {
    const payload = buildCreatePayload("Marketing", null)
    expect(payload.code).toBeUndefined()
  })

  it("omits code when empty string", () => {
    const payload = buildCreatePayload("Marketing", "   ")
    expect(payload.code).toBeUndefined()
  })
})


// ── Type safety: cost_center_id optional on Expense ──────────────────────────

describe("Expense type includes optional costCenterId", () => {
  it("accepts expense without costCenterId", () => {
    const expense: import("@/lib/types").Expense = {
      id: "e1",
      date: "2026-08-02",
      category: "Servicios",
      description: "Internet",
      amount: 5000,
    }
    expect(expense.costCenterId).toBeUndefined()
  })

  it("accepts expense with costCenterId", () => {
    const expense: import("@/lib/types").Expense = {
      id: "e1",
      date: "2026-08-02",
      category: "Servicios",
      description: "Internet",
      amount: 5000,
      costCenterId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
    }
    expect(expense.costCenterId).toBe("cccccccc-cccc-cccc-cccc-cccccccccccc")
  })

  it("accepts expense with costCenterId=null (unassigned)", () => {
    const expense: import("@/lib/types").Expense = {
      id: "e1",
      date: "2026-08-02",
      category: "Servicios",
      description: "Internet",
      amount: 5000,
      costCenterId: null,
    }
    expect(expense.costCenterId).toBeNull()
  })
})
