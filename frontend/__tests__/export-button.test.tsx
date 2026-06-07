/**
 * Unit tests for ExportButton component (C-14 export-module, task 7.1-7.2)
 *
 * Verifies that:
 *   7.1 Plan 'gratis' renders an upgrade CTA (Link to /planes) instead of a download button
 *   7.2 Quota exhausted (exportsRemaining = 0) disables the button
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { TooltipProvider } from "@/components/ui/tooltip"

function withProviders(ui: React.ReactElement) {
  return render(<TooltipProvider>{ui}</TooltipProvider>)
}

// ─── Mocks ────────────────────────────────────────────────────────────────────

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: { id: "test-user-id", email: "test@example.com" },
    isAdmin: false,
  }),
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}))

vi.mock("@/hooks/use-toast", () => ({
  toast: vi.fn(),
}))

vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: { getSession: vi.fn().mockResolvedValue({ data: { session: { access_token: "tok" } } }) },
  }),
}))

// Shared mock state for useExportUsage — overridden per test
type ExportDenyReason = "plan_gratis" | "quota_exceeded" | null

const mockExportUsageState = {
  exportsUsed: 0,
  exportsRemaining: 3,
  exportsLimit: 3,
  isLoading: false,
  canExport: (): { allowed: boolean; reason: ExportDenyReason } => ({ allowed: true, reason: null }),
}

vi.mock("@/hooks/auth/use-export-usage", () => ({
  useExportUsage: () => mockExportUsageState,
  triggerExport: vi.fn(),
}))

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("ExportButton", () => {
  beforeEach(() => {
    // Reset to valid state
    mockExportUsageState.exportsUsed = 0
    mockExportUsageState.exportsRemaining = 3
    mockExportUsageState.exportsLimit = 3
    mockExportUsageState.isLoading = false
    mockExportUsageState.canExport = (): { allowed: boolean; reason: ExportDenyReason } => ({ allowed: true, reason: null })
  })

  it("7.1 — renders upgrade link (not download button) when plan is gratis (limit=0)", async () => {
    mockExportUsageState.exportsLimit = 0
    mockExportUsageState.exportsRemaining = 0
    mockExportUsageState.canExport = (): { allowed: boolean; reason: ExportDenyReason } => ({ allowed: false, reason: "plan_gratis" })

    const { ExportButton } = await import("@/components/export/ExportButton")

    withProviders(<ExportButton exportType="sales_csv" />)

    // Should render a Link to /planes (upgrade CTA), not a button that calls the EF
    const link = screen.getByRole("link")
    expect(link).toHaveAttribute("href", "/planes")

    // Should NOT have a download button
    expect(screen.queryByRole("button", { name: /exportar ventas/i })).not.toBeInTheDocument()
  })

  it("7.2 — disables button when quota is exhausted", async () => {
    mockExportUsageState.exportsUsed = 3
    mockExportUsageState.exportsRemaining = 0
    mockExportUsageState.exportsLimit = 3
    mockExportUsageState.canExport = (): { allowed: boolean; reason: ExportDenyReason } => ({ allowed: false, reason: "quota_exceeded" })

    const { ExportButton } = await import("@/components/export/ExportButton")

    withProviders(<ExportButton exportType="sales_csv" />)

    const button = screen.getByRole("button")
    expect(button).toBeDisabled()
    // Shows 0 remaining
    expect(screen.getByText(/0 restante/i)).toBeInTheDocument()
  })

  it("7.2b — shows remaining count in enabled state", async () => {
    mockExportUsageState.exportsUsed = 1
    mockExportUsageState.exportsRemaining = 2
    mockExportUsageState.exportsLimit = 3
    mockExportUsageState.canExport = (): { allowed: boolean; reason: ExportDenyReason } => ({ allowed: true, reason: null })

    const { ExportButton } = await import("@/components/export/ExportButton")

    withProviders(<ExportButton exportType="purchases_csv" />)

    const button = screen.getByRole("button")
    expect(button).toBeEnabled()
    expect(screen.getByText(/2 restante/i)).toBeInTheDocument()
  })
})
