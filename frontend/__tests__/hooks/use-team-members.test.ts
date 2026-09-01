/**
 * qa-integral-modulos (G8, task 8.3) — useTeamMembers sin el embed roto.
 *
 * El QA del 2026-08-30 encontró el 400 `PGRST200` en consola: la query
 * `account_members.select("…, profiles(name, email)")` pide un embed que
 * PostgREST no puede resolver (no existe FK account_members→profiles), así
 * que TODA la lectura de miembros falla — Equipo muestra "0 / 10 usuarios",
 * roles y sucursales no listan a nadie.
 *
 * El mock replica el TRANSPORte real de PostgREST (lección del proyecto:
 * "los mocks replican el transporte real"): un select que incluya
 * `profiles(` devuelve el error PGRST200 tal cual lo devuelve prod; el
 * select plano devuelve filas. El fix (D6) va por dos queries + join en
 * cliente (patrón que ya funciona en /organizacion/invitar: account_members
 * SIN embed), NO por una FK nueva a profiles.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

// ── Estado del mock (transporte PostgREST simulado) ──────────────────────────

interface MockResult {
  data: unknown
  error: { code: string; message: string } | null
}

const state = {
  memberRows: [] as unknown[],
  profileRows: [] as unknown[],
  profilesError: null as MockResult["error"],
  calls: [] as { table: string; select: string }[],
}

const PGRST200: MockResult["error"] = {
  code: "PGRST200",
  message:
    "Could not find a relationship between 'account_members' and 'profiles' in the schema cache",
}

function makeBuilder(table: string) {
  let selectCols = ""
  const builder = {
    select: vi.fn((cols: string) => {
      selectCols = cols
      state.calls.push({ table, select: cols })
      return builder
    }),
    eq: vi.fn(() => builder),
    in: vi.fn(() => builder),
    order: vi.fn(() => builder),
    then(onFulfilled: (value: MockResult) => unknown) {
      let result: MockResult
      if (table === "account_members") {
        // Transporte real: el embed a profiles NO resuelve (sin FK) → PGRST200.
        result = selectCols.includes("profiles(")
          ? { data: null, error: PGRST200 }
          : { data: state.memberRows, error: null }
      } else if (table === "profiles") {
        result = state.profilesError
          ? { data: null, error: state.profilesError }
          : { data: state.profileRows, error: null }
      } else {
        result = { data: [], error: null }
      }
      return Promise.resolve(onFulfilled(result))
    },
  }
  return builder
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    from: vi.fn((table: string) => makeBuilder(table)),
  })),
}))

import { useTeamMembers, resolveMemberName, type TeamMemberRow } from "@/hooks/data/use-team-members"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const MEMBERS = [
  { id: "m-1", user_id: "user-1", role: "owner", created_at: "2026-01-01T00:00:00Z" },
  { id: "m-2", user_id: "user-2", role: "member", created_at: "2026-02-01T00:00:00Z" },
]

describe("useTeamMembers — sin el embed roto (PGRST200)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    state.memberRows = [...MEMBERS]
    state.profileRows = [{ id: "user-1", name: "Gonzalo", email: "g@test.com" }]
    state.profilesError = null
    state.calls = []
  })

  it("RED 8.3: lista los miembros reales contra el transporte PostgREST actual (hoy: 400 PGRST200 y lista vacía)", async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    // Hoy el hook manda el embed, recibe PGRST200 y tira: data undefined.
    expect(result.current.isError).toBe(false)
    expect(result.current.data).toHaveLength(2)
    const owner = result.current.data?.find((m) => m.user_id === "user-1")
    expect(owner?.profiles).toEqual({ name: "Gonzalo", email: "g@test.com" })
  })

  it("TRIANGULATE: el perfil invisible por RLS queda en null y el miembro igual aparece", async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.data).toBeDefined())

    const other = result.current.data?.find((m) => m.user_id === "user-2")
    expect(other).toBeDefined()
    expect(other?.profiles).toBeNull()
    expect(other?.role).toBe("member")
  })

  it("TRIANGULATE: sin miembros no consulta profiles y devuelve []", async () => {
    state.memberRows = []

    const { result } = renderHook(() => useTeamMembers("acct-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(result.current.data).toEqual([])
    expect(state.calls.some((c) => c.table === "profiles")).toBe(false)
  })

  it("TRIANGULATE: si la lectura de profiles falla, degrada a miembros sin perfil (no rompe la lista)", async () => {
    state.profilesError = { code: "XX000", message: "boom" }

    const { result } = renderHook(() => useTeamMembers("acct-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.isError).toBe(false)
    expect(result.current.data).toHaveLength(2)
    expect(result.current.data?.every((m) => m.profiles === null)).toBe(true)
  })

  it("la query de account_members NO pide el embed profiles( (causa raíz del PGRST200)", async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const memberSelects = state.calls.filter((c) => c.table === "account_members")
    expect(memberSelects.length).toBeGreaterThan(0)
    for (const call of memberSelects) {
      expect(call.select).not.toContain("profiles(")
    }
  })
})

describe("resolveMemberName — fallback existente (sano, no cambia)", () => {
  const members: TeamMemberRow[] = [
    {
      id: "m-1",
      user_id: "user-1",
      role: "owner",
      created_at: "2026-01-01T00:00:00Z",
      profiles: { name: null, email: "solo-email@test.com" },
    },
  ]

  it("cae a email cuando no hay nombre y a 'no registrado' cuando no hay perfil", () => {
    expect(resolveMemberName(members, "user-1")).toBe("solo-email@test.com")
    expect(resolveMemberName(members, "user-x")).toBe("no registrado")
    expect(resolveMemberName(members, null)).toBe("no registrado")
  })
})
