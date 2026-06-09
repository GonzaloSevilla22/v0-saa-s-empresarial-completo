import { describe, it, expect } from "vitest"
import {
  kpiDeltaPct,
  kpiBadgeTone,
  formatKpiDelta,
  formatKpiCurrency,
} from "@/lib/kpi-format"

// Lógica del badge de variación del Bloque Resumen KPI (spec sección 5):
//   verde  = variación FAVORABLE según la polaridad del KPI
//   rojo   = variación DESFAVORABLE según la polaridad
//   amarillo = sin variación significativa o sin baseline
// Polaridad invertida: para Costo por Venta y Stock sin Rotación SUBIR es malo.

describe("kpiDeltaPct", () => {
  it("calcula el % de variación contra el período anterior", () => {
    expect(kpiDeltaPct(112, 100)).toBe(12)
    expect(kpiDeltaPct(92, 100)).toBe(-8)
  })

  it("devuelve null sin baseline (prev 0, null o undefined)", () => {
    expect(kpiDeltaPct(100, 0)).toBeNull()
    expect(kpiDeltaPct(100, null)).toBeNull()
    expect(kpiDeltaPct(100, undefined)).toBeNull()
  })

  it("devuelve null si el valor actual es null (sin datos del período)", () => {
    expect(kpiDeltaPct(null, 100)).toBeNull()
  })
})

describe("kpiBadgeTone", () => {
  it("verde cuando un KPI up_good sube significativamente (Ganancia +12%)", () => {
    expect(kpiBadgeTone(12, "up_good")).toBe("green")
  })

  it("rojo cuando un KPI up_good baja significativamente", () => {
    expect(kpiBadgeTone(-12, "up_good")).toBe("red")
  })

  it("polaridad invertida: rojo cuando un KPI up_bad sube (Costo por Venta +8%)", () => {
    expect(kpiBadgeTone(8, "up_bad")).toBe("red")
  })

  it("polaridad invertida: verde cuando un KPI up_bad baja (Stock sin Rotación -10%)", () => {
    expect(kpiBadgeTone(-10, "up_bad")).toBe("green")
  })

  it("amarillo dentro del rango sin variación significativa (|Δ| < 5%)", () => {
    expect(kpiBadgeTone(3, "up_good")).toBe("yellow")
    expect(kpiBadgeTone(-4.9, "up_bad")).toBe("yellow")
    expect(kpiBadgeTone(0, "up_good")).toBe("yellow")
  })

  it("amarillo sin baseline (delta null)", () => {
    expect(kpiBadgeTone(null, "up_good")).toBe("yellow")
    expect(kpiBadgeTone(null, "up_bad")).toBe("yellow")
  })
})

describe("formatKpiDelta", () => {
  it("formatea subas con flecha arriba y signo", () => {
    expect(formatKpiDelta(12)).toBe("▲ +12%")
  })

  it("formatea bajas con flecha abajo", () => {
    expect(formatKpiDelta(-8)).toBe("▼ -8%")
  })

  it("redondea a entero", () => {
    expect(formatKpiDelta(7.6)).toBe("▲ +8%")
  })

  it("muestra — sin baseline", () => {
    expect(formatKpiDelta(null)).toBe("—")
  })
})

describe("formatKpiCurrency", () => {
  it("formatea pesos sin decimales con separador de miles", () => {
    expect(formatKpiCurrency(184200)).toBe("$184.200")
  })

  it("muestra — cuando no hay dato del período", () => {
    expect(formatKpiCurrency(null)).toBe("—")
  })

  it("soporta negativos", () => {
    expect(formatKpiCurrency(-1500)).toBe("-$1.500")
  })
})
