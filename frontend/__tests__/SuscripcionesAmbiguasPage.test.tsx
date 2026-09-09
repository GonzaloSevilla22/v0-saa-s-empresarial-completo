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
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type {
  AccountSearchResult,
  AmbiguousSubscription,
  RecentSubscription,
} from "@/hooks/data/use-ambiguous-subscriptions"

const { toastSuccessMock, toastErrorMock } = vi.hoisted(() => ({
  toastSuccessMock: vi.fn(),
  toastErrorMock: vi.fn(),
}))

vi.mock("sonner", () => ({
  toast: { success: toastSuccessMock, error: toastErrorMock },
}))

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

const RECENT_1: RecentSubscription = {
  id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
  plan: "pro",
  status: "authorized",
  accountId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  accountName: "Buyer Test",
  nextPaymentDate: "2026-09-01T00:00:00.000Z",
  lastPaymentStatus: "approved",
  retryState: "none",
  updatedAt: "2026-08-01T12:00:00.000Z",
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
const discardSubscriptionMock = vi.fn()
const replaySubscriptionChargesMock = vi.fn()
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
const mockRecentState: {
  data: RecentSubscription[] | undefined
  isLoading: boolean
  isError: boolean
} = {
  data: [RECENT_1],
  isLoading: false,
  isError: false,
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
    discardSubscription: discardSubscriptionMock,
    discardMutation: { isPending: false },
  }),
  // useAccountSearch no se ejecuta en esta suite: AccountSearchCombobox
  // (su único caller) está mockeado más arriba — se exporta igual para que
  // cualquier import type-only del módulo real no rompa la resolución.
  useAccountSearch: () => ({ data: [], isFetching: false, isError: false }),
  useRecentSubscriptions: () => ({
    data: mockRecentState.data,
    isLoading: mockRecentState.isLoading,
    isError: mockRecentState.isError,
    error: null,
    refetch: vi.fn(),
    replaySubscriptionCharges: replaySubscriptionChargesMock,
    replayMutation: { isPending: false },
  }),
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
  mockRecentState.data = [RECENT_1]
  mockRecentState.isLoading = false
  mockRecentState.isError = false
  resolveSubscriptionMock.mockReset()
  discardSubscriptionMock.mockReset()
  replaySubscriptionChargesMock.mockReset()
  toastSuccessMock.mockReset()
  toastErrorMock.mockReset()
  // jsdom no implementa navegación real — silenciar el "Not implemented" y
  // permitir asignar window.location.href sin que la suite aborte.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  delete (window as any).location
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ;(window as any).location = { href: "" }
})

// qa-integral-modulos (revisión post-apply): esta función es ASÍNCRONA — el
// import dinámico de la página arrastra Table/Badge/Button/lucide y el módulo
// del hook. Los tests la llamaban SIN await, así que el import + el render +
// el efecto de gating tenían que entrar enteros en el timeout de 1 s del
// waitFor/findBy siguiente; en una máquina cargada el PRIMER test (el único
// que paga el costo del import, después vitest cachea el módulo) se pasaba de
// 1 s y la suite se ponía roja sin ninguna causa real. Es una carrera de
// verdad, no ruido: se cierra esperando el render antes de medir.
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
    await renderPage()

    await waitFor(() => expect(window.location.href).toBe("/dashboard"))
    expect(screen.queryByText(/suscripciones ambiguas/i)).not.toBeInTheDocument()
  })

  it("§1 TRIANGULATE: an unauthenticated user is redirected to login without rendering", async () => {
    authUser = null
    await renderPage()

    await waitFor(() => expect(window.location.href).toBe("/auth/login"))
    expect(screen.queryByText(/suscripciones ambiguas/i)).not.toBeInTheDocument()
  })

  it("§2 GREEN: an admin sees the page content", async () => {
    await renderPage()

    expect(await screen.findByRole("heading", { name: /suscripciones ambiguas/i })).toBeInTheDocument()
  })
})

