/**
 * mp-real-subscriptions follow-up (task 8.8) — TDD tests for
 * /admin/pagos/ambiguas (SuscripcionesAmbiguasPage).
 *
 * Cycle: RED → GREEN → TRIANGULATE. Casos cubiertos (brief del follow-up):
 *   lista con casos / vacía / resolve OK refresca / resolve falla muestra
 *   error / no-admin no ve nada.
 *
 * AccountSearchCombobox se mockea (tiene su propia suite en
 * AccountSearchCombobox.test.tsx) — acá se testea la lógica de la página:
 * gating, lista, resolve.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { AccountSearchResult, AmbiguousSubscription } from "@/hooks/data/use-ambiguous-subscriptions"

// ── Mocks ─────────────────────────────────────────────────────────────────

const FAKE_ACCOUNT: AccountSearchResult = {
  accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  ownerEmail: "buyer@example.com",
  ownerName: "Buyer Test",
  billingPlan: "pro",
}

const AMBIGUOUS_1: AmbiguousSubscription = {
  id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  preapprovalId: "mp-preapproval-XYZ",
  preapprovalPlanId: "mp-plan-pro",
  plan: "pro",
  ambiguousReason: "no_match",
  amount: 69900,
  currency: "ARS",
  createdAt: "2026-08-01T12:00:00.000Z",
}

const AMBIGUOUS_2: AmbiguousSubscription = {
  id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
  preapprovalId: "mp-preapproval-ABC",
  preapprovalPlanId: "mp-plan-inicial",
  plan: "inicial",
  ambiguousReason: "multiple_match",
  amount: 9900,
  currency: "ARS",
  createdAt: "2026-08-01T08:00:00.000Z",
}

let profileRole: string | null = "admin"
let authUser: { id: string } | null = { id: "user-1" }

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getUser: vi.fn(async () => ({ data: { user: authUser } })),
    },
    from: vi.fn(() => ({
      select: vi.fn(() => ({
        eq: vi.fn(() => ({
          single: vi.fn(async () => ({ data: profileRole ? { role: profileRole } : null })),
        })),
      })),
    })),
  }),
}))

vi.mock("@/components/billing/AccountSearchCombobox", () => ({
  AccountSearchCombobox: ({
    value,
    onSelect,
    disabled,
    id,
  }: {
    value: AccountSearchResult | null
    onSelect: (a: AccountSearchResult) => void
    disabled?: boolean
    id?: string
  }) => (
    <button
      type="button"
      id={id}
      disabled={disabled}
      onClick={() => onSelect(FAKE_ACCOUNT)}
    >
      {value ? `Seleccionado: ${value.ownerEmail}` : "mock-select-account"}
    </button>
  ),
}))

const resolveSubscriptionMock = vi.fn()
const mockHookState: {
  data: AmbiguousSubscription[] | undefined
  isLoading: boolean
  isError: boolean
  error: Error | null
} = {
  data: [AMBIGUOUS_1, AMBIGUOUS_2],
  isLoading: false,
  isError: false,
  error: null,
}

vi.mock("@/hooks/data/use-ambiguous-subscriptions", () => ({
  useAmbiguousSubscriptions: () => ({
    data: mockHookState.data,
    isLoading: mockHookState.isLoading,
    isError: mockHookState.isError,
    error: mockHookState.error,
    refetch: vi.fn(),
    resolveSubscription: resolveSubscriptionMock,
    resolveMutation: { isPending: false },
  }),
  // useAccountSearch no se ejecuta en esta suite: AccountSearchCombobox
  // (su único caller) está mockeado más arriba — se exporta igual para que
  // cualquier import type-only del módulo real no rompa la resolución.
  useAccountSearch: () => ({ data: [], isFetching: false, isError: false }),
}))

// ── Setup ─────────────────────────────────────────────────────────────────

beforeEach(() => {
  vi.clearAllMocks()
  profileRole = "admin"
  authUser = { id: "user-1" }
  mockHookState.data = [AMBIGUOUS_1, AMBIGUOUS_2]
  mockHookState.isLoading = false
  mockHookState.isError = false
  mockHookState.error = null
  resolveSubscriptionMock.mockReset()
  // jsdom no implementa navegación real — silenciar el "Not implemented" y
  // permitir asignar window.location.href sin que la suite aborte.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  delete (window as any).location
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ;(window as any).location = { href: "" }
})

async function renderPage() {
  const { default: SuscripcionesAmbiguasPage } = await import(
    "@/app/(dashboard)/admin/pagos/ambiguas/page"
  )
  return render(<SuscripcionesAmbiguasPage />)
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("SuscripcionesAmbiguasPage — gating", () => {
  it("§1 RED: a non-admin sees nothing and gets redirected away", async () => {
    profileRole = "user"
    renderPage()

    await waitFor(() => expect(window.location.href).toBe("/dashboard"))
    expect(screen.queryByText(/suscripciones ambiguas/i)).not.toBeInTheDocument()
  })

  it("§1 TRIANGULATE: an unauthenticated user is redirected to login without rendering", async () => {
    authUser = null
    renderPage()

    await waitFor(() => expect(window.location.href).toBe("/auth/login"))
    expect(screen.queryByText(/suscripciones ambiguas/i)).not.toBeInTheDocument()
  })

  it("§2 GREEN: an admin sees the page content", async () => {
    renderPage()

    expect(await screen.findByRole("heading", { name: /suscripciones ambiguas/i })).toBeInTheDocument()
  })
})

describe("SuscripcionesAmbiguasPage — queue list", () => {
  it("§3 GREEN: renders one row per ambiguous subscription with plan/amount/reason", async () => {
    renderPage()

    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    expect(screen.getByText("Pro")).toBeInTheDocument()
    expect(screen.getByText("Inicial")).toBeInTheDocument()
    expect(screen.getByText(/\$\s?69\.900,00/)).toBeInTheDocument()
    expect(screen.getByText("Sin cuenta candidata")).toBeInTheDocument()
    expect(screen.getByText("Varias cuentas candidatas")).toBeInTheDocument()
    expect(screen.getByText("mp-preapproval-XYZ")).toBeInTheDocument()
  })

  it("§4 TRIANGULATE: shows a clear empty state when the queue has no rows", async () => {
    mockHookState.data = []
    renderPage()

    expect(await screen.findByText(/no hay suscripciones pendientes de revisión/i)).toBeInTheDocument()
    expect(screen.queryByRole("table")).not.toBeInTheDocument()
  })

  it("§4b: shows a loading spinner while the query is in flight", async () => {
    mockHookState.isLoading = true
    mockHookState.data = undefined
    renderPage()

    expect(await screen.findByText(/cargando cola/i)).toBeInTheDocument()
  })

  it("§4c: surfaces a fetch error", async () => {
    mockHookState.isError = true
    mockHookState.error = new Error("No se pudo cargar la cola de suscripciones ambiguas.")
    renderPage()

    expect(await screen.findByRole("alert")).toHaveTextContent(/no se pudo cargar la cola/i)
  })
})

describe("SuscripcionesAmbiguasPage — resolve flow", () => {
  it("§5 RED: 'Asignar' is disabled until an account is selected for that row", async () => {
    renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    expect(assignButtons[0]).toBeDisabled()
  })

  it("§5 GREEN: selecting an account then clicking Asignar calls resolveSubscription with the row's ids", async () => {
    resolveSubscriptionMock.mockResolvedValueOnce({ ok: true })
    const user = userEvent.setup()
    renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const [firstMockSelect] = screen.getAllByText("mock-select-account")
    await user.click(firstMockSelect)

    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    await user.click(assignButtons[0])

    await waitFor(() => {
      expect(resolveSubscriptionMock).toHaveBeenCalledWith({
        subscriptionId: AMBIGUOUS_1.id,
        accountId: FAKE_ACCOUNT.accountId,
      })
    })
  })

  it("§6 GREEN: a successful resolve shows a success notice", async () => {
    resolveSubscriptionMock.mockResolvedValueOnce({ ok: true })
    const user = userEvent.setup()
    renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const [firstMockSelect] = screen.getAllByText("mock-select-account")
    await user.click(firstMockSelect)
    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    await user.click(assignButtons[0])

    expect(await screen.findByRole("status")).toHaveTextContent(/asignada a buyer@example\.com/i)
  })

  it("§7 TRIANGULATE: a failed resolve shows an inline row error instead of a success notice", async () => {
    resolveSubscriptionMock.mockRejectedValueOnce(new Error("No hay una suscripción ambigua con ese id"))
    const user = userEvent.setup()
    renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const [firstMockSelect] = screen.getAllByText("mock-select-account")
    await user.click(firstMockSelect)
    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    await user.click(assignButtons[0])

    expect(await screen.findByText(/no hay una suscripción ambigua con ese id/i)).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })
})
