/**
 * v3-rbac-multirole Parte C — useOrgRole TDD tests (grupo 16, D19).
 *
 * D19: `role` sigue siendo el derivado singular de mayor precedencia (misma
 * forma que hoy); `roles` es el array nuevo (sólo lo consume la pantalla de
 * gestión). `isWriter` (ronda 1 adversarial, finding MAJOR): ya NO se deriva
 * del singular `rpc_my_account_role` (que colapsa cualquier rol funcional a
 * "member") sino del CONJUNTO real vía `rpc_my_active_account_roles()`
 * contrastado contra `is_writer` del catálogo (`useRoleCatalog`) — mismo
 * predicado EXISTS que `is_account_writer` en la base. Mientras el conjunto
 * (o el catálogo) está indeterminado (cargando / error transitorio) el hook
 * falla SIEMPRE abierto (escritor) — nunca vuelve a mirar el singular
 * `role` para decidirlo, porque "member" es justo el valor ambiguo que
 * colapsa tanto a un viewer real como a un rol funcional. Una vez que el
 * conjunto resuelve de verdad, "sin ningún rol activo writer" es
 * fail-CLOSED, igual que la base.
 *
 * Nota de test: el hook pasa `initialData: user?.accountRole ?? null` +
 * `staleTime: 5min` a la query del singular — React Query trata ese
 * `initialData` (aunque el VALOR sea null) como dato YA obtenido "ahora",
 * así que dentro de la ventana de staleTime nunca vuelve a llamar a queryFn
 * por sí solo. Cada test fuerza el refetch real invalidando la query
 * después de montar, igual que hacen las mutaciones reales de la pantalla.
 * La query del CONJUNTO (`orgActiveRoles`) no tiene `initialData`, así que
 * corre sola al montar — sólo hace falta esperar a que asiente.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const state = {
  accountId: "acc-1" as string | null,
  roleResult: null as unknown,
  roleError: null as { message: string } | null,
  activeRolesResult: undefined as unknown, // undefined = "nunca resuelve" (simula RPC colgado/no montado)
  activeRolesError: null as { message: string } | null,
  catalogRows: [] as unknown[],
  catalogError: null as { message: string } | null,
}

// Catálogo REAL (Parte A, D2) — sólo "viewer" es is_writer=false.
const FULL_CATALOG = [
  { code: "owner", label: "Propietario", description: "", sort_order: 1, is_writer: true },
  { code: "admin", label: "Administrador", description: "", sort_order: 2, is_writer: true },
  { code: "seller", label: "Vendedor", description: "", sort_order: 3, is_writer: true },
  { code: "cashier", label: "Cajero", description: "", sort_order: 4, is_writer: true },
  { code: "stock", label: "Depósito", description: "", sort_order: 5, is_writer: true },
  { code: "purchases", label: "Compras", description: "", sort_order: 6, is_writer: true },
  { code: "accountant", label: "Contable", description: "", sort_order: 7, is_writer: true },
  { code: "viewer", label: "Observador", description: "", sort_order: 8, is_writer: false },
]

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: state.accountId ? { accountId: state.accountId } : null,
  }),
}))

function makeCatalogBuilder() {
  const builder = {
    select: vi.fn(() => builder),
    order: vi.fn(() => builder),
    then(onFulfilled: (v: { data: unknown; error: unknown }) => unknown) {
      return Promise.resolve(
        onFulfilled({ data: state.catalogError ? null : state.catalogRows, error: state.catalogError }),
      )
    },
  }
  return builder
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    rpc: vi.fn((fnName: string) => {
      if (fnName === "rpc_my_active_account_roles") {
        if (state.activeRolesResult === undefined) {
          // Nunca resuelve dentro de la ventana del test -- simula el
          // estado "todavía cargando" de forma determinística.
          return new Promise(() => {})
        }
        return Promise.resolve({ data: state.activeRolesResult, error: state.activeRolesError })
      }
      // rpc_my_account_role (el singular legado).
      return Promise.resolve({ data: state.roleResult, error: state.roleError })
    }),
    from: vi.fn(() => makeCatalogBuilder()),
  })),
}))

import { useOrgRole } from "@/hooks/useOrgRole"

/** Monta el hook y fuerza un refetch real del singular (ver nota de arriba
 * sobre initialData) — la query del conjunto no lo necesita. */
async function renderOrgRole(accountId: string | null) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)

  const rendered = renderHook(() => useOrgRole(), { wrapper })

  if (accountId) {
    await act(async () => {
      await queryClient.invalidateQueries({ queryKey: ["orgRole", accountId] })
    })
  }

  return rendered
}