describe("SuscripcionesAmbiguasPage — queue list", () => {
  it("§3 GREEN: renders one row per ambiguous subscription with plan/amount/reason", async () => {
    await renderPage()

    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    // La sección "Suscripciones recientes" (residuo (c)) también renderiza
    // "Pro" (RECENT_1.plan) — se escopea a la tabla de la cola de ambiguos
    // (la primera del documento) para no colisionar.
    const [queueTable] = screen.getAllByRole("table")
    expect(within(queueTable).getByText("Pro")).toBeInTheDocument()
    expect(within(queueTable).getByText("Inicial")).toBeInTheDocument()
    expect(within(queueTable).getByText(/\$\s?69\.900,00/)).toBeInTheDocument()
    expect(within(queueTable).getByText("Sin cuenta candidata")).toBeInTheDocument()
    expect(within(queueTable).getByText("Varias cuentas candidatas")).toBeInTheDocument()
    expect(within(queueTable).getByText("mp-preapproval-XYZ")).toBeInTheDocument()
  })

  it("§4 TRIANGULATE: shows a clear empty state when the queue has no rows", async () => {
    mockHookState.data = []
    await renderPage()

    expect(await screen.findByText(/no hay suscripciones pendientes de revisión/i)).toBeInTheDocument()
    // La tabla de la cola de ambiguos desaparece — la de "Suscripciones
    // recientes" (residuo (c)) sigue ahí, así que no alcanza con "ninguna
    // tabla en la página"; se verifica por su columna distintiva.
    expect(screen.queryByRole("columnheader", { name: /motivo/i })).not.toBeInTheDocument()
  })

  it("§4b: shows a loading spinner while the query is in flight", async () => {
    mockHookState.isLoading = true
    mockHookState.data = undefined
    await renderPage()

    expect(await screen.findByText(/cargando cola/i)).toBeInTheDocument()
  })

  it("§4c: surfaces a fetch error", async () => {
    mockHookState.isError = true
    mockHookState.error = new Error("No se pudo cargar la cola de suscripciones ambiguas.")
    await renderPage()

    expect(await screen.findByRole("alert")).toHaveTextContent(/no se pudo cargar la cola/i)
  })
})

describe("SuscripcionesAmbiguasPage — resolve flow", () => {
  it("§5 RED: 'Asignar' is disabled until an account is selected for that row", async () => {
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    expect(assignButtons[0]).toBeDisabled()
  })

  it("§5 GREEN: selecting an account then clicking Asignar calls resolveSubscription with the row's ids", async () => {
    resolveSubscriptionMock.mockResolvedValueOnce({ ok: true })
    const user = userEvent.setup()
    await renderPage()
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
    await renderPage()
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
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    const [firstMockSelect] = screen.getAllByText("mock-select-account")
    await user.click(firstMockSelect)
    const assignButtons = screen.getAllByRole("button", { name: /asignar suscripción/i })
    await user.click(assignButtons[0])

    expect(await screen.findByText(/no hay una suscripción ambigua con ese id/i)).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()
  })
})

// ── Descartar (residuo (b)) ─────────────────────────────────────────────────

