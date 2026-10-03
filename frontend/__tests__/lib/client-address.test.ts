/**
 * remitos-venta (D11, tarea 4.8) — `lib/client-address.ts`: el domicilio de
 * entrega que el remito precarga con el domicilio PRINCIPAL del cliente.
 */
import { describe, it, expect } from "vitest"
import { formatClientAddress, primaryDeliveryAddress } from "@/lib/client-address"
import type { ClientAddress } from "@/lib/types"

function address(overrides: Partial<ClientAddress> = {}): ClientAddress {
  return {
    id: "a-1",
    accountId: "acc-1",
    clientId: "c-1",
    alias: null,
    street: null,
    city: null,
    province: null,
    postalCode: null,
    notes: null,
    isPrimary: false,
    createdAt: "2026-09-01T10:00:00Z",
    updatedAt: null,
    ...overrides,
  }
}

describe("formatClientAddress", () => {
  it("calle, localidad, provincia y código postal entre paréntesis", () => {
    expect(
      formatClientAddress(address({ street: "San Martín 100", city: "Mendoza", province: "Mendoza", postalCode: "5500" })),
    ).toBe("San Martín 100, Mendoza, Mendoza (5500)")
  })

  it("omite lo que falta sin dejar comas sueltas", () => {
    expect(formatClientAddress(address({ street: "Belgrano 25", province: "San Juan" }))).toBe("Belgrano 25, San Juan")
    expect(formatClientAddress(address({ city: "Godoy Cruz" }))).toBe("Godoy Cruz")
  })

  it("el código postal solo va entre paréntesis", () => {
    expect(formatClientAddress(address({ postalCode: "5500" }))).toBe("(5500)")
  })

  it("recorta espacios y descarta textos en blanco", () => {
    expect(formatClientAddress(address({ street: "  Lavalle 50  ", city: "   ", province: "Mendoza" }))).toBe(
      "Lavalle 50, Mendoza",
    )
  })

  it("no incluye alias ni notas (no son parte del domicilio impreso)", () => {
    expect(formatClientAddress(address({ alias: "Casa", street: "Lavalle 50", notes: "Timbre 2" }))).toBe("Lavalle 50")
  })

  it("sin ningún dato: texto vacío", () => {
    expect(formatClientAddress(address())).toBe("")
  })
})

describe("primaryDeliveryAddress", () => {
  it("el domicilio principal, formateado", () => {
    const list = [
      address({ id: "a-1", street: "Otra 1", isPrimary: false }),
      address({ id: "a-2", street: "San Martín 100", city: "Mendoza", isPrimary: true }),
    ]
    expect(primaryDeliveryAddress(list)).toBe("San Martín 100, Mendoza")
  })

  it("sin ninguno marcado como principal usa el primero con datos", () => {
    const list = [address({ id: "a-1" }), address({ id: "a-2", street: "Lavalle 50" })]
    expect(primaryDeliveryAddress(list)).toBe("Lavalle 50")
  })

  it("un principal sin datos cae en el siguiente con datos (nunca precarga vacío si hay algo)", () => {
    const list = [address({ id: "a-1", isPrimary: true }), address({ id: "a-2", street: "Lavalle 50" })]
    expect(primaryDeliveryAddress(list)).toBe("Lavalle 50")
  })

  it("sin direcciones (o sin lista todavía): vacío", () => {
    expect(primaryDeliveryAddress([])).toBe("")
    expect(primaryDeliveryAddress(undefined)).toBe("")
  })
})
