/**
 * documentos-marca-empresa (task 9.1) — RED→GREEN de `lib/color-contrast.ts`.
 *
 * La aritmética WCAG vivía dentro de `token-contrast-aa.test.ts` ("si un segundo
 * consumidor aparece, se promueve a `frontend/lib/`"). El segundo consumidor es el
 * aviso de contraste en vivo de la pestaña "Documentos": el color personalizado
 * de los papeles tiene que leerse sobre blanco (>= 4,5:1) y la persona lo ve ANTES
 * de guardar.
 *
 * El cálculo AUTORITATIVO es el de Python (`backend/services/commercial_documents/
 * palette.py`: el servidor rechaza un acento ilegible y el render cae a Neutro).
 * Este archivo lee el MISMO fixture que `test_document_palette.py`
 * (`backend/tests/fixtures/document_palette_cases.json`) caso por caso, así que los
 * dos lados no pueden divergir sin que un test lo diga.
 */
import { describe, expect, it } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  INK,
  MIN_ACCENT_CONTRAST,
  WHITE,
  bestTextOn,
  contrastRatio,
  displayContrast,
  hexToRgb,
  isValidAccent,
  relativeLuminance,
  srgbChannelToLinear,
} from "@/lib/color-contrast"

interface PaletteCase {
  color: string
  note: string
  contrast: number
  accepted: boolean
  text_on: "white" | "ink"
}

const FIXTURE = JSON.parse(
  fs.readFileSync(
    path.resolve(__dirname, "../../../backend/tests/fixtures/document_palette_cases.json"),
    "utf-8",
  ),
) as { min_accent_contrast: number; ink: string; cases: PaletteCase[] }

describe("fixture compartido con el backend", () => {
  it("el umbral y la tinta son los del fixture", () => {
    expect(MIN_ACCENT_CONTRAST).toBe(FIXTURE.min_accent_contrast)
    expect(INK).toEqual(hexToRgb(FIXTURE.ink))
  })

  it.each(FIXTURE.cases.map((c) => [c.color, c] as const))("%s", (_color, c) => {
    const rgb = hexToRgb(c.color)
    expect(rgb).not.toBeNull()
    const ratio = contrastRatio(rgb!, WHITE)
    expect(displayContrast(ratio)).toBe(c.contrast)
    expect(ratio >= MIN_ACCENT_CONTRAST).toBe(c.accepted)
    expect(isValidAccent(c.color)).toBe(c.accepted)
    expect(bestTextOn(rgb!)).toEqual(c.text_on === "white" ? WHITE : INK)
  })
})

describe("aritmética WCAG", () => {
  it("negro sobre blanco es 21:1 y es simétrico", () => {
    expect(contrastRatio({ r: 0, g: 0, b: 0 }, WHITE)).toBeCloseTo(21, 5)
    expect(contrastRatio(WHITE, INK)).toBeCloseTo(contrastRatio(INK, WHITE), 10)
  })

  it("la luminancia de los extremos", () => {
    expect(relativeLuminance({ r: 0, g: 0, b: 0 })).toBe(0)
    expect(relativeLuminance(WHITE)).toBeCloseTo(1, 10)
  })

  it("linealiza sRGB con el codo de 0,03928", () => {
    expect(srgbChannelToLinear(0)).toBe(0)
    expect(srgbChannelToLinear(10)).toBeCloseTo(10 / 255 / 12.92, 10)      // tramo lineal
    expect(srgbChannelToLinear(255)).toBeCloseTo(1, 10)
    expect(srgbChannelToLinear(128)).toBeCloseTo(((128 / 255 + 0.055) / 1.055) ** 2.4, 10)
  })

  it("el verde anterior de los papeles no pasa AA y su reemplazo oscuro sí", () => {
    expect(isValidAccent("#10b981")).toBe(false)
    expect(displayContrast(contrastRatio(hexToRgb("#10b981")!, WHITE))).toBe(2.54)
    expect(isValidAccent("#047857")).toBe(true)
  })

  it("el aviso nunca muestra 4,50 para un color que se rechaza (4,49976)", () => {
    const ratio = contrastRatio(hexToRgb("#ac5e80")!, WHITE)
    expect(ratio).toBeLessThan(MIN_ACCENT_CONTRAST)
    expect(Math.round(ratio * 100) / 100).toBe(4.5)         // el redondeo común mentiría
    expect(displayContrast(ratio)).toBe(4.49)
  })

  it("el umbral se aplica al valor EXACTO: 4,50192 pasa y 4,48992 no", () => {
    expect(isValidAccent("#a76180")).toBe(true)
    expect(isValidAccent("#a96081")).toBe(false)
  })
})

describe("hexToRgb", () => {
  it("lee #rrggbb en minúsculas o mayúsculas", () => {
    expect(hexToRgb("#1d4ed8")).toEqual({ r: 29, g: 78, b: 216 })
    expect(hexToRgb("#1D4ED8")).toEqual({ r: 29, g: 78, b: 216 })
  })

  it.each(["", "1d4ed8", "#1d4", "#1d4ed8ff", "#gggggg", "rgb(1,2,3)", " #1d4ed8"])("rechaza %j", (bad) => {
    expect(hexToRgb(bad)).toBeNull()
    expect(isValidAccent(bad)).toBe(false)
  })
})
