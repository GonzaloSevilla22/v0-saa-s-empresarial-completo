/**
 * seguros-perfil-asesor (task 4.3-4.5): tracking por vía de contacto.
 * `insuranceService.incrementContactClick(id, channel)` llama al RPC nuevo
 * `increment_seguros_contact_click(row_id, channel)` (migración
 * 20261017000001) con el MISMO contrato fire-and-forget que
 * `incrementClicks` (decisión PO 2026-08-01): ante cualquier error, loguea
 * y NO re-lanza, y en ningún caso cae en una escritura directa a la tabla.
 *
 * No toca frontend/__tests__/seguros-click-tracking.test.tsx (red de
 * seguridad de la función existente `increment_seguros_clicks`; corre sin
 * editarse — ver task 4.6).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

const { rpcMock, schemaMock } = vi.hoisted(() => ({
  rpcMock: vi.fn(),
  schemaMock: vi.fn(),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: rpcMock,
    schema: schemaMock,
  }),
}))

import { insuranceService } from "@/lib/services/insuranceService"

beforeEach(() => {
  rpcMock.mockReset()
  schemaMock.mockReset()
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe("insuranceService.incrementContactClick", () => {
  it("llama a increment_seguros_contact_click con row_id y channel", async () => {
    rpcMock.mockResolvedValue({ error: null })

    await insuranceService.incrementContactClick("advisor-1", "whatsapp")

    expect(rpcMock).toHaveBeenCalledTimes(1)
    expect(rpcMock).toHaveBeenCalledWith("increment_seguros_contact_click", {
      row_id: "advisor-1",
      channel: "whatsapp",
    })
  })

  it("pasa el id y el channel recibidos, no valores fijos", async () => {
    rpcMock.mockResolvedValue({ error: null })

    await insuranceService.incrementContactClick("otro-advisor", "email")

    expect(rpcMock).toHaveBeenCalledWith("increment_seguros_contact_click", {
      row_id: "otro-advisor",
      channel: "email",
    })
  })

  it("acepta una vía fuera del conjunto cerrado sin lanzar (la función valida server-side)", async () => {
    rpcMock.mockResolvedValue({ error: null })

    await expect(
      // @ts-expect-error -- probando robustez ante un valor no perteneciente a ContactChannel
      insuranceService.incrementContactClick("advisor-1", "carrier-pigeon")
    ).resolves.toBeUndefined()

    expect(rpcMock).toHaveBeenCalledWith("increment_seguros_contact_click", {
      row_id: "advisor-1",
      channel: "carrier-pigeon",
    })
  })

  it("ante error del RPC loguea sin re-lanzar y no cae en una escritura directa a la tabla", async () => {
    const rpcError = { message: "permission denied", code: "42501" }
    rpcMock.mockResolvedValue({ error: rpcError })
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    await expect(insuranceService.incrementContactClick("advisor-1", "phone")).resolves.toBeUndefined()

    expect(consoleErrorSpy).toHaveBeenCalled()
    expect(schemaMock).not.toHaveBeenCalled()
  })

  it("tampoco re-lanza si el cliente rechaza (error de red)", async () => {
    rpcMock.mockRejectedValue(new Error("network down"))
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    await expect(insuranceService.incrementContactClick("advisor-1", "web")).resolves.toBeUndefined()

    expect(consoleErrorSpy).toHaveBeenCalled()
    expect(schemaMock).not.toHaveBeenCalled()
  })
})
