/**
 * balanza-etiquetas-pos (task 4.1) — RED→GREEN de `lib/scale-layout.ts`.
 *
 * El bloque "contrato compartido" lee `backend/tests/fixtures/scale_layout_cases.json`
 * caso por caso y exige que el esquema zod del frontend coincida con el booleano
 * `valid` de cada uno — el MISMO archivo que ejercita `test_scale_settings.py`
 * en el backend (D4, D15).
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  scaleSettingsSchema,
  isValidScaleSettings,
  layoutResultPattern,
  maxRepresentableAmount,
  FACTORY_SCALE_SETTINGS,
  type ScaleSettings,
  type ScaleLayout,
} from "@/lib/scale-layout"

// ─── Fixture compartido ───────────────────────────────────────────────────────

interface FixtureCase {
  name: string
  layoutUnderTest: number | null
  settings: ScaleSettings
  valid: boolean
  error_code: string | null
  expected?: { resultPattern?: string; maxAmount?: number }
}

const fixturePath = path.resolve(__dirname, "../../backend/tests/fixtures/scale_layout_cases.json")
const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf-8")) as { cases: FixtureCase[] }

describe("scaleSettingsSchema — contrato compartido con pytest (D4)", () => {
  it.each(fixture.cases.map((c) => [c.name, c] as const))("%s", (_name, testCase) => {
    const result = scaleSettingsSchema.safeParse(testCase.settings)
    expect(result.success).toBe(testCase.valid)
  })

  it("el conjunto tiene al menos 18 casos (no se perdió el fixture)", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(18)
  })
})

describe("scaleSettingsSchema — casos aislados", () => {
  it("RED: una configuración vacía todavía no existe la función", () => {
    // Placeholder de documentación del ciclo — el resto de la suite YA
    // ejercita `isValidScaleSettings` contra el módulo real.
    expect(typeof isValidScaleSettings).toBe("function")
  })

  it("acepta la configuración de fábrica completa (los tres formatos habilitados)", () => {
    expect(isValidScaleSettings(FACTORY_SCALE_SETTINGS)).toBe(true)
  })

  it("TRIANGULATE: un formato deshabilitado con basura no invalida el resto", () => {
    const settings: ScaleSettings = {
      enabled: true,
      layouts: [
        { kind: "weighed", enabled: false, segments: [{ field: "amount", digits: 999 }] },
        FACTORY_SCALE_SETTINGS.layouts[1],
        { kind: "multi", enabled: false, segments: [] },
      ],
    }
    expect(isValidScaleSettings(settings)).toBe(true)
  })
})

describe("layoutResultPattern", () => {
  const fromFixture = (name: string): { layout: ScaleLayout; expected: string } => {
    const c = fixture.cases.find((x) => x.name === name)!
    const idx = c.layoutUnderTest as number
    return { layout: c.settings.layouts[idx], expected: c.expected!.resultPattern! }
  }

  it("formato de peso de fábrica → 20BBBBCCCCCCX", () => {
    const { layout, expected } = fromFixture("factory_weighed_valid")
    expect(layoutResultPattern(layout)).toBe(expected)
  })

  it("formato por unidad de fábrica → 21BBBBCCCCCCX", () => {
    const { layout, expected } = fromFixture("factory_unit_valid")
    expect(layoutResultPattern(layout)).toBe(expected)
  })

  it("TRIANGULATE: formato Varios de fábrica → 22CCIIIIIIIIX", () => {
    const { layout, expected } = fromFixture("factory_multi_valid")
    expect(layoutResultPattern(layout)).toBe(expected)
  })

  it("TRIANGULATE: importe de 0 decimales (misma forma, otro maxAmount)", () => {
    const { layout, expected } = fromFixture("weighed_zero_decimals_valid")
    expect(layoutResultPattern(layout)).toBe(expected)
  })

  it("un campo con 0 dígitos no imprime ninguna letra (Tara de fábrica)", () => {
    const layout: ScaleLayout = {
      kind: "weighed",
      enabled: true,
      segments: [
        { field: "fixed", digits: 2, value: "20" },
        { field: "plu", digits: 4 },
        { field: "amount", digits: 6, decimals: 2 },
        { field: "ignored", digits: 0 },
      ],
    }
    expect(layoutResultPattern(layout)).toBe("20BBBBCCCCCCX")
  })
})

describe("maxRepresentableAmount", () => {
  it("6 dígitos, 2 decimales → 9999.99", () => {
    const c = fixture.cases.find((x) => x.name === "factory_weighed_valid")!
    expect(maxRepresentableAmount(c.settings.layouts[0])).toBe(c.expected!.maxAmount)
  })

  it("TRIANGULATE: 6 dígitos, 0 decimales → 999999", () => {
    const c = fixture.cases.find((x) => x.name === "weighed_zero_decimals_valid")!
    expect(maxRepresentableAmount(c.settings.layouts[0])).toBe(c.expected!.maxAmount)
  })

  it("un formato sin campo de importe (Varios) devuelve null", () => {
    expect(maxRepresentableAmount(FACTORY_SCALE_SETTINGS.layouts[2])).toBeNull()
  })
})
