/**
 * TDD tests for holdsOwnStock — the single predicate that decides whether a
 * product is a real inventory line (counted / adjusted / reordered) or a
 * catalogue construct that should not appear in the stock/reposition views.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect } from "vitest"
import { holdsOwnStock } from "@/lib/product-stock"

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
