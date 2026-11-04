/**
 * multiusuario-operativo tanda C (17.4, D14) — la invitación rápida de Configuración → Equipo.
 *
 * Usaba el overload de 2 argumentos de `rpc_invite_member`, que resolvía a `viewer` sin que nadie lo
 * eligiera ("candidato registrado por v3-rbac-multirole"). La base lo RETIRÓ: la invitación rápida pasa a
 * declarar el CONJUNTO de roles y a ir por FastAPI, igual que /organizacion/invitar (spec
 * account-invitation-flow: «La invitación rápida de la pantalla de configuración SHALL declarar el
 * conjunto de roles del invitado, igual que la pantalla de invitación»).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"

const h = vi.hoisted(() => ({
  accountRole: "owner" as string,
  maxUsers: 5,
  members: [] as Array<{ id: string; user_id: string; role: string; created_at: string; profiles: null }>,
  post: vi.fn(),
  rpc: vi.fn(),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acct-1", accountRole: h.accountRole } }),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxUsers: h.maxUsers } }),
}))
vi.mock("@/hooks/data/use-team-members", () => ({
  useTeamMembers: () => ({ data: h.members, isLoading: false }),
}))
vi.mock("@/hooks/data/use-members", () => ({
  useMembers: () => ({ members: [], isLoading: false, isError: false }),
}))
vi.mock("@/hooks/data/use-role-catalog", () => ({
  useRoleCatalog: () => ({
    data: [
      { code: "owner", label: "Propietario", description: "Control total", sort_order: 1, is_writer: true },
      { code: "admin", label: "Administrador", description: "Gestiona", sort_order: 2, is_writer: true },
      { code: "seller", label: "Vendedor", description: "Registra ventas", sort_order: 3, is_writer: true },
    ],
  }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: (...a: unknown[]) => h.post(...a), delete: vi.fn() },
}))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: (...a: unknown[]) => h.rpc(...a) }),
}))
vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))

import { TeamSection } from "@/components/settings/TeamSection"

function wrapper({ children }: { children: ReactNode }) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

beforeEach(() => {
  h.accountRole = "owner"
  h.maxUsers = 5
  h.members = [{ id: "m-1", user_id: "user-1", role: "owner", created_at: "2026-01-01T00:00:00Z", profiles: null }]
  h.post.mockReset().mockResolvedValue({
    id: "inv-1", email: "ana@test.local", roles: ["seller"], expires_at: "2026-10-24T12:00:00+00:00", token: "0123456789abcdef".repeat(4), email_queued: true,
  })
  h.rpc.mockReset()
})

describe("TeamSection — invitación rápida", () => {
  it("declara el conjunto de roles y va por FastAPI (no por rpc_invite_member de 2 argumentos)", async () => {
    render(<TeamSection />, { wrapper })

    fireEvent.change(screen.getByLabelText("Email de la persona a invitar"), { target: { value: "Ana@Test.Local" } })
    fireEvent.click(screen.getByLabelText(/vendedor/i))
    fireEvent.click(screen.getByRole("button", { name: "Invitar" }))

    await waitFor(() => expect(h.post).toHaveBeenCalledWith("/members/invitations", { email: "ana@test.local", roles: ["seller"] }))
    expect(h.rpc).not.toHaveBeenCalled()
    expect(await screen.findByText(/le enviamos un email a ana@test\.local/i)).toBeInTheDocument()
  })

  it("ofrece el selector de roles (la invitación rápida ya no es ciega)", () => {
    render(<TeamSection />, { wrapper })
    expect(screen.getByRole("group", { name: /roles/i })).toBeInTheDocument()
    expect(screen.getByLabelText(/vendedor/i)).toBeInTheDocument()
  })

  it("el administrador también invita, pero sin ofrecer propietario ni administrador", () => {
    h.accountRole = "admin"
    render(<TeamSection />, { wrapper })

    expect(screen.getByLabelText("Email de la persona a invitar")).toBeInTheDocument()
    expect(screen.queryByLabelText(/propietario/i)).toBeNull()
    expect(screen.queryByLabelText(/^administrador/i)).toBeNull()
    expect(screen.getByLabelText(/vendedor/i)).toBeInTheDocument()
  })

  it("quien no es dueño ni administrador no ve el formulario", () => {
    h.accountRole = "member"
    render(<TeamSection />, { wrapper })

    expect(screen.queryByLabelText("Email de la persona a invitar")).toBeNull()
    expect(screen.getByText(/contactá al dueño de la cuenta/i)).toBeInTheDocument()
  })

  it("con el cupo agotado no ofrece el formulario", () => {
    h.maxUsers = 2
    h.members = [
      { id: "m-1", user_id: "user-1", role: "owner", created_at: "2026-01-01T00:00:00Z", profiles: null },
      { id: "m-2", user_id: "user-2", role: "member", created_at: "2026-02-01T00:00:00Z", profiles: null },
    ]
    render(<TeamSection />, { wrapper })

    expect(screen.getByText(/cupo de equipo alcanzado/i)).toBeInTheDocument()
    expect(screen.queryByLabelText("Email de la persona a invitar")).toBeNull()
  })

  it("remite a /organizacion/invitar para gestionar las pendientes", () => {
    render(<TeamSection />, { wrapper })
    const links = screen.getAllByRole("link", { name: /invitar miembro/i })
    expect(links.some((l) => l.getAttribute("href") === "/organizacion/invitar")).toBe(true)
  })

  it("un error del backend (429) se muestra con su mensaje accionable", async () => {
    const { PythonApiError } = await import("@/lib/api/python-api-error")
    h.post.mockRejectedValue(new PythonApiError("invitation_daily_cap: tope", 429, { code: "P0439" }))
    render(<TeamSection />, { wrapper })

    fireEvent.change(screen.getByLabelText("Email de la persona a invitar"), { target: { value: "ana@test.local" } })
    fireEvent.click(screen.getByRole("button", { name: "Invitar" }))

    expect(await screen.findByRole("alert")).toHaveTextContent(/por día/i)
  })
})
