/**
 * TDD tests for holdsOwnStock — the single predicate that decides whether a
 * product is a real inventory line (counted / adjusted / reordered) or a
 * catalogue construct that should not appear in the stock/reposition views.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect } from "vitest"
import { holdsOwnStock, getStockStatus, isBelowThreshold } from "@/lib/product-stock"

describe("holdsOwnStock", () => {
  // ── RED → GREEN: real inventory is included ──────────────────────────────
  it("includes tracked products (physical stock counted per sale)", () => {
    expect(holdsOwnStock({ stockControlType: "tracked" })).toBe(true)
  })

  // ── TRIANGULATE: variant_only parents are excluded ───────────────────────
  it("excludes variant_only parents (stock lives in the variant children)", () => {
    expect(holdsOwnStock({ stockControlType: "variant_only" })).toBe(false)
  })

  // ── TRIANGULATE: untracked services are excluded ─────────────────────────
  it("excludes untracked services (no stock to reposition)", () => {
    expect(holdsOwnStock({ stockControlType: "untracked" })).toBe(false)
  })

  // ── TRIANGULATE: fail-open on missing/unknown control type ───────────────
  it("fails open: undefined control type is treated as real inventory", () => {
    expect(holdsOwnStock({ stockControlType: undefined })).toBe(true)
  })

  it("fails open: unexpected legacy value ('unit') stays visible, never hidden", () => {
    // Legacy backend rows default stock_control_type to "unit" (see
    // product_repository.py); it is not in the union but must never be hidden.
    // @ts-expect-error — intentionally out-of-union legacy value
    expect(holdsOwnStock({ stockControlType: "unit" })).toBe(true)
  })
})

describe("getStockStatus", () => {
  // ── RED → GREEN: no threshold configured (minStock 0) is never critical ──
  // Canonical rule (RN-23 `check_branch_low_stock` + `get_dashboard_critical_stock`):
  // min_stock = 0 means "sin umbral configurado", so the product is not assessed.
  it("returns 'sin-umbral' when minStock is 0, regardless of stock", () => {
    expect(getStockStatus(0, 0)).toBe("sin-umbral")
    expect(getStockStatus(5, 0)).toBe("sin-umbral")
  })

  // ── TRIANGULATE: the three assessed states ───────────────────────────────
  it("returns 'critico' at or below the threshold", () => {
    expect(getStockStatus(5, 10)).toBe("critico")
    expect(getStockStatus(10, 10)).toBe("critico")
    expect(getStockStatus(0, 1)).toBe("critico")
  })

  it("returns 'bajo' just above the threshold (≤ minStock * 1.5)", () => {
    expect(getStockStatus(12, 10)).toBe("bajo")
    expect(getStockStatus(15, 10)).toBe("bajo")
  })

  it("returns 'ok' comfortably above the threshold", () => {
    expect(getStockStatus(20, 10)).toBe("ok")
  })

  it("treats a negative threshold as no threshold (defensive)", () => {
    expect(getStockStatus(0, -1)).toBe("sin-umbral")
  })
})

describe("isBelowThreshold", () => {
  it("is false when no threshold is configured (minStock 0)", () => {
    expect(isBelowThreshold(0, 0)).toBe(false)
    expect(isBelowThreshold(5, 0)).toBe(false)
  })

  it("is true at or below a configured threshold", () => {
    expect(isBelowThreshold(10, 10)).toBe(true)
    expect(isBelowThreshold(0, 10)).toBe(true)
  })

  it("is false above the threshold", () => {
    expect(isBelowThreshold(11, 10)).toBe(false)
  })

  // ── TRIANGULATE: stays in lock-step with getStockStatus === 'critico' ─────
  it("agrees with getStockStatus === 'critico'", () => {
    expect(isBelowThreshold(10, 10)).toBe(getStockStatus(10, 10) === "critico")
    expect(isBelowThreshold(5, 0)).toBe(getStockStatus(5, 0) === "critico")
  })
})
