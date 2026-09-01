/**
 * qa-integral-modulos G7 (H7) — los 5 toasts de ExportButton eran invisibles:
 * emitía por `@/hooks/use-toast` (shadcn), cuyo `<Toaster />` no está montado
 * en NINGÚN layout de la app. El único sistema de toast montado es `sonner`
 * (app/layout.tsx), así que "el usuario ve el aviso" ≡ "se emite por sonner".
 * D5: migrar las 5 ramas a sonner, NO montar un segundo Toaster.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import { TooltipProvider } from "@/components/ui/tooltip"

function withProviders(ui: React.ReactElement) {
  return render(<TooltipProvider>{ui}</TooltipProvider>)
}

// ─── Mocks ────────────────────────────────────────────────────────────────────

const sonnerToast = vi.hoisted(() => {
  const fn = vi.fn() as ReturnType<typeof vi.fn> & {
    success: ReturnType<typeof vi.fn>
    error: ReturnType<typeof vi.fn>
  }
  fn.success = vi.fn()
  fn.error = vi.fn()
  return fn
})
vi.mock("sonner", () => ({ toast: sonnerToast }))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: { id: "test-user-id", email: "test@example.com" },
    isAdmin: false,
  }),
}))

const invalidateQueries = vi.hoisted(() => vi.fn())
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries }),
}))

const getSessionMock = vi.hoisted(() =>
  vi.fn().mockResolvedValue({ data: { session: { access_token: "tok" } } }),
)
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getSession: getSessionMock } }),
}))

const triggerExportMock = vi.hoisted(() => vi.fn())
vi.mock("@/hooks/auth/use-export-usage", () => ({
  useExportUsage: () => ({
    exportsUsed: 0,
    exportsRemaining: 3,
    exportsLimit: 3,
    isLoading: false,
    canExport: () => ({ allowed: true, reason: null }),
  }),
  triggerExport: triggerExportMock,
}))

async function renderButton() {
  const { ExportButton } = await import("@/components/export/ExportButton")
  withProviders(<ExportButton exportType="sales_csv" />)
  return userEvent.setup()
}

async function clickExport(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", { name: /exportar/i }))
}

beforeEach(() => {
  sonnerToast.mockClear()
  sonnerToast.success.mockClear()
  sonnerToast.error.mockClear()
  invalidateQueries.mockClear()
  triggerExportMock.mockReset()
  getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok" } } })
})

describe("ExportButton — todas las ramas avisan por sonner (G7/H7)", () => {
  it("Edge Function caída: el usuario ve un toast de error", async () => {
    triggerExportMock.mockResolvedValue({ ok: false, error: "Edge Function 503" })
    const user = await renderButton()
    await clickExport(user)

    await waitFor(() =>
      expect(sonnerToast.error).toHaveBeenCalledWith(
        "Error al exportar",
        expect.objectContaining({ description: "Edge Function 503" }),
      ),
    )
  })

  it("cuota agotada: toast visible + refresco del contador", async () => {
    triggerExportMock.mockResolvedValue({ ok: false, error: "quota_exceeded" })
    const user = await renderButton()
    await clickExport(user)

    await waitFor(() =>
      expect(sonnerToast.error).toHaveBeenCalledWith(
        "Cuota agotada",
        expect.objectContaining({
          description: "Ya usaste todas tus exportaciones del mes.",
        }),
      ),
    )
    expect(invalidateQueries).toHaveBeenCalledWith({
      queryKey: ["exportUsage", "test-user-id"],
    })
  })

  it("éxito: toast de 'Exportación lista' visible", async () => {
    triggerExportMock.mockResolvedValue({ ok: true, signedUrl: null })
    const user = await renderButton()
    await clickExport(user)

    await waitFor(() =>
      expect(sonnerToast.success).toHaveBeenCalledWith(
        "Exportación lista",
        expect.objectContaining({
          description: "El archivo se descargó correctamente.",
        }),
      ),
    )
  })

  it("sin sesión: toast de 'No autenticado'", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } })
    const user = await renderButton()
    await clickExport(user)

    await waitFor(() => expect(sonnerToast.error).toHaveBeenCalledWith("No autenticado"))
    expect(triggerExportMock).not.toHaveBeenCalled()
  })

  it("excepción inesperada: toast de error genérico", async () => {
    triggerExportMock.mockRejectedValue(new Error("network down"))
    const user = await renderButton()
    await clickExport(user)

    await waitFor(() =>
      expect(sonnerToast.error).toHaveBeenCalledWith("Error inesperado al exportar"),
    )
  })
})
