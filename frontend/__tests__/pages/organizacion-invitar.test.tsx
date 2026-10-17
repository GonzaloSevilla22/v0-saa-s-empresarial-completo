/**
 * multiusuario-operativo tanda C (17.3) — /organizacion/invitar: la invitación de punta a punta.
 *
 * Antes la pantalla creaba la fila por supabase-js (`rpc_invite_member`) y mostraba el token para
 * compartirlo a mano: nadie mandaba el email. Fija:
 *
 *   · crea por FastAPI (`POST /members/invitations`) y NUNCA llama a `rpc_invite_member` por supabase-js;
 *   · el éxito dice «Le enviamos un email a …» (no «compartí el token») y «Copiar link» queda como opción
 *     SECUNDARIA que copia el LINK completo, nunca el token suelto;
 *   · lista las invitaciones de la cuenta con «Reenviar» (rota el token) y «Revocar» (con confirmación);
 *   · los topes de envío (429) y demás errores dicen qué esperar o qué corregir;
 *   · el administrador no ofrece propietario ni administrador; quien no es dueño ni administrador no ve el formulario.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { PythonApiError } from "@/lib/api/python-api-error"

const TOKEN = "0123456789abcdef".repeat(4)
const NEW_TOKEN = "fedcba9876543210".repeat(4)

const h = vi.hoisted(() => ({
  callerRole: "owner" as string | null,
  maxUsers: 5,
  members: [{ user_id: "u1" }] as Array<{ user_id: string }>,
  get: vi.fn(),
  post: vi.fn(),
  del: vi.fn(),
  rpc: vi.fn(),
  toastSuccess: vi.fn(),
  toastError: vi.fn(),
  writeText: vi.fn(),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acc-1", accountRole: h.callerRole } }),
}))

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: h.callerRole, roles: h.callerRole ? [h.callerRole] : [], rolesResolved: true, isWriter: true, isLoading: false }),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxUsers: h.maxUsers } }),
}))

vi.mock("@/hooks/data/use-members", () => ({
  useMembers: () => ({ members: h.members, isLoading: false, isError: false }),
}))

const CATALOG = [
  { code: "owner", label: "Propietario", description: "Control total", sort_order: 1, is_writer: true },
  { code: "admin", label: "Administrador", description: "Gestiona la cuenta", sort_order: 2, is_writer: true },
  { code: "seller", label: "Vendedor", description: "Registra ventas", sort_order: 3, is_writer: true },
  { code: "viewer", label: "Observador", description: "Solo lectura", sort_order: 8, is_writer: false },
]
vi.mock("@/hooks/data/use-role-catalog", () => ({
  useRoleCatalog: () => ({ data: CATALOG }),
  resolveRoleLabel: (_c: unknown, code: string) => code,
}))

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: (...a: unknown[]) => h.get(...a),
    post: (...a: unknown[]) => h.post(...a),
    delete: (...a: unknown[]) => h.del(...a),
  },
}))

// Si alguien volviera a invitar por supabase-js, esta RPC lo delataría.
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: (...a: unknown[]) => h.rpc(...a), from: () => ({ select: () => ({ order: () => Promise.resolve({ data: [], error: null }) }) }) }),
}))

vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))

vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => h.toastSuccess(...a), error: (...a: unknown[]) => h.toastError(...a) } }))

import InvitarPage from "@/app/(dashboard)/organizacion/invitar/page"

const ROW = {
  id: "inv-1",
  email: "pendiente@test.local",
  roles: ["seller"],
  role_labels: ["Vendedor"],
  state: "pending",
  created_at: "2026-10-17T12:00:00+00:00",
  expires_at: "2026-10-24T12:00:00+00:00",
  invited_by: "u1",
  invited_by_name: "Dueño",
  last_sent_at: "2026-10-17T12:00:05+00:00",
  send_count: 1,
}

let rows: unknown[] = []

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <InvitarPage />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  h.callerRole = "owner"
  h.maxUsers = 5
  h.members = [{ user_id: "u1" }]
  rows = [ROW]
  h.get.mockReset().mockImplementation(async (path: string) => {
    if (path === "/members/invitations") return rows
    return []
  })
  h.post.mockReset().mockResolvedValue({
    id: "inv-new", email: "nuevo@test.local", roles: ["seller"], expires_at: "2026-10-24T12:00:00+00:00", token: TOKEN, email_queued: true,
  })
  h.del.mockReset().mockResolvedValue({ id: "inv-1", status: "revoked" })
  h.rpc.mockReset()
  h.toastSuccess.mockReset()
  h.toastError.mockReset()
  h.writeText.mockReset().mockResolvedValue(undefined)
  Object.defineProperty(navigator, "clipboard", { value: { writeText: h.writeText }, configurable: true })
})

async function invite(email = "Nuevo@Test.Local") {
  fireEvent.change(screen.getByLabelText("Email"), { target: { value: email } })
  fireEvent.click(screen.getByLabelText(/vendedor/i))
  fireEvent.click(screen.getByRole("button", { name: /enviar invitación/i }))
}

describe("crear la invitación", () => {
  it("invita por FastAPI con el email normalizado y el conjunto de roles", async () => {
    renderPage()
    await invite()

    await waitFor(() => expect(h.post).toHaveBeenCalled())
    expect(h.post).toHaveBeenCalledWith("/members/invitations", { email: "nuevo@test.local", roles: ["seller"] })
  })

  it("NUNCA invita por supabase-js (rpc_invite_member ya no se llama desde el navegador)", async () => {
    renderPage()
    await invite()

    await waitFor(() => expect(h.post).toHaveBeenCalled())
    expect(h.rpc).not.toHaveBeenCalledWith("rpc_invite_member", expect.anything())
    expect(h.rpc).not.toHaveBeenCalled()
  })

  it("el éxito dice que se envió un email — no «compartí el token»", async () => {
    renderPage()
    await invite()

    expect(await screen.findByText(/le enviamos un email a nuevo@test\.local/i)).toBeInTheDocument()
    expect(screen.queryByText(/compartí el (token|código)/i)).toBeNull()
    expect(screen.queryByText(/todavía no se envía/i)).toBeNull()
  })

  it("«Copiar link» es secundario y copia el LINK completo, no el token suelto", async () => {
    renderPage()
    await invite()

    fireEvent.click(await screen.findByRole("button", { name: /copiar link/i }))

    await waitFor(() => expect(h.writeText).toHaveBeenCalled())
    expect(h.writeText).toHaveBeenCalledWith(`${window.location.origin}/invitacion/${TOKEN}`)
    expect(h.writeText).not.toHaveBeenCalledWith(TOKEN)
  })

  it("no imprime el token en pantalla", async () => {
    const { container } = renderPage()
    await invite()
    await screen.findByText(/le enviamos un email/i)
    expect(container.textContent).not.toContain(TOKEN)
  })

  it("sin roles seleccionados avisa que se incorpora como Observador", () => {
    renderPage()
    expect(screen.getByText(/se incorpora como observador/i)).toBeInTheDocument()
  })

  it.each([
    [new PythonApiError("invitation_cooldown: esperá", 429, { code: "P0439" }), /unos minutos/i],
    [new PythonApiError("invitation_daily_cap: tope", 429, { code: "P0439" }), /por día/i],
    [new PythonApiError("P409: pending invitation already exists for x", 409, { code: "P0407" }), /invitación pendiente/i],
    [new PythonApiError("P403: member quota reached (2 / 2)", 403, { code: "P0402" }), /límite de miembros/i],
    [new PythonApiError("invalid_email: no es válido", 400, { code: "P0400" }), /email/i],
  ])("traduce el error %# a un mensaje accionable", async (error, expected) => {
    h.post.mockRejectedValue(error)
    renderPage()
    await invite()

    expect(await screen.findByRole("alert")).toHaveTextContent(expected)
  })
})

describe("roles invitables", () => {
  it("el dueño ofrece todos los roles", () => {
    renderPage()
    for (const label of [/propietario/i, /administrador/i, /vendedor/i, /observador/i]) {
      expect(screen.getByLabelText(label)).toBeInTheDocument()
    }
  })

  it("el administrador NO ofrece propietario ni administrador", () => {
    h.callerRole = "admin"
    renderPage()
    expect(screen.queryByLabelText(/propietario/i)).toBeNull()
    expect(screen.queryByLabelText(/administrador/i)).toBeNull()
    expect(screen.getByLabelText(/vendedor/i)).toBeInTheDocument()
  })

  it("quien no es dueño ni administrador no ve el formulario ni pide la lista", async () => {
    h.callerRole = "seller"
    renderPage()

    expect(screen.getByText(/solo el dueño o un administrador puede invitar/i)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /enviar invitación/i })).toBeNull()
    expect(h.get).not.toHaveBeenCalledWith("/members/invitations")
  })

  it("con el cupo lleno no se ofrece el formulario y se ofrece ver planes", () => {
    h.maxUsers = 1
    h.members = [{ user_id: "u1" }]
    renderPage()

    expect(screen.getByText(/cupo lleno/i)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /enviar invitación/i })).toBeNull()
  })
})

describe("la lista de invitaciones", () => {
  it("muestra email, roles, estado, cuántas veces se envió y el vencimiento — sin token", async () => {
    const { container } = renderPage()

    const list = await screen.findByRole("list", { name: /invitaciones de la cuenta/i })
    expect(within(list).getByText("pendiente@test.local")).toBeInTheDocument()
    expect(within(list).getByText("Pendiente")).toBeInTheDocument()
    expect(within(list).getByText("Vendedor")).toBeInTheDocument()
    expect(within(list).getByText(/enviada 1 vez/i)).toBeInTheDocument()
    expect(within(list).getByText(/vence 24\/10\/2026/i)).toBeInTheDocument()
    expect(container.textContent).not.toContain("token")
  })

  it("distingue vencidas y revocadas; las revocadas no ofrecen acciones", async () => {
    rows = [
      { ...ROW, id: "inv-exp", email: "vencida@test.local", state: "expired" },
      { ...ROW, id: "inv-rev", email: "revocada@test.local", state: "revoked" },
    ]
    renderPage()

    expect(await screen.findByText("Vencida")).toBeInTheDocument()
    expect(screen.getByText("Revocada")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /reenviar la invitación a vencida@test\.local/i })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /reenviar la invitación a revocada@test\.local/i })).toBeNull()
    expect(screen.queryByRole("button", { name: /revocar la invitación a revocada@test\.local/i })).toBeNull()
  })

  it("sin invitaciones lo dice", async () => {
    rows = []
    renderPage()
    expect(await screen.findByText(/no hay invitaciones pendientes/i)).toBeInTheDocument()
  })

  it("si no se puede cargar, ofrece reintentar", async () => {
    h.get.mockRejectedValue(new Error("boom"))
    renderPage()
    expect(await screen.findByText(/no pudimos cargar las invitaciones/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /reintentar/i })).toBeInTheDocument()
  })
})

describe("Reenviar", () => {
  it("reenvía por FastAPI, avisa que el link anterior ya no sirve y ofrece copiar el link NUEVO", async () => {
    h.post.mockResolvedValue({ id: "inv-1", email: "pendiente@test.local", roles: ["seller"], expires_at: "2026-10-24T12:00:00+00:00", token: NEW_TOKEN, email_queued: true })
    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: /reenviar la invitación a pendiente@test\.local/i }))

    await waitFor(() => expect(h.post).toHaveBeenCalledWith("/members/invitations/inv-1/resend", {}))
    await waitFor(() => expect(h.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/link anterior ya no sirve/i)))

    fireEvent.click(await screen.findByRole("button", { name: /copiar link nuevo/i }))
    await waitFor(() => expect(h.writeText).toHaveBeenCalledWith(`${window.location.origin}/invitacion/${NEW_TOKEN}`))
  })

  it("un reenvío demasiado pronto (429) dice qué esperar y no ofrece link", async () => {
    h.post.mockRejectedValue(new PythonApiError("invitation_cooldown: esperá unos minutos", 429, { code: "P0439" }))
    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: /reenviar la invitación a pendiente@test\.local/i }))

    await waitFor(() => expect(h.toastError).toHaveBeenCalledWith(expect.stringMatching(/unos minutos/i)))
    expect(screen.queryByRole("button", { name: /copiar link nuevo/i })).toBeNull()
  })
})

describe("Revocar", () => {
  it("pide confirmación y recién después revoca", async () => {
    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: /revocar la invitación a pendiente@test\.local/i }))

    // Todavía no revocó: pide confirmación.
    expect(await screen.findByText(/¿revocar la invitación\?/i)).toBeInTheDocument()
    expect(h.del).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: /revocar invitación/i }))
    await waitFor(() => expect(h.del).toHaveBeenCalledWith("/members/invitations/inv-1"))
    await waitFor(() => expect(h.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/revocamos la invitación/i)))
  })

  it("«Cancelar» no revoca nada", async () => {
    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: /revocar la invitación a pendiente@test\.local/i }))
    fireEvent.click(await screen.findByRole("button", { name: /cancelar/i }))

    await waitFor(() => expect(screen.queryByText(/¿revocar la invitación\?/i)).toBeNull())
    expect(h.del).not.toHaveBeenCalled()
  })
})
