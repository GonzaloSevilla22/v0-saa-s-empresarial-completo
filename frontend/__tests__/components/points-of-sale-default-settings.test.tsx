/**
 * punto-venta-seleccion (tasks 5.1/5.2) — Configuración → Datos fiscales →
 * Puntos de venta: badge "Predeterminado", acciones accesibles para marcarlo y
 * quitarlo, y una línea que explica para qué sirve cuando hace falta.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

import type { PointOfSale } from "@/hooks/data/use-points-of-sale"

const { state, setDefaultMock, clearDefaultMock, deactivateMock } = vi.hoisted(() => ({
  state: { pointsOfSale: [] as PointOfSale[] },
  setDefaultMock: vi.fn(),
  clearDefaultMock: vi.fn(),
  deactivateMock: vi.fn(),
}))

vi.mock("@/hooks/data/use-points-of-sale", () => ({
  usePointsOfSale: () => ({ pointsOfSale: state.pointsOfSale, isLoading: false, isError: false }),
  useCreatePointOfSale: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useDeactivatePointOfSale: () => ({ mutateAsync: deactivateMock, isPending: false }),
  useSetDefaultPointOfSale: () => ({ mutateAsync: setDefaultMock, isPending: false }),
  useClearDefaultPointOfSale: () => ({ mutateAsync: clearDefaultMock, isPending: false }),
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({
  useFiscalProfile: () => ({ profile: { id: "fp-1", ivaCondition: "monotributista" } }),
  useUpsertFiscalProfile: () => ({ mutateAsync: vi.fn(), isPending: false }),
  isValidCuit: () => true,
}))

import { PointsOfSaleSection } from "@/components/settings/FiscalSettings"

const base = { fiscalProfileId: "fp-1", accountId: "acc-1", branchId: null, createdAt: "2026-09-26T00:00:00Z" }
const pv = (id: string, numero: number, isActive = true, isDefault = false): PointOfSale =>
  ({ ...base, id, numero, isActive, isDefault })

const EXPLAINER = /se usa si no elegís otro al facturar/i

beforeEach(() => {
  setDefaultMock.mockReset()
  clearDefaultMock.mockReset()
  deactivateMock.mockReset()
})

describe("PointsOfSaleSection — punto de venta predeterminado", () => {
  it("muestra el badge en el predeterminado y el formato de ARCA (0003)", () => {
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999, true, true)]
    render(<PointsOfSaleSection />)
    const row9999 = screen.getByTestId("pv-row-pv-9999")
    expect(within(row9999).getByText("Predeterminado")).toBeInTheDocument()
    expect(within(screen.getByTestId("pv-row-pv-3")).queryByText("Predeterminado")).toBeNull()
    expect(screen.getByText("PV 0003")).toBeInTheDocument()
  })

  it("ofrece «Usar como predeterminado» en los activos que no lo son y «Quitar predeterminado» en el que lo es", () => {
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999, true, true)]
    render(<PointsOfSaleSection />)
    expect(screen.getByRole("button", { name: "Usar PV 0003 como predeterminado" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Usar PV 9999 como predeterminado" })).toBeNull()
    expect(screen.getByRole("button", { name: "Quitar PV 9999 como predeterminado" })).toBeInTheDocument()
    // La desactivación también tiene nombre accesible (antes era sólo un ícono).
    expect(screen.getByRole("button", { name: "Desactivar PV 0003" })).toBeInTheDocument()
  })

  it("marcar llama a la mutación con el id; quitar llama a la de limpiar", async () => {
    const user = userEvent.setup()
    setDefaultMock.mockResolvedValueOnce(undefined)
    clearDefaultMock.mockResolvedValueOnce(undefined)
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999, true, true)]
    render(<PointsOfSaleSection />)

    await user.click(screen.getByRole("button", { name: "Usar PV 0003 como predeterminado" }))
    expect(setDefaultMock).toHaveBeenCalledWith("pv-3")

    await user.click(screen.getByRole("button", { name: "Quitar PV 9999 como predeterminado" }))
    expect(clearDefaultMock).toHaveBeenCalledTimes(1)
  })

  it("con dos activos y ningún predeterminado explica para qué sirve marcar uno", () => {
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999)]
    render(<PointsOfSaleSection />)
    expect(screen.getByText(EXPLAINER)).toBeInTheDocument()
  })

  it("TRIANGULATE: la explicación no aparece con predeterminado ni con un solo activo", () => {
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999, true, true)]
    const { unmount } = render(<PointsOfSaleSection />)
    expect(screen.queryByText(EXPLAINER)).toBeNull()
    unmount()

    state.pointsOfSale = [pv("pv-3", 3), pv("pv-1", 1, false)]
    render(<PointsOfSaleSection />)
    expect(screen.queryByText(EXPLAINER)).toBeNull()
    // Con un solo activo no hay nada que predeterminar.
    expect(screen.queryByRole("button", { name: /como predeterminado/ })).toBeNull()
  })

  it("si el backend rechaza, el error se muestra", async () => {
    const user = userEvent.setup()
    setDefaultMock.mockRejectedValueOnce(new Error("No tenés permisos para esta acción"))
    state.pointsOfSale = [pv("pv-3", 3), pv("pv-9999", 9999)]
    render(<PointsOfSaleSection />)
    await user.click(screen.getByRole("button", { name: "Usar PV 0003 como predeterminado" }))
    await waitFor(() => expect(screen.getByText("No tenés permisos para esta acción")).toBeInTheDocument())
  })
})