describe("useOrgRole — D19 (forma + fail-open del singular)", () => {
  beforeEach(() => {
    state.accountId = "acc-1"
    state.roleResult = null
    state.roleError = null
    state.activeRolesResult = undefined
    state.activeRolesError = null
    state.catalogRows = [...FULL_CATALOG]
    state.catalogError = null
  })

  it("RED 16.2: devuelve {role, roles, isWriter, isLoading} — el derivado singular sobrevive", async () => {
    state.roleResult = "owner"
    state.activeRolesResult = ["owner"]

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.role).toBe("owner"))
    await waitFor(() => expect(result.current.isWriter).toBe(true))
    expect(Array.isArray(result.current.roles)).toBe(true)
    expect(typeof result.current.isLoading).toBe("boolean")
  })

  it("RED 16.1a: fail-open — sin cuenta activa, role queda null (indeterminado) y se trata como escritor", async () => {
    state.accountId = null // sin cuenta activa -> ningún query corre, todo indeterminado

    const { result } = await renderOrgRole(null)

    expect(result.current.role).toBeNull()
    expect(result.current.isWriter).toBe(true)
  })

  it("RED 16.1b: fail-open — un error transitorio de AMBOS RPCs no bloquea (role null, conjunto indeterminado, isWriter true)", async () => {
    state.roleError = { message: "network blip" }
    state.activeRolesResult = null
    state.activeRolesError = { message: "network blip" }

    const { result } = await renderOrgRole("acc-1")

    // role nunca resuelve un valor real; el conjunto tampoco -- sigue
    // siendo el estado indeterminado que el fail-open debe tratar como
    // escritor, en TODO momento.
    expect(result.current.role).toBeNull()
    expect(result.current.isWriter).toBe(true)
  })

  it("fail-open — el conjunto todavía CARGANDO (no resolvió ni con éxito ni con error) trata al caller como escritor, aunque el singular ya diga 'member'", async () => {
    state.roleResult = "member"
    // state.activeRolesResult queda undefined -> la query de rpc_my_active_account_roles nunca resuelve.

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.role).toBe("member"))
    // El singular YA dice "member" -- pero NO se vuelve a mirar ese valor
    // para decidir isWriter mientras el conjunto real está indeterminado
    // (ver comentario del hook): "member" es AMBIGUO (puede ser un viewer
    // real o un seller que el singular colapsó), así que indeterminado
    // siempre falla ABIERTO, nunca cae al criterio legado.
    expect(result.current.isWriter).toBe(true)
  })

  it("GREEN — MAJOR ronda 1: un miembro cuyo ÚNICO rol activo es funcional ('seller') es escritor, aunque el singular colapse a 'member'", async () => {
    // rpc_my_account_role (Parte A) colapsa cualquier conjunto sin owner/
    // admin a 'member' -- éste es EXACTAMENTE el bug reproducido por el
    // revisor: is_account_writer=true en la base, isWriter=false en la UI.
    state.roleResult = "member"
    state.activeRolesResult = ["seller"]

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.role).toBe("member"))
    await waitFor(() => expect(result.current.roles).toEqual(["seller"]))
    expect(result.current.isWriter).toBe(true)
  })

  it("GREEN — MAJOR ronda 1: cualquier rol funcional del catálogo (cashier/stock/purchases/accountant) es escritor", async () => {
    for (const role of ["cashier", "stock", "purchases", "accountant"]) {
      state.roleResult = "member"
      state.activeRolesResult = [role]

      const { result } = await renderOrgRole("acc-1")

      await waitFor(() => expect(result.current.roles).toEqual([role]))
      expect(result.current.isWriter).toBe(true)
    }
  })

  it("GREEN: el conjunto resuelto con SOLO 'viewer' es de solo lectura (fail-CLOSED sobre un dato cierto)", async () => {
    state.roleResult = "viewer"
    state.activeRolesResult = ["viewer"]

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.roles).toEqual(["viewer"]))
    expect(result.current.isWriter).toBe(false)
  })

  it("GREEN: el conjunto resuelto VACÍO (sin ninguna membresía activa) es de solo lectura -- no indeterminado", async () => {
    state.roleResult = "member"
    state.activeRolesResult = []

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.role).toBe("member"))
    await waitFor(() => expect(result.current.isWriter).toBe(false))
    // Ronda 2 adversarial (finding NIT): `roles` debía reflejar el conjunto
    // VACÍO ya resuelto, no caer al fallback `[role]` del singular legacy --
    // antes de este fix, `roles` quedaba `["member"]` mientras `isWriter`
    // (arriba) ya decía `false` para el MISMO estado: dos derivados del
    // mismo hook contradiciéndose entre sí.
    expect(result.current.roles).toEqual([])
  })

  it("TRIANGULATE: admin y owner siguen siendo escritores", async () => {
    for (const role of ["admin", "owner"]) {
      state.roleResult = role
      state.activeRolesResult = [role]
      const { result } = await renderOrgRole("acc-1")
      await waitFor(() => expect(result.current.role).toBe(role))
      expect(result.current.isWriter).toBe(true)
    }
  })

  it("TRIANGULATE: un miembro con VARIOS roles activos (uno de ellos writer) es escritor", async () => {
    state.roleResult = "member"
    state.activeRolesResult = ["viewer", "seller"] // "viewer" no writer, "seller" sí -- alcanza con uno.

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.roles).toEqual(["viewer", "seller"]))
    expect(result.current.isWriter).toBe(true)
  })

  it("fail-open: un código de rol AUSENTE del catálogo ya resuelto (vacío) no hace fail-closed", async () => {
    state.roleResult = "member"
    state.activeRolesResult = ["seller"]
    // El catálogo SÍ resolvió (no está cargando), pero vacío -- no contiene
    // "seller". `catalog.find(...)` da undefined -> el fallback `?? true`
    // del hook evita bloquear por un código que el catálogo (ya resuelto)
    // simplemente no trae, en vez de tratarlo como "no writer".
    state.catalogRows = []

    const { result } = await renderOrgRole("acc-1")

    await waitFor(() => expect(result.current.roles).toEqual(["seller"]))
    expect(result.current.isWriter).toBe(true)
  })
})
