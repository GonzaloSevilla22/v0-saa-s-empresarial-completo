/**
 * Accesibilidad — multiusuario-operativo tanda C (task 18.1). Molde: `proveedores.a11y.test.tsx`.
 *
 * Comportamiento real, no tautologías: cada control alcanzable por su nombre accesible, un solo `h1` por
 * pantalla, los estados de error anunciados como `alert` y la carga como `status` (un lector de pantalla
 * tiene que enterarse de que la invitación no está disponible), los íconos decorativos fuera del árbol
 * accesible, y el diálogo de «Revocar» con título y descripción (rol `alertdialog`). Los botones primarios
 * llevan el alto táctil de 44 px en móvil (`min-h-11`).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { PythonApiError } from "@/lib/api/python-api-error"

const TOKEN = "0123456789abcdef".repeat(4)

const h = vi.hoisted(() => ({
  user: null as null | { id: string; accountId: string; accountRole: string },
  get: vi.fn(),
  post: vi.fn(),
  del: vi.fn(),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: h.user,
    logout: vi.fn(),
    adoptActiveAccount: vi.fn(),
    switchAccount: vi.fn(),
  }),
}))
vi.mock("@/hooks/data/use-role-catalog", () => ({
  useRoleCatalog: () => ({
    data: [
      { code: "seller", label: "Vendedor", description: "Registra ventas", sort_order: 3, is_writer: true },
      { code: "viewer", label: "Observador", description: "Solo lectura", sort_order: 8, is_writer: false },
    ],
  }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: (...a: unknown[]) => h.get(...a), post: (...a: unknown[]) => h.post(...a), delete: (...a: unknown[]) => h.del(...a) },
}))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn(), replace: vi.fn() }) }))
vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { InvitationAcceptance } from "@/components/invitations/InvitationAcceptance"
import { InviteMemberForm } from "@/components/invitations/InviteMemberForm"
import { PendingInvitations } from "@/components/invitations/PendingInvitations"

function wrap(ui: React.ReactElement) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

const PREVIEW = {
  account_id: "acc-negocio",
  account_display_name: "Panadería Sol",
  inviter_name: "Ana Gómez",
  roles: ["seller"],
  role_labels: ["Vendedor"],
  expires_at: "2026-10-24T12:00:00+00:00",
  already_member: false,
}

beforeEach(() => {
  h.user = { id: "u1", accountId: "acc-1", accountRole: "owner" }
  h.get.mockReset().mockResolvedValue(PREVIEW)
  h.post.mockReset()
  h.del.mockReset()
})

describe("/invitacion/[token] — a11y de los cuatro estados", () => {
  it("sin sesión: un h1, dos enlaces con nombre, íconos decorativos ocultos y el logo sin texto alternativo ruidoso", () => {
    h.user = null
    const { container } = wrap(<InvitationAcceptance token={TOKEN} />)

    // La pantalla pública es una página entera: tiene UN h1 (el título de la tarjeta era un <div> y la
    // dejaba sin ningún encabezado para un lector de pantalla).
    expect(screen.getByRole("heading", { level: 1, name: "Tenés una invitación" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Ingresar" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Crear cuenta" })).toBeInTheDocument()
    for (const icon of container.querySelectorAll("svg")) {
      expect(icon.getAttribute("aria-hidden")).toBe("true")
    }
    expect(container.querySelector("img")?.getAttribute("alt")).toBe("")
  })

  it("cargando: se anuncia como estado", () => {
    h.get.mockReturnValue(new Promise(() => undefined))
    wrap(<InvitationAcceptance token={TOKEN} />)
    expect(screen.getByRole("status")).toHaveTextContent(/cargando la invitación/i)
  })

  it("vista previa: «Aceptar invitación» alcanzable por nombre, con alto táctil de 44 px, y la lista de datos como definición", async () => {
    wrap(<InvitationAcceptance token={TOKEN} />)

    const accept = await screen.findByRole("button", { name: "Aceptar invitación" })
    expect(screen.getByRole("heading", { level: 1, name: /te invitaron a sumarte a panadería sol/i })).toBeInTheDocument()
    expect(accept.className).toMatch(/min-h-11/)
    expect(screen.getByRole("button", { name: "Ahora no" }).className).toMatch(/min-h-11/)
    // <dl>/<dt>/<dd>: "Te invita", "Roles", "Vence" quedan asociados a su valor.
    expect(screen.getByText("Te invita").tagName).toBe("DT")
    expect(screen.getByText("Ana Gómez").tagName).toBe("DD")
  })

  it("no disponible: se anuncia como alerta y la salida tiene nombre", async () => {
    h.get.mockRejectedValue(new PythonApiError("P404: invalid or expired invitation token", 404, { code: "P0404" }))
    wrap(<InvitationAcceptance token={TOKEN} />)

    const alert = await screen.findByRole("alert")
    expect(within(alert).getByRole("heading", { level: 1, name: "Invitación no disponible" })).toBeInTheDocument()
    expect(alert).toHaveTextContent(/no está disponible para tu usuario/i)
    expect(within(alert).getByRole("button", { name: "Cerrar sesión e ingresar con otro email" }).className).toMatch(/min-h-11/)
  })

  it("error de carga: alerta con «Reintentar»", async () => {
    h.get.mockRejectedValue(new Error("Failed to fetch"))
    wrap(<InvitationAcceptance token={TOKEN} />)
    expect(within(await screen.findByRole("alert")).getByRole("button", { name: "Reintentar" })).toBeInTheDocument()
  })
})

describe("InviteMemberForm — a11y", () => {
  it("el email se alcanza por su label y los roles forman un grupo con nombre", () => {
    wrap(<InviteMemberForm callerRole="owner" idPrefix="a11y" />)

    expect(screen.getByLabelText("Email")).toBeInTheDocument()
    const group = screen.getByRole("group", { name: "Roles" })
    expect(within(group).getByLabelText(/vendedor/i)).toBeInTheDocument()
    expect(within(group).getByLabelText(/observador/i)).toBeInTheDocument()
  })

  it("el error se anuncia como alerta y el éxito como estado", async () => {
    h.post.mockRejectedValueOnce(new PythonApiError("invitation_cooldown", 429, { code: "P0439" }))
    wrap(<InviteMemberForm callerRole="owner" idPrefix="a11y" />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "a@b.co" } })
    fireEvent.click(screen.getByRole("button", { name: /enviar invitación/i }))
    expect(await screen.findByRole("alert")).toBeInTheDocument()

    h.post.mockResolvedValueOnce({ id: "i", email: "a@b.co", roles: [], expires_at: "2026-10-24T12:00:00+00:00", token: TOKEN, email_queued: true })
    fireEvent.click(screen.getByRole("button", { name: /enviar invitación/i }))
    expect(await screen.findByRole("status")).toHaveTextContent(/le enviamos un email/i)
  })

  it("el botón de envío tiene alto táctil de 44 px en móvil", () => {
    wrap(<InviteMemberForm callerRole="owner" idPrefix="a11y" />)
    expect(screen.getByRole("button", { name: /enviar invitación/i }).className).toMatch(/min-h-11/)
  })
})

describe("PendingInvitations — a11y", () => {
  const ROW = {
    id: "inv-1", email: "pendiente@test.local", roles: ["seller"], role_labels: ["Vendedor"], state: "pending",
    created_at: "2026-10-17T12:00:00+00:00", expires_at: "2026-10-24T12:00:00+00:00", invited_by: "u1", invited_by_name: "Dueño",
    last_sent_at: "2026-10-17T12:00:05+00:00", send_count: 1,
  }

  it("cada acción nombra a QUIÉN afecta (no hay dos «Reenviar» indistinguibles)", async () => {
    h.get.mockResolvedValue([ROW, { ...ROW, id: "inv-2", email: "otra@test.local" }])
    wrap(<PendingInvitations />)

    expect(await screen.findByRole("button", { name: "Reenviar la invitación a pendiente@test.local" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reenviar la invitación a otra@test.local" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revocar la invitación a otra@test.local" })).toBeInTheDocument()
  })

  it("«Revocar» abre un diálogo de alerta con título y descripción, y los botones táctiles", async () => {
    h.get.mockResolvedValue([ROW])
    wrap(<PendingInvitations />)
    fireEvent.click(await screen.findByRole("button", { name: "Revocar la invitación a pendiente@test.local" }))

    const dialog = await screen.findByRole("alertdialog")
    expect(within(dialog).getByText("¿Revocar la invitación?")).toBeInTheDocument()
    expect(dialog).toHaveAccessibleDescription(/ya no va a poder sumarse/i)
    expect(within(dialog).getByRole("button", { name: "Cancelar" }).className).toMatch(/min-h-11/)
  })

  it("la lista tiene nombre y la carga se anuncia", async () => {
    h.get.mockResolvedValue([ROW])
    wrap(<PendingInvitations />)
    expect(screen.getByRole("status", { name: /cargando invitaciones/i })).toBeInTheDocument()
    expect(await screen.findByRole("list", { name: /invitaciones de la cuenta/i })).toBeInTheDocument()
  })
})
