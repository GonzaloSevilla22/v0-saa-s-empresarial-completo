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
 *
 * tablero-menu-pulido (P4): la segunda query pedía `profiles.email`, columna que
 * NO existe (el email vive en auth.users): PostgREST respondía 400 (42703) en
 * cada carga y, como el error se ignora a propósito, TODOS los perfiles caían a
 * null — las pantallas perdían hasta el nombre ("Creada por no registrado").
 * El mock replica ese transporte: un select de `profiles` con una columna que la
 * tabla no tiene devuelve el 42703 tal cual lo devuelve prod.
 *
 * Ronda 1 de revisión: el mock aplica además la RLS real de `profiles` — las
 * únicas policies SELECT vivas son "Users can view own profile" (`auth.uid() =
 * id`) y la de admin de PLATAFORMA. Un miembro común recibe SÓLO su propia
 * fila: el nombre de un compañero nunca llega por acá (lo resuelve el
 * directorio de /members, `resolveMemberName` en hooks/data/use-members.ts).
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
  // La TABLA profiles completa; lo que vuelve lo recorta la RLS (ver `then`).
  profileRows: [] as { id: string; name: string | null }[],
  // auth.uid() de la sesión simulada (miembro común, no admin de plataforma).
  authUid: "user-1",
  profilesError: null as MockResult["error"],
  calls: [] as { table: string; select: string }[],
}

// Columnas que public.profiles SÍ tiene entre las que el hook puede pedir
// (verificado contra lib/database.types.ts y las migraciones: sin `email`).
const PROFILES_COLUMNS = ["id", "name", "avatar_url", "last_name"]

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
        const unknown = selectCols
          .split(",")
          .map((c) => c.trim())
          .filter((c) => c && !PROFILES_COLUMNS.includes(c))
        if (unknown.length > 0) {
          // Transporte real: columna inexistente -> 400, código 42703.
          result = {
            data: null,
            error: { code: "42703", message: `column profiles.${unknown[0]} does not exist` },
          }
        } else {
          // RLS real: "Users can view own profile" (auth.uid() = id) — sin
          // error, el resto de las filas simplemente no vuelve.
          result = state.profilesError
            ? { data: null, error: state.profilesError }
            : { data: state.profileRows.filter((p) => p.id === state.authUid), error: null }
        }
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

import { useTeamMembers } from "@/hooks/data/use-team-members"

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
    // La fila de Lucía EXISTE en la tabla: si vuelve null es por la RLS.
    state.profileRows = [{ id: "user-1", name: "Gonzalo" }, { id: "user-2", name: "Lucía" }]
    state.authUid = "user-1"
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
    expect(owner?.profiles).toEqual({ name: "Gonzalo" })
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

describe("useTeamMembers — la query de perfiles pide sólo columnas que existen (tablero-menu-pulido P4)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    state.memberRows = [...MEMBERS]
    state.profileRows = [{ id: "user-1", name: "Gonzalo" }, { id: "user-2", name: "Lucía" }]
    state.authUid = "user-1"
    state.profilesError = null
    state.calls = []
  })

  it('el select de profiles es exactamente "id, name" (sin email, que no existe en la tabla)', async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const profileSelects = state.calls.filter((c) => c.table === "profiles")
    expect(profileSelects.map((c) => c.select)).toEqual(["id, name"])
  })

  it("el nombre PROPIO vuelve a resolverse (el 400 por columna inexistente ya no tira todos los perfiles a null)", async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.data).toBeDefined())

    const propio = result.current.data?.find((m) => m.user_id === "user-1")
    // Estricto: ni siquiera una clave `email` (el tipo no promete lo que la
    // tabla no tiene).
    expect(propio?.profiles).toStrictEqual({ name: "Gonzalo" })
  })

  it("el nombre de un COMPAÑERO no llega por profiles (RLS: sólo el propio) — lo resuelve /members", async () => {
    const { result } = renderHook(() => useTeamMembers("acct-1"), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(result.current.data?.map((m) => [m.user_id, m.profiles?.name ?? null])).toEqual([
      ["user-1", "Gonzalo"],
      ["user-2", null],
    ])
  })
})
