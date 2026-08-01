/**
 * TDD tests for seguros click tracking:
 * - insuranceService.incrementClicks llama al RPC atómico
 *   public.increment_seguros_clicks (sin fallback select+update no atómico)
 *   y ante error loguea sin re-lanzar (decisión PO 2026-08-01: el tracking
 *   jamás rompe la UX)
 * - SegurosPage registra el click al abrir "Más información" (fire-and-forget,
 *   sin bloquear la navegación al contact_url)
 * Mocks: @/lib/supabase/client (rpc + schema/from chain)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

// vi.hoisted: insuranceService llama createClient() a nivel de módulo, así que
// la factory del mock corre durante el import — los mocks tienen que existir antes
const { rpcMock, schemaMock, fromMock, selectMock, eqMock, orderMock, updateMock, singleMock } =
  vi.hoisted(() => ({
    rpcMock: vi.fn(),
    schemaMock: vi.fn(),
    fromMock: vi.fn(),
    selectMock: vi.fn(),
    eqMock: vi.fn(),
    orderMock: vi.fn(),
    updateMock: vi.fn(),
    singleMock: vi.fn(),
  }))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: rpcMock,
    schema: schemaMock,
  }),
}))

import { insuranceService, Insurance } from "@/lib/services/insuranceService"
import SegurosPage from "@/app/(dashboard)/seguros/page"

function makeInsurance(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "seguro-1",
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

function mockVisibleInsurances(rows: Insurance[]) {
  // schema("community").from("seguros").select("*").eq("is_visible", true).order(...)
  const chain = {
    select: selectMock,
    eq: eqMock,
    order: orderMock,
    update: updateMock,
    single: singleMock,
  }
  schemaMock.mockReturnValue({ from: fromMock })
  fromMock.mockReturnValue(chain)
  selectMock.mockReturnValue(chain)
  eqMock.mockReturnValue(chain)
  orderMock.mockResolvedValue({ data: rows, error: null })
}

beforeEach(() => {
  rpcMock.mockReset()
  schemaMock.mockReset()
  fromMock.mockReset()
  selectMock.mockReset()
  eqMock.mockReset()
  orderMock.mockReset()
  updateMock.mockReset()
  singleMock.mockReset()
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe("insuranceService.incrementClicks", () => {
  it("llama al RPC increment_seguros_clicks con row_id", async () => {
    rpcMock.mockResolvedValue({ error: null })

    await insuranceService.incrementClicks("seguro-1")

    expect(rpcMock).toHaveBeenCalledTimes(1)
    expect(rpcMock).toHaveBeenCalledWith("increment_seguros_clicks", { row_id: "seguro-1" })
  })

  it("pasa el id recibido, no un valor fijo", async () => {
    rpcMock.mockResolvedValue({ error: null })

    await insuranceService.incrementClicks("otro-seguro-99")

    expect(rpcMock).toHaveBeenCalledWith("increment_seguros_clicks", { row_id: "otro-seguro-99" })
  })

  it("ante error del RPC loguea sin re-lanzar y sin ejecutar el fallback select+update", async () => {
    const rpcError = { message: "permission denied", code: "42501" }
    rpcMock.mockResolvedValue({ error: rpcError })
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    // No debe tirar: el tracking es fire-and-forget por contrato
    await expect(insuranceService.incrementClicks("seguro-1")).resolves.toBeUndefined()

    expect(consoleErrorSpy).toHaveBeenCalled()
    // El fallback no atómico fue eliminado: ante error NO debe tocar la tabla
    expect(schemaMock).not.toHaveBeenCalled()
    expect(updateMock).not.toHaveBeenCalled()
  })

  it("tampoco re-lanza si el cliente rechaza (error de red)", async () => {
    rpcMock.mockRejectedValue(new Error("network down"))
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    await expect(insuranceService.incrementClicks("seguro-1")).resolves.toBeUndefined()

    expect(consoleErrorSpy).toHaveBeenCalled()
    expect(schemaMock).not.toHaveBeenCalled()
  })
})

describe("SegurosPage — tracking de clicks en 'Más información'", () => {
  it("registra el click con el id del seguro clickeado", async () => {
    mockVisibleInsurances([
      makeInsurance(),
      makeInsurance({ id: "seguro-2", title: "Seguro Flota Reparto" }),
    ])
    rpcMock.mockResolvedValue({ error: null })

    render(<SegurosPage />)

    const links = await screen.findAllByRole("link", { name: /más información/i })
    expect(links).toHaveLength(2)

    await userEvent.click(links[1])

    await waitFor(() => {
      expect(rpcMock).toHaveBeenCalledWith("increment_seguros_clicks", { row_id: "seguro-2" })
    })
    expect(rpcMock).toHaveBeenCalledTimes(1)
  })

  it("mantiene el link de contacto intacto (nueva pestaña, sin bloquear navegación)", async () => {
    mockVisibleInsurances([makeInsurance()])
    rpcMock.mockResolvedValue({ error: null })

    render(<SegurosPage />)

    const link = await screen.findByRole("link", { name: /más información/i })
    expect(link).toHaveAttribute("href", "https://aseguradora.example.com/contacto")
    expect(link).toHaveAttribute("target", "_blank")
    expect(link).toHaveAttribute("rel", "noopener noreferrer")
  })

  it("un fallo del RPC no rompe la página (fire-and-forget)", async () => {
    mockVisibleInsurances([makeInsurance()])
    rpcMock.mockResolvedValue({ error: { message: "boom", code: "XX000" } })
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    render(<SegurosPage />)

    const link = await screen.findByRole("link", { name: /más información/i })
    await userEvent.click(link)

    await waitFor(() => {
      expect(rpcMock).toHaveBeenCalledTimes(1)
    })
    // La card sigue renderizada y no hubo unhandled rejection que tumbe el test
    expect(screen.getByText("Seguro Integral Comercio")).toBeInTheDocument()
    await waitFor(() => {
      expect(consoleErrorSpy).toHaveBeenCalled()
    })
  })
})
