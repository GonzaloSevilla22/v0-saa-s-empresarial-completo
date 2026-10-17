/**
 * multiusuario-operativo tanda A (D5) — `AccountSwitcher`.
 *
 * Selector de cuenta activa en el encabezado del menú lateral. Se muestra SÓLO con
 * dos o más cuentas (quien tiene una no ve nada nuevo); muestra el nombre visible
 * de cada negocio (cascada de los documentos, calculada en `lib/accounts.ts`) y el
 * rol del usuario en cada uno; al elegir, delega en `switchAccount` del contexto
 * (que persiste, renueva el token, limpia la caché, avisa a las otras pestañas y
 * lleva al Tablero).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, within, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"
import type { AccountSummary } from "@/lib/accounts"

const switchAccountMock = vi.fn()
const roleCatalogSpy = vi.hoisted(() => vi.fn())
let accountsFixture: AccountSummary[] = []
let userFixture: { accountId: string } | null = { accountId: "acc-p" }

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: userFixture,
    accounts: accountsFixture,
    switchAccount: (...args: unknown[]) => switchAccountMock(...args),
  }),
}))

vi.mock("@/hooks/data/use-role-catalog", () => ({
  useRoleCatalog: () => {
    roleCatalogSpy()
    return {
      data: [
        { code: "owner", label: "Dueño", description: "", sort_order: 1, is_writer: true },
        { code: "seller", label: "Vendedor", description: "", sort_order: 3, is_writer: true },
        { code: "cashier", label: "Cajero", description: "", sort_order: 4, is_writer: true },
      ],
    }
  },
  resolveRoleLabel: (catalog: { code: string; label: string }[] | undefined, code: string) =>
    catalog?.find((entry) => entry.code === code)?.label ?? code,
}))

import { AccountSwitcher } from "@/components/accounts/AccountSwitcher"

function account(overrides: Partial<AccountSummary>): AccountSummary {
  return {
    accountId: "acc-p",
    isActive: true,
    isOwner: true,
    memberRole: "owner",
    roles: ["owner"],
    displayName: "Mi Kiosco",
    billingPlan: "inicial",
    billingStatus: "active",
    trialPlan: undefined,
    trialExpiresAt: undefined,
    planExpiresAt: undefined,
    billingExempt: false,
    effectivePlan: "inicial",
    ...overrides,
  }
}

const personal = account({ accountId: "acc-p", isActive: true, displayName: "Mi Kiosco", roles: ["owner"] })
const business = account({
  accountId: "acc-a",
  isActive: false,
  isOwner: false,
  memberRole: "member",
  displayName: "Ferretería Roca",
  roles: ["seller", "cashier"],
})

beforeEach(() => {
  roleCatalogSpy.mockClear()
  switchAccountMock.mockReset().mockResolvedValue(undefined)
  accountsFixture = [personal, business]
  userFixture = { accountId: "acc-p" }
})

describe("AccountSwitcher — cuándo se muestra", () => {
  it("con UNA sola cuenta no muestra nada (el usuario de hoy no ve cambios)", () => {
    accountsFixture = [personal]
    const { container } = render(<AccountSwitcher />)
    expect(container).toBeEmptyDOMElement()
  })

  it("con una sola cuenta NI SIQUIERA pide el catálogo de roles (la mayoría de los usuarios no paga una lectura de más en cada pantalla)", () => {
    accountsFixture = [personal]
    render(<AccountSwitcher />)
    expect(roleCatalogSpy).not.toHaveBeenCalled()
  })

  it("con dos cuentas sí lo pide (las etiquetas de rol salen del catálogo)", () => {
    render(<AccountSwitcher />)
    expect(roleCatalogSpy).toHaveBeenCalled()
  })

  it("sin cuentas tampoco muestra nada", () => {
    accountsFixture = []
    const { container } = render(<AccountSwitcher />)
    expect(container).toBeEmptyDOMElement()
  })

  it("con dos cuentas muestra el negocio activo y el rol propio en él", () => {
    render(<AccountSwitcher />)
    const trigger = screen.getByRole("button", { name: /cuenta activa/i })
    expect(within(trigger).getByText("Mi Kiosco")).toBeInTheDocument()
    expect(within(trigger).getByText("Dueño")).toBeInTheDocument()
  })
})

describe("AccountSwitcher — la lista", () => {
  it("lista las dos cuentas con su nombre y el rol de cada una, y marca la activa", async () => {
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))

    const items = await screen.findAllByRole("menuitemradio")
    expect(items).toHaveLength(2)
    expect(within(items[0]).getByText("Mi Kiosco")).toBeInTheDocument()
    expect(within(items[0]).getByText("Dueño")).toBeInTheDocument()
    expect(within(items[1]).getByText("Ferretería Roca")).toBeInTheDocument()
    expect(within(items[1]).getByText("Vendedor, Cajero")).toBeInTheDocument()
    expect(items[0]).toHaveAttribute("aria-checked", "true")
    expect(items[1]).toHaveAttribute("aria-checked", "false")
  })

  it("el rol se resuelve contra el catálogo y cae al código crudo si no lo conoce", async () => {
    accountsFixture = [personal, account({ accountId: "acc-x", isActive: false, displayName: "Otro", roles: ["accountant"] })]
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))

    expect(await screen.findByText("accountant")).toBeInTheDocument()
  })
})

describe("AccountSwitcher — cambiar de cuenta", () => {
  it("elegir otra cuenta llama a switchAccount con su id", async () => {
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))
    await user.click(await screen.findByRole("menuitemradio", { name: /Ferretería Roca/ }))

    expect(switchAccountMock).toHaveBeenCalledTimes(1)
    expect(switchAccountMock).toHaveBeenCalledWith("acc-a")
  })

  it("elegir la cuenta que ya está activa NO hace nada", async () => {
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))
    await user.click(await screen.findByRole("menuitemradio", { name: /Mi Kiosco/ }))

    expect(switchAccountMock).not.toHaveBeenCalled()
  })

  it("mientras cambia, el selector queda deshabilitado (un doble click no dispara dos cambios)", async () => {
    let finish: () => void = () => {}
    switchAccountMock.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve
        }),
    )
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))
    await user.click(await screen.findByRole("menuitemradio", { name: /Ferretería Roca/ }))

    await waitFor(() => expect(screen.getByRole("button", { name: /cuenta activa/i })).toBeDisabled())
    finish()
    await waitFor(() => expect(screen.getByRole("button", { name: /cuenta activa/i })).toBeEnabled())
  })

  it("si el cambio falla, el selector se rehabilita y no explota (el contexto ya avisa el error)", async () => {
    switchAccountMock.mockRejectedValue(new Error("La membresía ya no existe"))
    const user = userEvent.setup()
    render(<AccountSwitcher />)

    await user.click(screen.getByRole("button", { name: /cuenta activa/i }))
    await user.click(await screen.findByRole("menuitemradio", { name: /Ferretería Roca/ }))

    await waitFor(() => expect(screen.getByRole("button", { name: /cuenta activa/i })).toBeEnabled())
  })
})

describe("AccountSwitcher — accesibilidad y tamaño de toque", () => {
  it("el disparador y los ítems tienen un alto táctil de 44 px (min-h-11) en móvil", async () => {
    const user = userEvent.setup()
    render(<AccountSwitcher />)
    const trigger = screen.getByRole("button", { name: /cuenta activa/i })
    expect(trigger.className).toMatch(/min-h-11/)

    await user.click(trigger)
    const items = await screen.findAllByRole("menuitemradio")
    for (const item of items) expect(item.className).toMatch(/min-h-11/)
  })

  it("no usa colores literales: sólo tokens semánticos (claro y oscuro)", () => {
    const { container } = render(<AccountSwitcher />)
    expect(container.innerHTML).not.toMatch(/\b(?:text|bg|border)-(?:slate|gray|zinc|neutral|stone|red|green|blue|yellow|emerald|white|black)(?:-\d{2,3})?\b/)
  })
})
