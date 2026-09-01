/**
 * qa-integral-modulos G4 (H4) — /reportes/sucursal estaba vacío SIEMPRE:
 * (1) resolvía el tenant desde session.user.user_metadata.account_id, que
 *     NADA escribe en ningún entorno → return [] silencioso, la RPC jamás se
 *     llamaba (la pantalla nunca funcionó para nadie desde C-06);
 * (2) sin rama de error visible, el 42702 de la RPC (arreglado en G4 backend)
 *     habría quedado tapado como "Sin datos".
 * Canon del tenant: account_members vía useAuth().user.accountId
 * (auth-context.tsx). El espejo sano rpc_cost_center_report NO se toca.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

const rpcMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: rpcMock,
    auth: {
      // Realista: ningún usuario tiene account_id en user_metadata (nada lo
      // escribe). El camino viejo que leía de acá devolvía [] en silencio.
      getSession: async () => ({
        data: { session: { user: { id: "user-1", user_metadata: { name: "QA" } } } },
      }),
    },
  }),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({
    limits: { hasBranchesModule: true, historyDays: 365 },
    isLoading: false,
  }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "acc-canon-1" } }),
}))

import SucursalReportPage from "@/app/(dashboard)/reportes/sucursal/page"

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <SucursalReportPage />
    </QueryClientProvider>,
  )
}

const ROWS = [
  {
    branch_id: "b-1",
    branch_name: "Casa Central",
    total_sales: 324850,
    total_expenses: 1158787,
    operation_count: 25,
  },
]

beforeEach(() => {
  rpcMock.mockReset()
})

describe("SucursalReportPage — tenant por el canon account_members + rama de error (G4/H4)", () => {
  it("pide rpc_branch_report con la cuenta resuelta por account_members (useAuth), no user_metadata", async () => {
    rpcMock.mockResolvedValue({ data: ROWS, error: null })
    renderPage()
    await waitFor(() => expect(rpcMock).toHaveBeenCalled())
    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_branch_report",
      expect.objectContaining({ p_account_id: "acc-canon-1" }),
    )
  })

  it("con datos, la tabla muestra la sucursal (no 'Sin datos')", async () => {
    rpcMock.mockResolvedValue({ data: ROWS, error: null })
    renderPage()
    expect(await screen.findByText("Casa Central")).toBeInTheDocument()
    expect(screen.queryByText(/sin datos para el período/i)).not.toBeInTheDocument()
  })

  it("un error de la RPC muestra la rama de error, distinguible de 'sin datos'", async () => {
    rpcMock.mockResolvedValue({
      data: null,
      error: { message: 'column reference "branch_id" is ambiguous' },
    })
    renderPage()
    expect(
      await screen.findByText(/no se pudo cargar el reporte/i),
    ).toBeInTheDocument()
    expect(screen.queryByText(/sin datos para el período/i)).not.toBeInTheDocument()
  })

  it("rango sin datos muestra 'Sin datos' y NO la rama de error", async () => {
    rpcMock.mockResolvedValue({ data: [], error: null })
    renderPage()
    expect(
      await screen.findByText(/sin datos para el período seleccionado/i),
    ).toBeInTheDocument()
    expect(screen.queryByText(/no se pudo cargar el reporte/i)).not.toBeInTheDocument()
  })
})
