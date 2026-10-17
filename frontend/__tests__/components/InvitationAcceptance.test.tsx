/**
 * multiusuario-operativo tanda C (17.1) — la pantalla pública de aceptación /invitacion/[token].
 *
 * Cuatro estados, ligados a la IDENTIDAD (specs account-invitation-flow «La pantalla de aceptación
 * está ligada a la identidad invitada»):
 *
 *   1. SIN sesión: un mensaje genérico —sin el nombre del negocio ni el de quien invita— con
 *      «Ingresar» y «Crear cuenta», que al completarse vuelven a ESTA invitación. Ni siquiera
 *      consulta la vista previa.
 *   2. Con sesión y la identidad CORRECTA: la vista previa (negocio, quién invita, roles,
 *      vencimiento) y «Aceptar». Aceptar crea la membresía, deja el negocio como cuenta activa
 *      (`adoptActiveAccount`: renueva el token, limpia la caché) y da la bienvenida.
 *   3. Con sesión y OTRA identidad, o token vencido / revocado / usado / inexistente: UN solo
 *      mensaje, indistinguible entre esos casos, con «Cerrar sesión e ingresar con otro email».
 *   4. Ya es miembro: «Ya sos parte de {negocio}» con «Cambiar a esa cuenta».
 *
 * El token nunca se imprime en pantalla.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { PythonApiError } from "@/lib/api/python-api-error"

const TOKEN = "0123456789abcdef".repeat(4)

const h = vi.hoisted(() => ({
  user: null as null | { id: string; accountId: string },
  logout: vi.fn(),
  adoptActiveAccount: vi.fn(),
  switchAccount: vi.fn(),
  push: vi.fn(),
  replace: vi.fn(),
  get: vi.fn(),
  post: vi.fn(),
  toastError: vi.fn(),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: h.user,
    isAuthenticated: !!h.user,
    logout: h.logout,
    adoptActiveAccount: h.adoptActiveAccount,
    switchAccount: h.switchAccount,
  }),
}))

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: (...a: unknown[]) => h.get(...a), post: (...a: unknown[]) => h.post(...a) },
}))

const routerDoble = { push: h.push, replace: h.replace }
vi.mock("next/navigation", () => ({ useRouter: () => routerDoble }))

vi.mock("next/link", () => ({
  default: ({ href, children, ...rest }: { href: string; children: React.ReactNode }) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))

vi.mock("sonner", () => ({ toast: { error: (...a: unknown[]) => h.toastError(...a), success: vi.fn() } }))

import { InvitationAcceptance } from "@/components/invitations/InvitationAcceptance"

const PREVIEW = {
  account_id: "acc-negocio",
  account_display_name: "Panadería Sol",
  inviter_name: "Ana Gómez",
  roles: ["seller", "cashier"],
  role_labels: ["Vendedor", "Cajero"],
  expires_at: "2026-10-24T12:00:00+00:00",
  already_member: false,
}

const problem = (message: string, status: number, code?: string) => new PythonApiError(message, status, { code })

function renderScreen() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <InvitationAcceptance token={TOKEN} />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  h.user = { id: "u-invitado", accountId: "acc-personal" }
  h.logout.mockReset().mockResolvedValue(undefined)
  h.adoptActiveAccount.mockReset().mockResolvedValue(undefined)
  h.switchAccount.mockReset().mockResolvedValue(undefined)
  h.push.mockReset()
  h.replace.mockReset()
  h.get.mockReset().mockResolvedValue(PREVIEW)
  h.post.mockReset().mockResolvedValue({ account_id: "acc-negocio", active_account_id: "acc-negocio", roles: ["seller", "cashier"] })
  h.toastError.mockReset()
})

describe("sin sesión — mensaje genérico", () => {
  beforeEach(() => {
    h.user = null
  })

  it("no muestra el negocio ni a quien invita, y ni siquiera pide la vista previa", () => {
    renderScreen()

    expect(screen.getByText(/tenés una invitación para sumarte a un negocio en aliadata/i)).toBeInTheDocument()
    expect(screen.queryByText("Panadería Sol")).toBeNull()
    expect(screen.queryByText("Ana Gómez")).toBeNull()
    expect(h.get).not.toHaveBeenCalled()
  })

  it("«Ingresar» y «Crear cuenta» vuelven a ESTA invitación", () => {
    renderScreen()

    const returnTo = encodeURIComponent(`/invitacion/${TOKEN}`)
    expect(screen.getByRole("link", { name: /ingresar/i }).getAttribute("href")).toBe(`/auth/login?next=${returnTo}`)
    expect(screen.getByRole("link", { name: /crear cuenta/i }).getAttribute("href")).toBe(`/auth/register?next=${returnTo}`)
  })

  it("no imprime el token en pantalla", () => {
    const { container } = renderScreen()
    expect(container.textContent).not.toContain(TOKEN)
  })
})

describe("con sesión y la identidad correcta — vista previa", () => {
  it("muestra el negocio, quién invita, los roles y el vencimiento, con «Aceptar»", async () => {
    renderScreen()

    expect(await screen.findByText(/te invitaron a sumarte a panadería sol/i)).toBeInTheDocument()
    expect(screen.getByText("Ana Gómez")).toBeInTheDocument()
    expect(screen.getByText("Vendedor")).toBeInTheDocument()
    expect(screen.getByText("Cajero")).toBeInTheDocument()
    expect(screen.getByText("24/10/2026")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /aceptar invitación/i })).toBeInTheDocument()
    expect(h.get).toHaveBeenCalledWith(`/invitations/${TOKEN}`)
  })

  it("«Ahora no» lleva al Tablero sin aceptar", async () => {
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /ahora no/i }))

    expect(h.push).toHaveBeenCalledWith("/dashboard")
    expect(h.post).not.toHaveBeenCalled()
  })

  it("no imprime el token en pantalla", async () => {
    const { container } = renderScreen()
    await screen.findByText(/te invitaron a sumarte/i)
    expect(container.textContent).not.toContain(TOKEN)
  })
})

describe("aceptar", () => {
  it("acepta por FastAPI, deja el negocio como cuenta activa y da la bienvenida con los roles", async () => {
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    await waitFor(() => expect(h.adoptActiveAccount).toHaveBeenCalledTimes(1))
    expect(h.post).toHaveBeenCalledWith(`/invitations/${TOKEN}/accept`, {})
    expect(h.adoptActiveAccount).toHaveBeenCalledWith({ message: "Te sumaste a Panadería Sol como Vendedor, Cajero" })
  })

  it("el orden importa: primero aceptar, recién después activar la cuenta", async () => {
    const order: string[] = []
    h.post.mockImplementation(async () => {
      order.push("accept")
      return { account_id: "acc-negocio", active_account_id: "acc-negocio", roles: ["seller"] }
    })
    h.adoptActiveAccount.mockImplementation(async () => {
      order.push("adopt")
    })
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    await waitFor(() => expect(order).toEqual(["accept", "adopt"]))
  })

  it("mientras acepta deshabilita el botón (no se acepta dos veces)", async () => {
    let release: (value: unknown) => void = () => undefined
    h.post.mockReturnValue(new Promise((resolve) => (release = resolve)))
    renderScreen()
    const button = await screen.findByRole("button", { name: /aceptar invitación/i })
    fireEvent.click(button)

    await waitFor(() => expect(screen.getByRole("button", { name: /aceptando/i })).toBeDisabled())
    fireEvent.click(screen.getByRole("button", { name: /aceptando/i }))
    expect(h.post).toHaveBeenCalledTimes(1)
    release({ account_id: "acc-negocio", active_account_id: "acc-negocio", roles: ["seller"] })
  })

  it("si aceptó pero no pudo cambiar de cuenta, lo dice y ofrece reintentar el cambio (la membresía ya existe)", async () => {
    h.adoptActiveAccount.mockRejectedValueOnce(new Error("no se pudo renovar"))
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    expect(await screen.findByText(/aceptaste la invitación/i)).toBeInTheDocument()
    expect(h.post).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole("button", { name: /cambiar a esa cuenta/i }))
    await waitFor(() => expect(h.adoptActiveAccount).toHaveBeenCalledTimes(2))
    expect(h.post).toHaveBeenCalledTimes(1) // no vuelve a aceptar
  })
})

describe("con sesión y OTRA identidad, o token vencido / revocado / usado — UN solo mensaje", () => {
  const UNAVAILABLE = /esta invitación no está disponible para tu usuario: puede haber vencido o ser para otro email/i

  it("la vista previa 404 muestra el mensaje único con «Cerrar sesión e ingresar con otro email»", async () => {
    h.get.mockRejectedValue(problem("P404: invalid or expired invitation token", 404, "P0404"))
    renderScreen()

    expect(await screen.findByText(UNAVAILABLE)).toBeInTheDocument()
    expect(screen.queryByText("Panadería Sol")).toBeNull()
    expect(screen.queryByRole("button", { name: /aceptar invitación/i })).toBeNull()
  })

  it("el mensaje es EL MISMO ante cualquier 404 (no distingue vencida de ajena)", async () => {
    const mensajes = new Set<string>()
    for (const detail of ["P404: invalid or expired invitation token", "otro texto de la base", "token revocado"]) {
      h.get.mockRejectedValue(problem(detail, 404, "P0404"))
      const { container, unmount } = renderScreen()
      await screen.findByText(UNAVAILABLE)
      mensajes.add(container.textContent ?? "")
      unmount()
    }
    expect(mensajes.size).toBe(1)
  })

  it("aceptar con un 404 (se revocó mientras miraba) cae en el mismo mensaje", async () => {
    h.post.mockRejectedValue(problem("P404: invalid or expired invitation token", 404, "P0404"))
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    expect(await screen.findByText(UNAVAILABLE)).toBeInTheDocument()
    expect(h.adoptActiveAccount).not.toHaveBeenCalled()
  })

  it("«Cerrar sesión e ingresar con otro email» cierra la sesión y vuelve a ESTA invitación", async () => {
    h.get.mockRejectedValue(problem("P404: invalid or expired invitation token", 404, "P0404"))
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /cerrar sesión e ingresar con otro email/i }))

    await waitFor(() => expect(h.logout).toHaveBeenCalledWith({ returnTo: `/invitacion/${TOKEN}` }))
  })
})

describe("ya es miembro", () => {
  it("la vista previa informa «Ya sos parte» y ofrece cambiar a esa cuenta (no ofrece aceptar)", async () => {
    h.get.mockResolvedValue({ ...PREVIEW, already_member: true })
    renderScreen()

    expect(await screen.findByText(/ya sos parte de panadería sol/i)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /aceptar invitación/i })).toBeNull()
    fireEvent.click(screen.getByRole("button", { name: /cambiar a esa cuenta/i }))
    await waitFor(() => expect(h.switchAccount).toHaveBeenCalledWith("acc-negocio"))
  })

  it("aceptar y recibir 409 (ya era miembro) cae en el mismo estado, sin duplicar la membresía", async () => {
    h.post.mockRejectedValue(problem("P409: caller is already a member of account x", 409, "P0409"))
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    expect(await screen.findByText(/ya sos parte de panadería sol/i)).toBeInTheDocument()
    expect(h.adoptActiveAccount).not.toHaveBeenCalled()
  })
})

describe("otros fallos", () => {
  it("el cupo del plan del negocio lo dice claro", async () => {
    h.post.mockRejectedValue(problem("P403: member quota reached (2 / 2)", 403, "P0402"))
    renderScreen()
    fireEvent.click(await screen.findByRole("button", { name: /aceptar invitación/i }))

    expect(await screen.findByText(/alcanzó el máximo de usuarios/i)).toBeInTheDocument()
  })

  it("un fallo de red al cargar NO se hace pasar por «no disponible»: ofrece reintentar", async () => {
    h.get.mockRejectedValueOnce(new Error("Failed to fetch"))
    renderScreen()

    expect(await screen.findByText(/no pudimos cargar la invitación/i)).toBeInTheDocument()
    expect(screen.queryByText(/no está disponible para tu usuario/i)).toBeNull()
    h.get.mockResolvedValue(PREVIEW)
    fireEvent.click(screen.getByRole("button", { name: /reintentar/i }))
    expect(await screen.findByText(/te invitaron a sumarte a panadería sol/i)).toBeInTheDocument()
  })
})
