/**
 * presupuestos-modulo (D7, tarea 5.11) — `QuoteSettingsCard`: validez por defecto
 * de los presupuestos, en la pestaña Cobranzas de /configuracion.
 *
 *  - owner/admin la editan (1..365 días; el servidor valida igual: 422/`P0400`);
 *  - el resto de los roles la ve en sólo lectura (la RPC exige `CAN_CONFIGURE`);
 *  - mientras los roles no resolvieron rige el fail-open del resto de la app
 *    (`hasCapability`): el servidor rechaza con `P0403` a quien no corresponda.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  settings: { value: { defaultQuoteValidityDays: 15 } as { defaultQuoteValidityDays: number } | undefined },
  save: vi.fn(),
  isPending: { value: false },
  useOrgRole: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
}))

vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess } }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-quotes", () => ({
  useQuoteSettings: () => ({ data: mocks.settings.value, isLoading: mocks.settings.value === undefined }),
  useUpdateQuoteSettings: () => ({ mutateAsync: mocks.save, isPending: mocks.isPending.value }),
}))

import { QuoteSettingsCard } from "@/components/quotes/QuoteSettingsCard"

function asRoles(roles: string[], resolved = true) {
  mocks.useOrgRole.mockReturnValue({ role: roles[0], roles, rolesResolved: resolved, isWriter: true, isLoading: false })
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.settings.value = { defaultQuoteValidityDays: 15 }
  mocks.isPending.value = false
  mocks.save.mockResolvedValue({ defaultQuoteValidityDays: 20 })
  asRoles(["owner"])
})

describe("QuoteSettingsCard — edición (owner/admin)", () => {
  it("precarga la validez persistida", () => {
    render(<QuoteSettingsCard />)

    expect(screen.getByLabelText(/días de validez/i)).toHaveValue(15)
  })

  it.each([["owner"], ["admin"]])("un %s puede editar y guardar", async (role) => {
    asRoles([role])
    render(<QuoteSettingsCard />)

    fireEvent.change(screen.getByLabelText(/días de validez/i), { target: { value: "20" } })
    fireEvent.click(screen.getByRole("button", { name: /guardar validez/i }))

    await waitFor(() => expect(mocks.save).toHaveBeenCalledWith(20))
    expect(mocks.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/20 días/))
  })

  it.each([["0"], ["366"], ["-3"], ["1.5"], [""]])("rechaza %j antes de llamar a la API", (value) => {
    render(<QuoteSettingsCard />)

    fireEvent.change(screen.getByLabelText(/días de validez/i), { target: { value } })
    fireEvent.click(screen.getByRole("button", { name: /guardar validez/i }))

    expect(mocks.toastError).toHaveBeenCalledWith(expect.stringMatching(/entre 1 y 365/i))
    expect(mocks.save).not.toHaveBeenCalled()
  })

  it.each([["1"], ["365"]])("acepta el borde %s", async (value) => {
    render(<QuoteSettingsCard />)

    fireEvent.change(screen.getByLabelText(/días de validez/i), { target: { value } })
    fireEvent.click(screen.getByRole("button", { name: /guardar validez/i }))

    await waitFor(() => expect(mocks.save).toHaveBeenCalledWith(Number(value)))
  })

  it("con 1 día usa el singular en el aviso", async () => {
    render(<QuoteSettingsCard />)

    fireEvent.change(screen.getByLabelText(/días de validez/i), { target: { value: "1" } })
    fireEvent.click(screen.getByRole("button", { name: /guardar validez/i }))

    await waitFor(() => expect(mocks.toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/1 día(?!s)/)))
  })

  it("si el servidor rechaza (por ejemplo por rol) muestra el mensaje traducido", async () => {
    mocks.save.mockRejectedValue(new Error("insufficient_role"))
    render(<QuoteSettingsCard />)

    fireEvent.change(screen.getByLabelText(/días de validez/i), { target: { value: "20" } })
    fireEvent.click(screen.getByRole("button", { name: /guardar validez/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastError.mock.calls[0][0]).toMatch(/tu rol no permite/i)
  })

  it("mientras guarda deshabilita el botón", () => {
    mocks.isPending.value = true
    render(<QuoteSettingsCard />)

    expect(screen.getByRole("button", { name: /guardando/i })).toBeDisabled()
  })

  it("el texto de ayuda explica que no reescribe presupuestos ya hechos", () => {
    render(<QuoteSettingsCard />)

    expect(screen.getByText(/no cambia los presupuestos ya creados/i)).toBeInTheDocument()
  })
})

describe("QuoteSettingsCard — sólo lectura", () => {
  it.each([["seller"], ["cashier"], ["stock"]])("un usuario sólo %s ve el valor pero no puede editarlo", (role) => {
    asRoles([role])
    render(<QuoteSettingsCard />)

    expect(screen.queryByLabelText(/días de validez/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /guardar validez/i })).not.toBeInTheDocument()
    expect(screen.getByTestId("quote-validity-readonly")).toHaveTextContent(/15 días/)
    expect(screen.getByText(/dueño o un administrador/i)).toBeInTheDocument()
  })

  it("sólo lectura con 1 día usa el singular", () => {
    mocks.settings.value = { defaultQuoteValidityDays: 1 }
    asRoles(["seller"])
    render(<QuoteSettingsCard />)

    expect(screen.getByTestId("quote-validity-readonly")).toHaveTextContent(/1 día(?!s)/)
  })

  it("con el rol sin resolver es fail-open: muestra el formulario (la barrera real es la RPC con CAN_CONFIGURE)", () => {
    asRoles(["member"], false)
    render(<QuoteSettingsCard />)

    expect(screen.getByLabelText(/días de validez/i)).toBeInTheDocument()
  })

  it("mientras la validez no cargó no inventa un valor en la vista de sólo lectura", () => {
    mocks.settings.value = undefined
    asRoles(["seller"])
    render(<QuoteSettingsCard />)

    expect(screen.getByTestId("quote-validity-readonly")).toHaveTextContent("—")
  })
})
