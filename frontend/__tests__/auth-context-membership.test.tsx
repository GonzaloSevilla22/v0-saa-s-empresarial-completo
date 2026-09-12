/**
 * Tests de auth-context — resolución de la membresía activa (MAJOR-1,
 * v3-rbac-multirole Parte C, ronda 3 adversarial).
 *
 * `.single()` sobre `account_members` devolvía 406/PGRST116 en cuanto el
 * usuario tenía 2+ membresías (todo miembro invitado a otra cuenta, porque
 * `handle_new_user` ya le da una propia) -- `membership` quedaba `null`,
 * `accountId` caía a `""` y cualquier hook `enabled: !!accountId` se
 * apagaba en silencio. El fix reemplaza `.single()` por
 * `.order("created_at", {ascending:true}).order("id", {ascending:true}).limit(1).maybeSingle()`,
 * el MISMO criterio determinístico que usa `backend/core/deps.py::get_account_id`
 * y el hook de auth (20260827000001): la membresía más antigua por
 * `created_at`, desempatada por `id`.
 *
 * El fake `.from("account_members")` de este archivo implementa el mismo
 * contrato de PostgREST que ejercita el código real (`eq/order/order/limit/
 * maybeSingle`), aplicando el ORDER BY compuesto sobre los datos de fixture
 * -- así los 3 escenarios pedidos por la revisión (1 membresía, 2 con
 * desempate, 0 membresías) corren contra el mismo camino que produce en
 * producción, sin mockear el criterio por fuera de la cadena real.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/supabase/client, next/navigation
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { AuthProvider, useAuth } from "@/contexts/auth-context"

// ── Fixture de fila de account_members ──────────────────────────────────────
interface MembershipFixtureRow {
  id: string
  account_id: string
  role: string
  created_at: string
  accounts: {
    billing_plan: string
    billing_status: string
    trial_plan: string | null
    trial_started_at: string | null
    trial_expires_at: string | null
    billing_exempt: boolean | null
  }
}

function membershipRow(overrides: Partial<MembershipFixtureRow> & { id: string; account_id: string }): MembershipFixtureRow {
  return {
    role: "owner",
    created_at: "2026-01-01T00:00:00.000Z",
    accounts: {
      billing_plan: "gratis",
      billing_status: "trialing",
      trial_plan: null,
      trial_started_at: null,
      trial_expires_at: null,
      billing_exempt: false,
    },
    ...overrides,
  }
}

// ── Fake de la cadena PostgREST para account_members ────────────────────────
// Implementa eq/order/order/limit/maybeSingle contra el array de fixture --
// el ORDER BY es compuesto (created_at, luego id), igual que la cadena real
// que usa auth-context.tsx y la migración del hook de auth.
function buildAccountMembersChain(rows: MembershipFixtureRow[]) {
  const orderKeys: { col: "created_at" | "id"; ascending: boolean }[] = []
  let limitN: number | null = null

  const resolve = () => {
    const sorted = [...rows].sort((a, b) => {
      for (const { col, ascending } of orderKeys) {
        const av = a[col]
        const bv = b[col]
        const cmp = av < bv ? -1 : av > bv ? 1 : 0
        if (cmp !== 0) return ascending ? cmp : -cmp
      }
      return 0
    })
    return limitN !== null ? sorted.slice(0, limitN) : sorted
  }

  const chain = {
    eq: () => chain,
    order: (col: "created_at" | "id", opts: { ascending: boolean }) => {
      orderKeys.push({ col, ascending: opts.ascending })
      return chain
    },
    limit: (n: number) => {
      limitN = n
      return chain
    },
    maybeSingle: () => Promise.resolve({ data: resolve()[0] ?? null, error: null }),
  }
  return chain
}

// ── Supabase client mock ─────────────────────────────────────────────────────
let membershipRows: MembershipFixtureRow[] = []
const getUserMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: {
      getUser: () => getUserMock(),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe: vi.fn() } } }),
    },
    from: (table: string) => {
      if (table === "profiles") {
        return { select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: null, error: null }) }) }) }
      }
      if (table === "account_members") {
        return { select: () => ({ eq: () => buildAccountMembersChain(membershipRows) }) }
      }
      throw new Error(`Tabla no mockeada en este test: ${table}`)
    },
  }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
}))

// ── Test consumer ────────────────────────────────────────────────────────────
function Consumer() {
  const { user } = useAuth()
  return (
    <div>
      <span data-testid="account-id">{user?.accountId ?? ""}</span>
      <span data-testid="account-role">{user?.accountRole ?? ""}</span>
    </div>
  )
}

function renderWithAuth() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Consumer />
      </AuthProvider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  membershipRows = []
  getUserMock.mockReset().mockResolvedValue({
    data: { user: { id: "user-1", email: "u@test.com", user_metadata: {} } },
    error: null,
  })
})

describe("auth-context — resolución de membresía activa (MAJOR-1)", () => {
  it("1 membresía: la resuelve sin ambigüedad", async () => {
    membershipRows = [membershipRow({ id: "m-1", account_id: "acc-1", role: "owner" })]

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-1"))
    expect(screen.getByTestId("account-role").textContent).toBe("owner")
  })

  it("(triangulate) 2 membresías: elige la más antigua por created_at", async () => {
    membershipRows = [
      membershipRow({ id: "m-newer", account_id: "acc-newer", role: "admin", created_at: "2026-06-01T00:00:00.000Z" }),
      membershipRow({ id: "m-older", account_id: "acc-older", role: "owner", created_at: "2026-01-01T00:00:00.000Z" }),
    ]

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-older"))
    expect(screen.getByTestId("account-role").textContent).toBe("owner")
  })

  it("(triangulate) 2 membresías con el mismo created_at: desempata por id", async () => {
    const tie = "2026-03-15T00:00:00.000Z"
    membershipRows = [
      membershipRow({ id: "m-zzz", account_id: "acc-zzz", role: "member", created_at: tie }),
      membershipRow({ id: "m-aaa", account_id: "acc-aaa", role: "admin", created_at: tie }),
    ]

    renderWithAuth()

    // "m-aaa" < "m-zzz" lexicográficamente -> gana el desempate por id.
    await waitFor(() => expect(screen.getByTestId("account-id").textContent).toBe("acc-aaa"))
    expect(screen.getByTestId("account-role").textContent).toBe("admin")
  })

  it("0 membresías: resuelve null sin lanzar (accountId cae al fallback \"\")", async () => {
    membershipRows = []

    renderWithAuth()

    await waitFor(() => expect(screen.getByTestId("account-role").textContent).toBe("owner"))
    expect(screen.getByTestId("account-id").textContent).toBe("")
  })
})
