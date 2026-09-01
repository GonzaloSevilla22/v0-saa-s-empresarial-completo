/**
 * seguros-perfil-asesor (task 7.1/7.6): /admin/seguros edita todos los
 * campos nuevos del perfil de asesor. Cubre los escenarios del delta spec:
 * alta completa de un asesor, el formulario de oferta legacy sigue
 * operando sin exigir campos de asesor, reordenar una lista se persiste,
 * guardar sin slug / con slug duplicado falla con mensaje claro (no un
 * error crudo de Postgres), y el desglose de clicks por vía es visible.
 *
 * Mockea el servicio (createInsurance/updateInsurance/getAllInsurances/
 * getAdminStats/toggleInsuranceVisibility) y `sonner` (toast) para poder
 * aserter los mensajes mostrados sin acoplar el test a la UI del toast.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Insurance } from "@/lib/services/insuranceService"

const {
  getAllInsurancesMock,
  getAdminStatsMock,
  createInsuranceMock,
  updateInsuranceMock,
  toggleInsuranceVisibilityMock,
  deleteInsuranceMock,
  toastErrorMock,
  toastSuccessMock,
} = vi.hoisted(() => ({
  getAllInsurancesMock: vi.fn(),
  getAdminStatsMock: vi.fn(),
  createInsuranceMock: vi.fn(),
  updateInsuranceMock: vi.fn(),
  toggleInsuranceVisibilityMock: vi.fn(),
  deleteInsuranceMock: vi.fn(),
  toastErrorMock: vi.fn(),
  toastSuccessMock: vi.fn(),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: vi.fn(), schema: vi.fn() }),
}))

vi.mock("sonner", () => ({
  toast: { error: toastErrorMock, success: toastSuccessMock },
}))

vi.mock("@/lib/services/insuranceService", async () => {
  const actual = await vi.importActual<typeof import("@/lib/services/insuranceService")>(
    "@/lib/services/insuranceService"
  )
  return {
    ...actual,
    insuranceService: {
      ...actual.insuranceService,
      getAllInsurances: getAllInsurancesMock,
      getAdminStats: getAdminStatsMock,
      createInsurance: createInsuranceMock,
      updateInsurance: updateInsuranceMock,
      toggleInsuranceVisibility: toggleInsuranceVisibilityMock,
      deleteInsurance: deleteInsuranceMock,
    },
  }
})

import AdminSegurosPage from "@/app/(dashboard)/admin/seguros/page"

function makeOffer(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "offer-1",
    title: "Seguro Integral Comercio",
    description: "Cobertura completa para tu local",
    coverage: "Incendio, robo y responsabilidad civil",
    price: "Desde $15.000/mes",
    contact_url: "https://aseguradora.example.com/contacto",
    is_visible: true,
    created_at: "2026-03-01T00:00:00.000Z",
    updated_at: "2026-03-01T00:00:00.000Z",
    ...overrides,
  }
}

const baseStats = {
  total: 1,
  visible: 1,
  hidden: 0,
  totalClicks: 6,
  timeSeries: [],
  channelClicks: { whatsapp: 3, email: 1, phone: 0, web: 2 },
}

beforeEach(() => {
  getAllInsurancesMock.mockReset()
  getAdminStatsMock.mockReset().mockResolvedValue(baseStats)
  createInsuranceMock.mockReset().mockResolvedValue({})
  updateInsuranceMock.mockReset().mockResolvedValue({})
  toggleInsuranceVisibilityMock.mockReset()
  deleteInsuranceMock.mockReset()
  toastErrorMock.mockReset()
  toastSuccessMock.mockReset()
})

async function openCreateDialog() {
  const user = userEvent.setup()
  render(<AdminSegurosPage />)
  await screen.findByText(/listado detallado/i)
  await user.click(screen.getByRole("button", { name: /crear seguro/i }))
  return user
}

async function selectEntryType(user: ReturnType<typeof userEvent.setup>, label: "Oferta" | "Asesor") {
  await user.click(screen.getByRole("combobox", { name: /tipo de entrada/i }))
  await user.click(await screen.findByRole("option", { name: label }))
}

describe("AdminSegurosPage — alta completa de un asesor", () => {
  it("crea un asesor con identidad, matrícula, listas, zonas y las 4 vías de contacto", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    const user = await openCreateDialog()

    await selectEntryType(user, "Asesor")

    await user.type(screen.getByLabelText(/título/i), "Julián Dupás — PAS")
    await user.type(screen.getByLabelText(/nombre del asesor/i), "Julián Dupás")
    await user.type(screen.getByLabelText(/^rol$/i), "Productor Asesor de Seguros")
    await user.type(screen.getByLabelText(/^slug$/i), "julian-dupas")
    await user.type(screen.getByLabelText(/matrícula/i), "98506")
    await user.type(screen.getByLabelText(/whatsapp/i), "5492266474348")
    await user.type(screen.getByLabelText(/^email$/i), "julian@argbroker.com.ar")
    await user.type(screen.getByLabelText(/^teléfono$/i), "2266 474348")
    await user.type(screen.getByLabelText(/sitio web/i), "https://www.argbroker.com.ar")

    await user.click(screen.getByRole("button", { name: /agregar línea de servicio/i }))
    await user.type(screen.getByLabelText(/título de línea de servicio 1/i), "Autos y motos")
    await user.type(screen.getByLabelText(/descripción de línea de servicio 1/i), "Coberturas adaptadas.")

    await user.click(screen.getByRole("button", { name: /agregar pilar/i }))
    await user.type(screen.getByLabelText(/título de pilar 1/i), "Transparencia")
    await user.type(screen.getByLabelText(/contenido de pilar 1/i), "Explico todo antes de firmar.")

    await user.type(screen.getByLabelText(/agregar zona de cobertura/i), "Mendoza")
    await user.click(screen.getByRole("button", { name: /^agregar zona$/i }))

    await user.click(screen.getByRole("button", { name: /crear seguro/i }))

    await waitFor(() => expect(createInsuranceMock).toHaveBeenCalledTimes(1))
    const payload = createInsuranceMock.mock.calls[0][0]
    expect(payload).toMatchObject({
      entry_type: "advisor",
      slug: "julian-dupas",
      advisor_name: "Julián Dupás",
      license_number: "98506",
      contact_whatsapp: "5492266474348",
      contact_email: "julian@argbroker.com.ar",
      contact_phone: "2266 474348",
      contact_url: "https://www.argbroker.com.ar",
    })
    expect(payload.service_lines).toEqual([{ title: "Autos y motos", description: "Coberturas adaptadas." }])
    expect(payload.pillars).toEqual([{ title: "Transparencia", body: "Explico todo antes de firmar." }])
    expect(payload.coverage_areas).toEqual(["Mendoza"])
  })
})

describe("AdminSegurosPage — la oferta legacy sigue operando", () => {
  it("edita una oferta sin exigir campos de asesor", async () => {
    const offer = makeOffer()
    getAllInsurancesMock.mockResolvedValue([offer])
    const user = userEvent.setup()
    render(<AdminSegurosPage />)

    await user.click(await screen.findByRole("button", { name: /editar/i }))

    // El tipo sigue en "Oferta" y no aparecen campos propios del asesor
    expect(screen.queryByLabelText(/^slug$/i)).not.toBeInTheDocument()

    const description = screen.getByLabelText(/descripción estratégica/i)
    await user.clear(description)
    await user.type(description, "Descripción actualizada")

    await user.click(screen.getByRole("button", { name: /guardar cambios/i }))

    await waitFor(() => expect(updateInsuranceMock).toHaveBeenCalledTimes(1))
    expect(updateInsuranceMock).toHaveBeenCalledWith(
      "offer-1",
      expect.objectContaining({ description: "Descripción actualizada" })
    )
  })
})

describe("AdminSegurosPage — listas ordenadas", () => {
  it("agregar, reordenar y guardar una lista se persiste en el orden nuevo", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    const user = await openCreateDialog()
    await selectEntryType(user, "Asesor")

    await user.type(screen.getByLabelText(/título/i), "Asesor de prueba")
    await user.type(screen.getByLabelText(/^slug$/i), "asesor-prueba")

    await user.click(screen.getByRole("button", { name: /agregar línea de servicio/i }))
    await user.type(screen.getByLabelText(/título de línea de servicio 1/i), "A")
    await user.type(screen.getByLabelText(/descripción de línea de servicio 1/i), "Primera")

    await user.click(screen.getByRole("button", { name: /agregar línea de servicio/i }))
    await user.type(screen.getByLabelText(/título de línea de servicio 2/i), "B")
    await user.type(screen.getByLabelText(/descripción de línea de servicio 2/i), "Segunda")

    // Sube la línea B (índice 2) por encima de la A
    await user.click(screen.getByRole("button", { name: /subir línea de servicio 2/i }))

    await user.click(screen.getByRole("button", { name: /crear seguro/i }))

    await waitFor(() => expect(createInsuranceMock).toHaveBeenCalledTimes(1))
    const payload = createInsuranceMock.mock.calls[0][0]
    expect(payload.service_lines).toEqual([
      { title: "B", description: "Segunda" },
      { title: "A", description: "Primera" },
    ])
  })
})

describe("AdminSegurosPage — validación con mensaje claro", () => {
  it("guardar un asesor sin slug falla con un mensaje claro, sin llamar al servicio", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    const user = await openCreateDialog()
    await selectEntryType(user, "Asesor")

    await user.type(screen.getByLabelText(/título/i), "Asesor sin slug")
    // No completa el slug a propósito

    await user.click(screen.getByRole("button", { name: /crear seguro/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalled())
    expect(createInsuranceMock).not.toHaveBeenCalled()
    const [message] = toastErrorMock.mock.calls[0]
    expect(message).not.toMatch(/constraint|check|23505|postgres/i)
    expect(message).toMatch(/slug/i)
  })

  it("guardar un slug duplicado muestra un mensaje claro, no el error crudo de Postgres", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    createInsuranceMock.mockRejectedValue({
      code: "23505",
      message: 'duplicate key value violates unique constraint "idx_seguros_slug_unique"',
    })
    const user = await openCreateDialog()
    await selectEntryType(user, "Asesor")

    await user.type(screen.getByLabelText(/título/i), "Asesor duplicado")
    await user.type(screen.getByLabelText(/^slug$/i), "julian-dupas")

    await user.click(screen.getByRole("button", { name: /crear seguro/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalled())
    const [message] = toastErrorMock.mock.calls[0]
    expect(message).not.toMatch(/constraint|duplicate key|23505/i)
    expect(message).toMatch(/slug/i)
  })

  it("guardar con las listas vacías no falla", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    const user = await openCreateDialog()
    await selectEntryType(user, "Asesor")

    await user.type(screen.getByLabelText(/título/i), "Asesor sin listas")
    await user.type(screen.getByLabelText(/^slug$/i), "asesor-sin-listas")

    await user.click(screen.getByRole("button", { name: /crear seguro/i }))

    await waitFor(() => expect(createInsuranceMock).toHaveBeenCalledTimes(1))
    const payload = createInsuranceMock.mock.calls[0][0]
    expect(payload.service_lines).toEqual([])
    expect(payload.pillars).toEqual([])
  })
})

describe("AdminSegurosPage — métricas", () => {
  it("muestra el desglose de clicks por vía junto al total", async () => {
    getAllInsurancesMock.mockResolvedValue([])
    render(<AdminSegurosPage />)

    await screen.findByText(/listado detallado/i)
    expect(screen.getByText("6")).toBeInTheDocument() // total
    const breakdown = screen.getByTestId("contact-clicks-breakdown")
    expect(within(breakdown).getByText(/whatsapp/i)).toBeInTheDocument()
    expect(within(breakdown).getByText("3")).toBeInTheDocument()
    expect(within(breakdown).getByText("2")).toBeInTheDocument()
  })
})