describe("SuscripcionesAmbiguasPage — discard flow", () => {
  it("§8 RED: clicking 'Descartar' on a row opens a confirmation dialog", async () => {
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    await user.click(
      screen.getByRole("button", { name: `Descartar suscripción ${AMBIGUOUS_1.preapprovalId}` }),
    )

    expect(
      await screen.findByRole("heading", { name: /descartar esta suscripción ambigua/i }),
    ).toBeInTheDocument()
  })

  it("§8 GREEN: confirming calls discardSubscription with the row id and the typed reason, and shows a success toast", async () => {
    discardSubscriptionMock.mockResolvedValueOnce({ id: AMBIGUOUS_1.id, status: "cancelled" })
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    await user.click(
      screen.getByRole("button", { name: `Descartar suscripción ${AMBIGUOUS_1.preapprovalId}` }),
    )
    await user.type(await screen.findByLabelText(/motivo \(opcional\)/i), "cancelado en MP")
    await user.click(screen.getByRole("button", { name: "Descartar" }))

    await waitFor(() => {
      expect(discardSubscriptionMock).toHaveBeenCalledWith({
        subscriptionId: AMBIGUOUS_1.id,
        reason: "cancelado en MP",
      })
    })
    await waitFor(() => expect(toastSuccessMock).toHaveBeenCalled())
  })

  it("§9 TRIANGULATE: leaving the reason empty sends undefined instead of an empty string", async () => {
    discardSubscriptionMock.mockResolvedValueOnce({ id: AMBIGUOUS_1.id, status: "cancelled" })
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    await user.click(
      screen.getByRole("button", { name: `Descartar suscripción ${AMBIGUOUS_1.preapprovalId}` }),
    )
    await screen.findByRole("heading", { name: /descartar esta suscripción ambigua/i })
    await user.click(screen.getByRole("button", { name: "Descartar" }))

    await waitFor(() => {
      expect(discardSubscriptionMock).toHaveBeenCalledWith({
        subscriptionId: AMBIGUOUS_1.id,
        reason: undefined,
      })
    })
  })

  it("§9 TRIANGULATE: a failed discard shows an error toast", async () => {
    discardSubscriptionMock.mockRejectedValueOnce(new Error("Ya fue resuelta"))
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones ambiguas/i })

    await user.click(
      screen.getByRole("button", { name: `Descartar suscripción ${AMBIGUOUS_1.preapprovalId}` }),
    )
    await screen.findByRole("heading", { name: /descartar esta suscripción ambigua/i })
    await user.click(screen.getByRole("button", { name: "Descartar" }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith("Ya fue resuelta"))
  })
})

// ── "Suscripciones recientes" (residuo (c)) ─────────────────────────────────

describe("SuscripcionesAmbiguasPage — recent subscriptions section", () => {
  it("§10 GREEN: renders a row per recent subscription with plan/status/account", async () => {
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones recientes/i })

    expect(screen.getByText("Buyer Test")).toBeInTheDocument()
    expect(screen.getByText("Activa")).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: /replicar cuotas de la suscripción pro de buyer test/i }),
    ).toBeInTheDocument()
  })

  it("§10 TRIANGULATE: shows an empty state when there are no recent subscriptions", async () => {
    mockRecentState.data = []
    await renderPage()

    expect(await screen.findByText(/no hay suscripciones recientes todavía/i)).toBeInTheDocument()
  })

  it("§10b: shows a loading state while the recent-subscriptions query is in flight", async () => {
    mockRecentState.isLoading = true
    mockRecentState.data = undefined
    await renderPage()

    expect(await screen.findByText(/cargando suscripciones recientes/i)).toBeInTheDocument()
  })

  it("§10c: surfaces a fetch error for the recent-subscriptions section", async () => {
    mockRecentState.isError = true
    await renderPage()

    expect(
      await screen.findByText(/no se pudieron cargar las suscripciones recientes/i),
    ).toBeInTheDocument()
  })

  it("§11 GREEN: confirming 'Replicar' calls replaySubscriptionCharges with the row id and shows a summary toast", async () => {
    replaySubscriptionChargesMock.mockResolvedValueOnce({
      ok: true, applied: ["7031580844"], alreadyApplied: [],
    })
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones recientes/i })

    await user.click(
      screen.getByRole("button", { name: /replicar cuotas de la suscripción pro de buyer test/i }),
    )
    await user.click(await screen.findByRole("button", { name: "Replicar" }))

    await waitFor(() => {
      expect(replaySubscriptionChargesMock).toHaveBeenCalledWith(RECENT_1.id)
    })
    await waitFor(() => {
      expect(toastSuccessMock).toHaveBeenCalledWith(expect.stringMatching(/1 cuota/i))
    })
  })

  it("§11 TRIANGULATE: a failed replay shows an error toast", async () => {
    replaySubscriptionChargesMock.mockRejectedValueOnce(new Error("Error al consultar MercadoPago"))
    const user = userEvent.setup()
    await renderPage()
    await screen.findByRole("heading", { name: /suscripciones recientes/i })

    await user.click(
      screen.getByRole("button", { name: /replicar cuotas de la suscripción pro de buyer test/i }),
    )
    await user.click(await screen.findByRole("button", { name: "Replicar" }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith("Error al consultar MercadoPago"))
  })
})
