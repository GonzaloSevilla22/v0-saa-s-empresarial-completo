/**
 * ExportacionesPage — /exportaciones (limpieza de hooks/use-toast, candidato
 * heredado de qa-integral-modulos G7/H7, ver CLAUDE.md §"Candidatos").
 *
 * Igual que ExportButton (ya migrado en export-button-sonner.test.tsx), esta
 * pantalla emitía sus 2 avisos de "Regenerar" por `@/hooks/use-toast`, cuyo
 * `<Toaster />` no está montado en ningún layout — invisibles para el
 * usuario. El único sistema de toast montado es `sonner` (app/layout.tsx).
 *
 * Invariantes bajo test:
 * - Regenerar con error: toast.error de sonner con la descripción del error.
 * - Regenerar con éxito: toast.success de sonner.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

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
  useAuth: () => ({ user: { id: "test-user-id", email: "test@example.com" } }),
}))

vi.mock("@/components/export/ExportButton", () => ({
  ExportButton: ({ exportType }: { exportType: string }) => (
    <button type="button">{`Exportar ${exportType}`}</button>
  ),
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

const getSessionMock = vi.hoisted(() =>
  vi.fn().mockResolvedValue({ data: { session: { access_token: "tok" } } }),
)
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getSession: getSessionMock } }),
}))

const invalidateQueries = vi.hoisted(() => vi.fn())
const EXPIRED_LOG = {
  id: "log-1",
  user_id: "test-user-id",
  org_id: null,
  export_type: "sales_csv",
  file_path: "sales.csv",
  signed_url: null,
  signed_url_expires_at: null,
  status: "generated",
  created_at: "2026-09-01T00:00:00Z",
}

vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries }),
  useQuery: () => ({ data: [EXPIRED_LOG], isLoading: false }),
}))

import ExportacionesPage from "@/app/(dashboard)/exportaciones/page"

beforeEach(() => {
  sonnerToast.mockClear()
  sonnerToast.success.mockClear()
  sonnerToast.error.mockClear()
  invalidateQueries.mockClear()
  triggerExportMock.mockReset()
  getSessionMock.mockResolvedValue({ data: { session: { access_token: "tok" } } })
})

describe("ExportacionesPage — Regenerar avisa por sonner (G7/H7)", () => {
  it("regeneración fallida: toast.error de sonner con la descripción", async () => {
    triggerExportMock.mockResolvedValue({ ok: false, error: "Edge Function 503" })
    const user = userEvent.setup()
    render(<ExportacionesPage />)

    await user.click(screen.getByRole("button", { name: /regenerar/i }))

    await waitFor(() =>
      expect(sonnerToast.error).toHaveBeenCalledWith(
        "No se pudo regenerar",
        expect.objectContaining({ description: "Edge Function 503" }),
      ),
    )
  })

  it("regeneración exitosa: toast.success de sonner", async () => {
    triggerExportMock.mockResolvedValue({ ok: true, signedUrl: null })
    const user = userEvent.setup()
    render(<ExportacionesPage />)

    await user.click(screen.getByRole("button", { name: /regenerar/i }))

    await waitFor(() =>
      expect(sonnerToast.success).toHaveBeenCalledWith("Exportación regenerada"),
    )
    expect(invalidateQueries).toHaveBeenCalledWith({
      queryKey: ["exportLogs", "test-user-id"],
    })
  })
})
