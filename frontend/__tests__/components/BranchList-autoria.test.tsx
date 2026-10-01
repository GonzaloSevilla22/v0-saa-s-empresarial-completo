import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import type { Branch, PlanLimits } from "@/lib/types"
import type { MemberRow } from "@/hooks/data/use-members"

// tablero-menu-pulido (P4, ronda 1 de revisión): "Creada por X" / "Desactivada
// por X" en /sucursales se resolvía con `profiles`, cuya RLS sólo deja leer el
// perfil PROPIO ("Users can view own profile"; la otra policy SELECT es la de
// admin de plataforma). Una sucursal creada o desactivada por un COMPAÑERO
// decía "no registrado" — el texto que la spec `branches` reserva para la
// autoría nula. El nombre sale ahora del directorio de /members
// (rpc_list_account_members, SECURITY DEFINER): nombre → email → "no registrado".

const h = vi.hoisted(() => ({
  activas: [] as Branch[],
  inactivas: [] as Branch[],
  directorio: [] as MemberRow[],
  directorioCargando: false,
  directorioConError: false,
  useMembersCalls: [] as Array<string | null>,
}))

vi.mock("@/hooks/data/use-branches", () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useBranches: () => ({ branches: h.activas, isLoading: false, isError: false }),
    useInactiveBranches: () => ({ branches: h.inactivas, isLoading: false, isError: false }),
    useCloseBranch: mutacion,
    useDeactivateBranch: mutacion,
    useOpenBranch: mutacion,
  }
})

// use-members importa el cliente del backend, que exige su URL al cargarse.
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

vi.mock("@/hooks/data/use-members", async (importOriginal) => {
  const actual = await importOriginal<Record<string, unknown>>()
  return {
    ...actual,
    useMembers: (accountId: string | null) => {
      h.useMembersCalls.push(accountId)
      return {
        members: h.directorio,
        isLoading: h.directorioCargando,
        isError: h.directorioConError,
      }
    },
  }
})

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acct-1" } }),
}))

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: "member" }),
}))

import { BranchList } from "@/components/branches/BranchList"

const LIMITS = { maxBranches: 3 } as PlanLimits

function sucursal(id: string, nombre: string, extra: Partial<Branch>): Branch {
  return {
    id,
    accountId: "acct-1",
    name: nombre,
    address: null,
    isActive: true,
    createdAt: "2026-09-01T12:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...extra,
  }
}

function miembro(user_id: string, name: string | null, email: string | null): MemberRow {
  return {
    member_id: `m-${user_id}`,
    user_id,
    legacy_role: "member",
    created_at: "2026-09-01T10:00:00+00:00",
    name,
    email,
    roles: [],
  }
}

beforeEach(() => {
  h.useMembersCalls = []
  h.directorioCargando = false
  h.directorioConError = false
  h.directorio = [
    miembro("user-1", "Gonzalo", "g@test.local"),
    miembro("user-2", "Lucía", "l@test.local"),
    miembro("user-3", null, "sin-nombre@test.local"),
  ]
  h.activas = [
    sucursal("b-1", "Centro", { createdBy: "user-2" }),
    sucursal("b-2", "Godoy Cruz", { createdBy: "user-3" }),
    sucursal("b-3", "Showroom", { createdBy: null }),
  ]
  h.inactivas = [
    sucursal("b-4", "Depósito", {
      isActive: false,
      createdBy: "user-1",
      deactivatedBy: "user-2",
      deactivatedAt: "2026-09-20T15:00:00Z",
    }),
  ]
})

describe("BranchList — autoría de compañeros (tablero-menu-pulido P4)", () => {
  it("una sucursal creada por un compañero muestra su nombre, no 'no registrado'", () => {
    render(<BranchList limits={LIMITS} />)
    expect(screen.getByText("Creada por Lucía")).toBeInTheDocument()
  })

  it("la desactivó un compañero: 'Desactivada por' lleva su nombre", () => {
    render(<BranchList limits={LIMITS} />)
    expect(screen.getByText(/^Desactivada por Lucía/)).toBeInTheDocument()
  })

  it("un miembro sin nombre de perfil se identifica por su email", () => {
    render(<BranchList limits={LIMITS} />)
    expect(screen.getByText("Creada por sin-nombre@test.local")).toBeInTheDocument()
  })

  it("'no registrado' queda sólo para la autoría nula", () => {
    render(<BranchList limits={LIMITS} />)
    expect(screen.getAllByText("Creada por no registrado")).toHaveLength(1)
  })

  it("lee el directorio de la cuenta activa", () => {
    render(<BranchList limits={LIMITS} />)
    expect(h.useMembersCalls.length).toBeGreaterThan(0)
    expect(h.useMembersCalls.every((id) => id === "acct-1")).toBe(true)
  })
})

// Ronda 2 de revisión: `useMembers` devuelve `members: []` mientras /members
// carga (FastAPI en Render free: cold start de ~50 s) o si falla, y
// `resolveMemberName([], id)` es "no registrado". Una autoría CONOCIDA no puede
// mostrarse como "no registrado" — la spec `branches` reserva ese texto para la
// autoría nula — sólo porque el directorio todavía no llegó.
describe("BranchList — autoría mientras el directorio de /members no está disponible", () => {
  it("cargando: la autoría conocida queda pendiente y 'no registrado' sigue sólo para la nula", () => {
    h.directorio = []
    h.directorioCargando = true
    render(<BranchList limits={LIMITS} />)

    expect(screen.getAllByText("Creada por no registrado")).toHaveLength(1)
    expect(screen.getAllByText("Creada por …")).toHaveLength(2)
    expect(screen.getByText(/^Desactivada por …/)).toBeInTheDocument()
    expect(screen.queryByText(/^Desactivada por no registrado/)).not.toBeInTheDocument()
  })

  it("con error y sin datos: tampoco se afirma 'no registrado' para una autoría conocida", () => {
    h.directorio = []
    h.directorioConError = true
    render(<BranchList limits={LIMITS} />)

    expect(screen.getAllByText("Creada por no registrado")).toHaveLength(1)
    expect(screen.getAllByText("Creada por …")).toHaveLength(2)
    expect(screen.getByText(/^Desactivada por …/)).toBeInTheDocument()
  })

  it("si un refresco falla pero hay datos previos, se siguen usando: muestra los nombres", () => {
    h.directorioConError = true
    render(<BranchList limits={LIMITS} />)

    expect(screen.getByText("Creada por Lucía")).toBeInTheDocument()
    expect(screen.getByText(/^Desactivada por Lucía/)).toBeInTheDocument()
    expect(screen.queryByText("Creada por …")).not.toBeInTheDocument()
  })
})
