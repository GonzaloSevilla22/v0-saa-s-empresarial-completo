/**
 * factura-fiscal-imprimible (tasks 3.3/3.4) — Configuración → Datos fiscales →
 * "Datos para imprimir la factura".
 *
 * - Muestra un aviso que NOMBRA lo que falta para imprimir mientras falte algo.
 * - Envía sólo los campos que el usuario tocó (el backend es tri-estado:
 *   ausente = conservar, null = borrar), más cuit/iva/ambiente del perfil que
 *   exige el schema del endpoint.
 * - Inicio de actividades es una fecha y no puede ser futura.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

import type { FiscalProfile } from "@/hooks/data/use-fiscal-profile"

const { state, upsertMock } = vi.hoisted(() => ({
  state: { profile: null as FiscalProfile | null },
  upsertMock: vi.fn(),
}))

vi.mock("@/hooks/data/use-points-of-sale", () => ({
  usePointsOfSale: () => ({ pointsOfSale: [], isLoading: false, isError: false }),
  useCreatePointOfSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useDeactivatePointOfSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useSetDefaultPointOfSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useClearDefaultPointOfSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: state.profile, isLoading: false }),
  useUpsertFiscalProfile: () => ({ mutateAsync: upsertMock, isPending: false }),
  isValidCuit: () => true,
}))

import { IssuerPrintDataSection } from "@/components/settings/FiscalSettings"

const perfil = (overrides: Partial<FiscalProfile> = {}): FiscalProfile => ({
  id: "fp-1",
  accountId: "acc-1",
  cuit: "20-12345678-6",
  ivaCondition: "monotributista",
  iibbCondition: null,
  certificadoAfipPath: null,
  ambiente: "produccion",
  createdAt: "2026-09-26T00:00:00Z",
  delegacionAutorizada: true,
  platformRepresentanteCuit: null,
  razonSocial: "PEREZ MARIA LAURA",
  nombreFantasia: null,
  domicilioComercial: null,
  iibbNumero: "0712345",
  inicioActividades: null,
  ...overrides,
})

beforeEach(() => {
  upsertMock.mockReset()
  upsertMock.mockResolvedValue(perfil())
})

describe("IssuerPrintDataSection", () => {
  it("avisa qué falta para imprimir, con nombres legibles", () => {
    state.profile = perfil()
    render(<IssuerPrintDataSection />)

    const aviso = screen.getByRole("alert")
    expect(aviso).toHaveTextContent(/para imprimir tus facturas/i)
    expect(aviso).toHaveTextContent("el domicilio comercial y la fecha de inicio de actividades")
  })

  it("sin faltantes no hay aviso", () => {
    state.profile = perfil({ domicilioComercial: "Av. San Martín 1234, Mendoza", inicioActividades: "2019-03-01" })
    render(<IssuerPrintDataSection />)

    expect(screen.queryByRole("alert")).toBeNull()
  })

  it("muestra los cinco campos, con inicio de actividades como fecha", () => {
    state.profile = perfil()
    render(<IssuerPrintDataSection />)

    expect(screen.getByLabelText(/razón social/i)).toHaveValue("PEREZ MARIA LAURA")
    expect(screen.getByLabelText(/nombre de fantasía/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/domicilio comercial/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/número de ingresos brutos/i)).toHaveValue("0712345")
    expect(screen.getByLabelText(/inicio de actividades/i)).toHaveAttribute("type", "date")
  })

  it("envía sólo los campos tocados, con los datos base del perfil", async () => {
    state.profile = perfil()
    const user = userEvent.setup()
    render(<IssuerPrintDataSection />)

    await user.type(screen.getByLabelText(/domicilio comercial/i), "Av. San Martín 1234, Mendoza")
    await user.click(screen.getByRole("button", { name: /guardar datos para imprimir/i }))

    await waitFor(() => expect(upsertMock).toHaveBeenCalledTimes(1))
    expect(upsertMock).toHaveBeenCalledWith({
      cuit: "20-12345678-6",
      iva_condition: "monotributista",
      ambiente: "produccion",
      domicilio_comercial: "Av. San Martín 1234, Mendoza",
    })
  })

  it("vaciar un campo lo borra (null explícito)", async () => {
    state.profile = perfil({ nombreFantasia: "Sumar" })
    const user = userEvent.setup()
    render(<IssuerPrintDataSection />)

    await user.clear(screen.getByLabelText(/nombre de fantasía/i))
    await user.click(screen.getByRole("button", { name: /guardar datos para imprimir/i }))

    await waitFor(() => expect(upsertMock).toHaveBeenCalledTimes(1))
    const payload = upsertMock.mock.calls[0][0] as Record<string, unknown>
    expect(payload.nombre_fantasia).toBeNull()
    expect("razon_social" in payload).toBe(false)
  })

  it("rechaza un inicio de actividades futuro sin llamar al backend", async () => {
    state.profile = perfil()
    const user = userEvent.setup()
    render(<IssuerPrintDataSection />)

    // Un <input type="date"> no se tipea carácter a carácter en jsdom: se
    // setea el valor como lo hace el selector nativo del navegador.
    fireEvent.change(screen.getByLabelText(/inicio de actividades/i), {
      target: { value: "2999-01-01" },
    })
    await user.click(screen.getByRole("button", { name: /guardar datos para imprimir/i }))

    expect(await screen.findByText(/no puede ser posterior a hoy/i)).toBeInTheDocument()
    expect(upsertMock).not.toHaveBeenCalled()
  })

  it("sin perfil fiscal pide guardar primero los datos fiscales", () => {
    state.profile = null
    render(<IssuerPrintDataSection />)

    expect(screen.getByText(/guardá primero los datos fiscales/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /guardar datos para imprimir/i })).toBeDisabled()
  })
})
