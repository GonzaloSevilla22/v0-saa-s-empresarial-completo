import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"

// tablero-menu-pulido (P4): la lista del Equipo mostraba `profiles.email ?? user_id`,
// pero `public.profiles` no tiene `email` (vive en auth.users), así que cada
// miembro aparecía con su UUID crudo. El email ahora sale de `useMembers`
// (GET /members -> rpc_list_account_members, que lo resuelve desde auth.users),
// cruzado por user_id; sin email resuelto se conserva el fallback al user_id.

const h = vi.hoisted(() => ({
  teamMembers: [] as Array<{
    id: string
    user_id: string
    role: "owner" | "admin" | "member"
    created_at: string
    profiles: { name: string | null } | null
  }>,
  memberRows: [] as Array<{ user_id: string; email: string | null }>,
  useMembersCalls: [] as Array<string | null>,
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acct-1", accountRole: "owner" } }),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxUsers: 5 } }),
}))

vi.mock("@/hooks/data/use-team-members", () => ({
  useTeamMembers: () => ({ data: h.teamMembers, isLoading: false }),
}))

vi.mock("@/hooks/data/use-members", () => ({
  useMembers: (accountId: string | null) => {
    h.useMembersCalls.push(accountId)
    return { members: h.memberRows, isLoading: false, isError: false }
  },
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: vi.fn() }),
}))

import { TeamSection } from "@/components/settings/TeamSection"

function wrapper({ children }: { children: ReactNode }) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

beforeEach(() => {
  h.useMembersCalls = []
  h.teamMembers = [
    { id: "m-1", user_id: "user-1", role: "owner", created_at: "2026-01-01T00:00:00Z", profiles: { name: "Gonzalo" } },
    { id: "m-2", user_id: "user-2", role: "member", created_at: "2026-02-01T00:00:00Z", profiles: null },
  ]
  h.memberRows = [{ user_id: "user-1", email: "g@test.com" }]
})

describe("TeamSection — email real del miembro (tablero-menu-pulido P4)", () => {
  it("muestra el email resuelto bajo el nombre, no el UUID crudo", () => {
    render(<TeamSection />, { wrapper })

    expect(screen.getByText("Gonzalo")).toBeInTheDocument()
    expect(screen.getByText("g@test.com")).toBeInTheDocument()
    expect(screen.queryByText("user-1")).toBeNull()
  })

  it("el miembro sin email resuelto conserva el fallback al user_id", () => {
    render(<TeamSection />, { wrapper })

    // user-2 no está en la lista de /members -> sin email, queda su id.
    expect(screen.getByText("user-2")).toBeInTheDocument()
    expect(screen.getByText("Usuario")).toBeInTheDocument()
  })

  it("un email nulo en /members también cae al user_id (nunca 'null')", () => {
    h.memberRows = [{ user_id: "user-1", email: null }, { user_id: "user-2", email: "l@test.com" }]
    render(<TeamSection />, { wrapper })

    expect(screen.getByText("user-1")).toBeInTheDocument()
    expect(screen.getByText("l@test.com")).toBeInTheDocument()
    expect(screen.queryByText("null")).toBeNull()
  })

  it("lee los emails de la cuenta activa (useMembers recibe el accountId)", () => {
    render(<TeamSection />, { wrapper })

    expect(h.useMembersCalls.length).toBeGreaterThan(0)
    expect(h.useMembersCalls.every((id) => id === "acct-1")).toBe(true)
  })
})
