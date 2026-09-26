/**
 * punto-venta-seleccion (D6) — regla única de preselección del punto de venta
 * al facturar, en `lib/` (pura, sin `python-client`).
 *
 * Orden firmado por el PO (OQ-2, 2026-09-26): última elección de la sesión (si
 * sigue activa) > predeterminado de la cuenta > único activo > ninguno. Un PV
 * inactivo nunca se ofrece ni se preselecciona.
 */
import { describe, it, expect } from "vitest"

import {
  activePointsOfSale,
  formatPointOfSaleLabel,
  formatPointOfSaleNumber,
  lastPointOfSaleStorageKey,
  resolvePreselectedPointOfSale,
  type PointOfSaleOption,
} from "@/lib/fiscal-point-of-sale"
import { formatComprobante } from "@/lib/fiscal-comprobante"

const pv = (id: string, numero: number, isActive = true, isDefault = false): PointOfSaleOption => ({
  id,
  numero,
  isActive,
  isDefault,
})

const PV3 = pv("pv-3", 3)
const PV9999 = pv("pv-9999", 9999)
const PV9999_DEFAULT = pv("pv-9999", 9999, true, true)

describe("resolvePreselectedPointOfSale", () => {
  it("sin elección previa se preselecciona el predeterminado", () => {
    expect(resolvePreselectedPointOfSale([PV3, PV9999_DEFAULT], { lastUsedId: null })).toBe("pv-9999")
  })

  it("la última elección de la sesión gana sobre el predeterminado", () => {
    expect(resolvePreselectedPointOfSale([PV3, PV9999_DEFAULT], { lastUsedId: "pv-3" })).toBe("pv-3")
  })

  it("una última elección que ya no está activa se ignora (cae al predeterminado)", () => {
    const pv3Inactive = pv("pv-3", 3, false)
    expect(resolvePreselectedPointOfSale([pv3Inactive, PV9999_DEFAULT], { lastUsedId: "pv-3" })).toBe("pv-9999")
  })

  it("varios activos sin predeterminado ni elección previa no preseleccionan nada", () => {
    expect(resolvePreselectedPointOfSale([PV3, PV9999], { lastUsedId: null })).toBeNull()
  })

  it("un PV inactivo de menor número no se ofrece: queda el único activo", () => {
    const pv1Inactive = pv("pv-1", 1, false)
    expect(resolvePreselectedPointOfSale([pv1Inactive, PV3], { lastUsedId: null })).toBe("pv-3")
  })

  it("TRIANGULATE: una última elección que no pertenece a la lista (otra cuenta) se ignora", () => {
    expect(resolvePreselectedPointOfSale([PV3, PV9999], { lastUsedId: "pv-de-otra-cuenta" })).toBeNull()
    expect(resolvePreselectedPointOfSale([PV3], { lastUsedId: "pv-de-otra-cuenta" })).toBe("pv-3")
  })

  it("TRIANGULATE: un 'predeterminado' inactivo (dato inconsistente) nunca se preselecciona", () => {
    const staleDefault = pv("pv-9999", 9999, false, true)
    expect(resolvePreselectedPointOfSale([PV3, staleDefault, pv("pv-5", 5)], { lastUsedId: null })).toBeNull()
  })

  it("sin puntos de venta no hay preselección", () => {
    expect(resolvePreselectedPointOfSale([], { lastUsedId: "pv-3" })).toBeNull()
  })

  it("con un solo activo, la última elección vieja no impide preseleccionarlo", () => {
    expect(resolvePreselectedPointOfSale([pv("pv-1", 1, false), PV3], { lastUsedId: "pv-1" })).toBe("pv-3")
  })
})

describe("activePointsOfSale", () => {
  it("devuelve sólo los activos, en el orden recibido", () => {
    const list = [pv("pv-1", 1, false), PV3, PV9999]
    expect(activePointsOfSale(list).map((p) => p.id)).toEqual(["pv-3", "pv-9999"])
  })

  it("una lista sin activos da vacío", () => {
    expect(activePointsOfSale([pv("pv-1", 1, false)])).toEqual([])
  })
})

describe("formato del número de punto de venta (ARCA, 4 dígitos)", () => {
  it("formatPointOfSaleNumber rellena a 4 dígitos", () => {
    expect(formatPointOfSaleNumber(3)).toBe("0003")
    expect(formatPointOfSaleNumber(9999)).toBe("9999")
  })

  it("es el mismo padding que el comprobante (una sola fuente)", () => {
    expect(formatComprobante(3, 501)).toBe(`${formatPointOfSaleNumber(3)}-00000501`)
  })

  it("formatPointOfSaleLabel antepone 'PV'", () => {
    expect(formatPointOfSaleLabel(3)).toBe("PV 0003")
  })
})

describe("lastPointOfSaleStorageKey", () => {
  it("la memoria de la sesión es por cuenta", () => {
    expect(lastPointOfSaleStorageKey("acc-1")).toBe("fiscal:last-pv:acc-1")
    expect(lastPointOfSaleStorageKey("acc-2")).not.toBe(lastPointOfSaleStorageKey("acc-1"))
  })
})
