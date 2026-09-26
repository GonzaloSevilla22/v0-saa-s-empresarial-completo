/**
 * factura-fiscal-imprimible (task 3.3) — `use-fiscal-profile` mapea los datos
 * del emisor que devuelve `GET /fiscal/profile` (snake_case → camelCase), y un
 * perfil viejo sin esas columnas queda en null (no undefined).
 */
import { describe, it, expect, vi } from "vitest"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn() },
}))

import { mapFiscalProfileRow } from "@/hooks/data/use-fiscal-profile"

const base = {
  id: "fp-1",
  account_id: "acc-1",
  cuit: "27213790337",
  iva_condition: "monotributista" as const,
  iibb_condition: null,
  certificado_afip_path: null,
  ambiente: "produccion" as const,
  created_at: "2026-09-26T00:00:00Z",
  delegacion_autorizada: true,
  platform_representante_cuit: null,
}

describe("mapFiscalProfileRow — datos del emisor", () => {
  it("mapea los cinco campos", () => {
    const p = mapFiscalProfileRow({
      ...base,
      razon_social: "PEREZ MARIA LAURA",
      nombre_fantasia: "Sumar",
      domicilio_comercial: "Av. San Martín 1234, Mendoza",
      iibb_numero: "0712345",
      inicio_actividades: "2019-03-01",
    })

    expect(p.razonSocial).toBe("PEREZ MARIA LAURA")
    expect(p.nombreFantasia).toBe("Sumar")
    expect(p.domicilioComercial).toBe("Av. San Martín 1234, Mendoza")
    expect(p.iibbNumero).toBe("0712345")
    expect(p.inicioActividades).toBe("2019-03-01")
  })

  it("un perfil sin las columnas nuevas queda en null", () => {
    const p = mapFiscalProfileRow(base)

    expect(p.razonSocial).toBeNull()
    expect(p.nombreFantasia).toBeNull()
    expect(p.domicilioComercial).toBeNull()
    expect(p.iibbNumero).toBeNull()
    expect(p.inicioActividades).toBeNull()
  })
})
