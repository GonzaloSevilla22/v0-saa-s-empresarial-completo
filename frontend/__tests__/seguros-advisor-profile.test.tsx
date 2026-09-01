/**
 * seguros-perfil-asesor (task 3.1-3.4): extensión de insuranceService para
 * el perfil de asesor de seguros — obtener un asesor por slug, distinguir
 * `offer` de `advisor`, y validar con Zod la forma de las listas jsonb
 * (service_lines / pillars) en el borde de la app (design.md D3).
 *
 * No toca frontend/__tests__/seguros-click-tracking.test.tsx (red de
 * seguridad, corre sin editarse).
 *
 * Mocks: @/lib/supabase/client (schema/from/select/eq/maybeSingle chain),
 * mismo patrón que seguros-click-tracking.test.tsx (vi.hoisted porque
 * insuranceService llama createClient() a nivel de módulo).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"

const { schemaMock, fromMock, selectMock, eqMock, orderMock, maybeSingleMock } =
  vi.hoisted(() => ({
    schemaMock: vi.fn(),
    fromMock: vi.fn(),
    selectMock: vi.fn(),
    eqMock: vi.fn(),
    orderMock: vi.fn(),
    maybeSingleMock: vi.fn(),
  }))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    rpc: vi.fn(),
    schema: schemaMock,
  }),
}))

import {
  insuranceService,
  isAdvisorEntry,
  serviceLinesSchema,
  pillarsSchema,
  type Insurance,
} from "@/lib/services/insuranceService"

function makeAdvisorRow(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "advisor-1",
    title: "Julián Dupás — Productor Asesor de Seguros",
    description: "",
    coverage: "",
    price: "",
    contact_url: "https://www.argbroker.com.ar",
    is_visible: true,
    created_at: "2026-09-01T00:00:00.000Z",
    updated_at: "2026-09-01T00:00:00.000Z",
    entry_type: "advisor",
    slug: "julian-dupas",
    advisor_name: "Julián Dupás",
    advisor_role: "Productor Asesor de Seguros",
    license_number: "98506",
    license_authority: null,
    headline: "Un seguro no termina cuando se emite la póliza.",
    bio: "Mi trabajo comienza con el análisis de cada situación particular.",
    photo_url: null,
    contact_phone: "2266 474348",
    contact_whatsapp: "5492266474348",
    contact_email: "julian_dupas@argbroker.com.ar",
    service_lines: [{ title: "Autos y motos", description: "Coberturas adaptadas." }],
    pillars: [{ title: "Comparación de alternativas", body: "No trabajo con una única aseguradora." }],
    coverage_areas: ["Necochea", "Mendoza"],
    disclaimer: "Aliadata no es aseguradora ni intermediaria.",
    contact_clicks: {},
    is_featured: false,
    sort_order: 0,
    ...overrides,
  }
}

function mockChain(resolved: { data: unknown; error: unknown }) {
  const chain: Record<string, unknown> = {}
  chain.select = selectMock.mockReturnValue(chain)
  chain.eq = eqMock.mockReturnValue(chain)
  chain.order = orderMock.mockResolvedValue(resolved)
  chain.maybeSingle = maybeSingleMock.mockResolvedValue(resolved)
  schemaMock.mockReturnValue({ from: fromMock })
  fromMock.mockReturnValue(chain)
  return chain
}

beforeEach(() => {
  schemaMock.mockReset()
  fromMock.mockReset()
  selectMock.mockReset()
  eqMock.mockReset()
  orderMock.mockReset()
  maybeSingleMock.mockReset()
})

describe("insuranceService.getAdvisorBySlug", () => {
  it("consulta community.seguros filtrando por slug y entry_type='advisor'", async () => {
    const row = makeAdvisorRow()
    mockChain({ data: row, error: null })

    const result = await insuranceService.getAdvisorBySlug("julian-dupas")

    expect(schemaMock).toHaveBeenCalledWith("community")
    expect(fromMock).toHaveBeenCalledWith("seguros")
    expect(eqMock).toHaveBeenCalledWith("slug", "julian-dupas")
    expect(eqMock).toHaveBeenCalledWith("entry_type", "advisor")
    expect(result).toEqual(row)
  })

  it("devuelve null cuando el slug no existe (sin lanzar)", async () => {
    mockChain({ data: null, error: null })

    const result = await insuranceService.getAdvisorBySlug("no-existe")

    expect(result).toBeNull()
  })

  it("propaga el error de Postgres si la consulta falla", async () => {
    mockChain({ data: null, error: { message: "boom", code: "XX000" } })

    await expect(insuranceService.getAdvisorBySlug("julian-dupas")).rejects.toBeTruthy()
  })

  it("devuelve la fila igual cuando las vías de contacto opcionales están ausentes (D7: cada vía degrada sola)", async () => {
    const row = makeAdvisorRow({
      contact_whatsapp: null,
      contact_email: null,
      photo_url: null,
      license_authority: null,
    })
    mockChain({ data: row, error: null })

    const result = await insuranceService.getAdvisorBySlug("julian-dupas")

    expect(result?.contact_whatsapp).toBeNull()
    expect(result?.contact_email).toBeNull()
    expect(result?.contact_phone).toBe("2266 474348")
  })
})

describe("isAdvisorEntry", () => {
  it("distingue una entrada de tipo advisor", () => {
    expect(isAdvisorEntry({ entry_type: "advisor" })).toBe(true)
  })

  it("distingue una entrada de tipo offer", () => {
    expect(isAdvisorEntry({ entry_type: "offer" })).toBe(false)
  })

  it("trata entry_type ausente (filas legacy/mocks) como offer, no como advisor", () => {
    expect(isAdvisorEntry({})).toBe(false)
  })
})

describe("serviceLinesSchema / pillarsSchema (Zod, borde de la app)", () => {
  it("acepta una lista de líneas de servicio bien formada", () => {
    const result = serviceLinesSchema.safeParse([
      { title: "Autos y motos", description: "Coberturas adaptadas." },
    ])
    expect(result.success).toBe(true)
  })

  it("acepta una lista vacía", () => {
    expect(serviceLinesSchema.safeParse([]).success).toBe(true)
  })

  it("rechaza un elemento sin title", () => {
    const result = serviceLinesSchema.safeParse([{ description: "sin título" }])
    expect(result.success).toBe(false)
  })

  it("rechaza que la columna completa no sea un array", () => {
    expect(serviceLinesSchema.safeParse({ title: "no es lista" }).success).toBe(false)
  })

  it("acepta una lista de pilares bien formada", () => {
    const result = pillarsSchema.safeParse([{ title: "Transparencia", body: "Explico todo." }])
    expect(result.success).toBe(true)
  })

  it("rechaza un pilar sin body", () => {
    expect(pillarsSchema.safeParse([{ title: "Transparencia" }]).success).toBe(false)
  })
})
