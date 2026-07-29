/**
 * Regression guard for task 1.9 of `v4-visual-3d-refresh` Fase A: migrate
 * hardcoded color classes (emerald, amber, yellow, red scale utilities, and
 * their hex equivalents) to semantic tokens (success/warning/destructive) in
 * the highest-traffic `refresh-only`/`2d-motion` surfaces per
 * `frontend/docs/surface-matrix.md` — dashboard, ventas/listados, productos.
 *
 * `v4-frontend-01` (not implemented yet) owns the real anti-regression color
 * lint this task is meant to keep passing (design.md D3). Until that lint
 * exists, this is a lightweight static-source stand-in scoped to exactly the
 * files touched by this task: it reads each file's source and asserts the
 * specific hardcoded patterns that were present before the migration are
 * gone, guarding against a future revert. It intentionally does NOT flag
 * blue, purple, violet or sky utility classes (categorical/decorative colors
 * like "info", product type badges, or other KPI accents) — design.md D3's
 * mapping only defines targets for emerald/green to success, amber to
 * warning, red to destructive, slate/zinc to muted/foreground; there is no
 * defined semantic token for a generic "info"/categorical accent, so those
 * are explicitly out of scope (mapping them would mean inventing a token,
 * which is not this task's call).
 *
 * Cycle: RED (files still had the hardcoded classes before the migration) →
 * GREEN (migrated) → TRIANGULATE (14 files across 3 different surfaces,
 * each with its own distinct forbidden-pattern set) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

const FRONTEND_ROOT = resolve(__dirname, "../..")

const FILES_WITH_FORBIDDEN_PATTERNS: Array<{ file: string; forbidden: string[] }> = [
  {
    file: "app/(dashboard)/dashboard/page.tsx",
    forbidden: ["text-red-400", "text-yellow-400"],
  },
  {
    file: "components/dashboard/ai-alerts.tsx",
    forbidden: ["bg-red-500", "text-red-400", "bg-yellow-500", "text-yellow-400"],
  },
  {
    file: "components/dashboard/ai-summary-card.tsx",
    forbidden: ["text-red-400", "text-emerald-400"],
  },
  {
    file: "components/dashboard/kpi-card.tsx",
    forbidden: ["text-emerald-400", "text-red-400"],
  },
  {
    file: "components/dashboard/KpiSummaryBlock.tsx",
    forbidden: ["text-emerald-400", "text-amber-400", "text-red-400"],
  },
  {
    file: "components/dashboard/KpiSummaryCard.tsx",
    forbidden: ["#34D399", "#F87171", "#FBBF24"],
  },
  {
    file: "components/dashboard/NotificationBell.tsx",
    forbidden: ["bg-amber-500"],
  },
  {
    file: "components/dashboard/recent-activity.tsx",
    forbidden: ["bg-emerald-500", "text-emerald-400", "bg-red-500", "text-red-400"],
  },
  {
    file: "components/dashboard/TrialBanner.tsx",
    forbidden: [
      "bg-red-50",
      "border-red-200",
      "text-red-800",
      "text-red-500",
      "text-red-700",
      "text-red-600",
      "bg-amber-50",
      "border-amber-200",
      "text-amber-800",
      "text-amber-500",
      "text-amber-700",
      "text-amber-600",
    ],
  },
  {
    file: "components/ventas/sale-receipt-button.tsx",
    forbidden: ["text-emerald-500"],
  },
  {
    file: "components/ventas/sale-operations-list.tsx",
    forbidden: ["bg-emerald-500", "text-emerald-400", "border-emerald-500"],
  },
  {
    file: "app/(dashboard)/productos/page.tsx",
    forbidden: ["border-yellow-500", "bg-yellow-500", "text-yellow-400"],
  },
  {
    file: "components/products/product-import-dialog.tsx",
    forbidden: [
      "text-red-400",
      "text-yellow-400",
      "text-emerald-400",
      "bg-red-500",
      "bg-yellow-500",
      "border-emerald-500",
      "border-red-500",
      "border-yellow-500",
    ],
  },
  {
    file: "components/products/product-catalog.tsx",
    forbidden: ["text-emerald-400", "text-yellow-400", "text-red-400"],
  },
]

describe("task 1.9 — hardcoded color classes migrated to semantic tokens", () => {
  for (const { file, forbidden } of FILES_WITH_FORBIDDEN_PATTERNS) {
    it(`${file} no longer contains hardcoded emerald/amber/yellow/red classes with a defined semantic-token mapping`, () => {
      const source = readFileSync(resolve(FRONTEND_ROOT, file), "utf-8")
      for (const pattern of forbidden) {
        expect(source).not.toContain(pattern)
      }
    })
  }
})
