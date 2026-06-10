import { describe, expect, it } from "vitest"
import { isCuitFormat, isValidCuit, isValidTaxId } from "@/lib/cuit-utils"

describe("isCuitFormat", () => {
  it("reconoce el formato NN-NNNNNNNN-N", () => {
    expect(isCuitFormat("30-71234567-1")).toBe(true)
    expect(isCuitFormat("20-12345678-6")).toBe(true)
  })

  it("rechaza DNI y formatos inválidos", () => {
    expect(isCuitFormat("12345678")).toBe(false)
    expect(isCuitFormat("30-7123456-12")).toBe(false)
    expect(isCuitFormat("abc")).toBe(false)
  })
})

describe("isValidCuit (módulo 11)", () => {
  it("acepta CUITs con dígito verificador correcto", () => {
    expect(isValidCuit("30-71234567-1")).toBe(true)
    expect(isValidCuit("20-12345678-6")).toBe(true)
  })

  it("rechaza CUIT con dígito verificador incorrecto", () => {
    expect(isValidCuit("20-12345678-9")).toBe(false)
    expect(isValidCuit("30-71234567-8")).toBe(false)
  })

  it("rechaza valores que no tienen formato CUIT", () => {
    expect(isValidCuit("12345678")).toBe(false)
    expect(isValidCuit("")).toBe(false)
  })

  it("aplica la regla 11→0 del dígito verificador", () => {
    // suma ponderada de 20-12345698 = 154 → 154 % 11 = 0 → dígito 0
    expect(isValidCuit("20-12345698-0")).toBe(true)
  })

  it("aplica la regla 10→9 del dígito verificador", () => {
    // suma ponderada de 20-12445678 = 155 → 155 % 11 = 1 → 11-1 = 10 → dígito 9
    expect(isValidCuit("20-12445678-9")).toBe(true)
  })
})

describe("isValidTaxId (CUIT o DNI)", () => {
  it("acepta DNI de 7 u 8 dígitos sin verificación", () => {
    expect(isValidTaxId("12345678")).toBe(true)
    expect(isValidTaxId("1234567")).toBe(true)
  })

  it("acepta CUIT válido", () => {
    expect(isValidTaxId("30-71234567-1")).toBe(true)
  })

  it("rechaza CUIT con formato correcto pero dígito inválido", () => {
    expect(isValidTaxId("20-12345678-9")).toBe(false)
  })

  it("rechaza basura", () => {
    expect(isValidTaxId("abc")).toBe(false)
    expect(isValidTaxId("")).toBe(false)
    expect(isValidTaxId("123")).toBe(false)
  })
})
