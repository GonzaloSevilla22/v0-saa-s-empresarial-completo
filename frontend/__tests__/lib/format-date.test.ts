/**
 * v3-rbac-multirole Parte C (ronda 1 adversarial) — formatDate acepta las DOS
 * formas que el proyecto le pasa hoy.
 *
 * RED reproducido en vivo con el stack local antes del fix: /organizacion/roles
 * mostraba "Desde Invalid Date" en las 3 filas de miembro y, peor, el
 * vencimiento del rol —la funcionalidad central de este change— salía como
 * "Cajero hasta Invalid Date" / "Contable venció Invalid Date" en las cuatro
 * combinaciones (375x812 y 1440x900 x claro/oscuro). La causa: `formatDate`
 * concatenaba `"T12:00:00"` incondicionalmente, y `GET /members` devuelve
 * `created_at`/`expires_at` como instantes ISO completos.
 */
import { describe, it, expect } from "vitest"
import { formatDate, localDateEndOfDayISO } from "@/lib/format"

describe("formatDate", () => {
  it("fecha de negocio sin hora: la ancla al mediodía local (no se corre un día atrás en ART)", () => {
    expect(formatDate("2026-09-12")).toBe("12/09/2026")
  })

  it("RED: un instante ISO completo con Z ya NO produce 'Invalid Date'", () => {
    const out = formatDate("2026-09-22T15:30:00.123456Z")
    expect(out).not.toContain("Invalid")
    expect(out).toBe("22/09/2026")
  })

  it("TRIANGULATE: instante ISO con offset explícito", () => {
    const out = formatDate("2026-01-05T10:00:00-03:00")
    expect(out).not.toContain("Invalid")
    expect(out).toBe("05/01/2026")
  })

  it("TRIANGULATE: instante sin zona (hora local) tampoco rompe", () => {
    const out = formatDate("2026-12-31T23:00:00")
    expect(out).not.toContain("Invalid")
    expect(out).toBe("31/12/2026")
  })

  it("TRIANGULATE: el caso real de /organizacion/roles (created_at de GET /members)", () => {
    expect(formatDate("2026-09-12T03:25:24.042661Z")).not.toContain("Invalid")
  })

  it("REGRESIÓN: un valor ausente NO lanza — el cuerpo viejo degradaba sin romper y eso se conserva", () => {
    // `ExportacionesPage` monta filas sin `createdAt`; con `dateStr.includes()`
    // desnudo, la página entera se caía con un TypeError.
    expect(() => formatDate(undefined as unknown as string)).not.toThrow()
    expect(() => formatDate(null as unknown as string)).not.toThrow()
    expect(formatDate(undefined as unknown as string)).toBe("—")
    expect(formatDate("")).toBe("—")
  })
})

/**
 * RED reproducido en vivo antes del fix: en el diálogo "Asignar rol" de
 * /organizacion/roles se eligió **31/12/2026** en el selector de vencimiento
 * y, tras guardar, el badge del miembro quedó **"Compras hasta 30/12/2026"** —
 * un día ANTES del que el administrador concedió. Causa: el camino original
 * `new Date("2026-12-31").toISOString()` lee el `yyyy-mm-dd` como medianoche
 * UTC, que en ART (UTC-3) cae el 30/12 a las 21:00.
 */
describe("localDateEndOfDayISO", () => {
  it("RED: la fecha elegida sobrevive el ida y vuelta — nunca se corre un día atrás", () => {
    const iso = localDateEndOfDayISO("2026-12-31")
    expect(formatDate(iso)).toBe("31/12/2026")
  })

  it("ancla al FINAL del día local (23:59), no a su medianoche", () => {
    const d = new Date(localDateEndOfDayISO("2026-12-31"))
    expect(d.getFullYear()).toBe(2026)
    expect(d.getMonth()).toBe(11)
    expect(d.getDate()).toBe(31)
    expect(d.getHours()).toBe(23)
    expect(d.getMinutes()).toBe(59)
  })

  it("TRIANGULATE: el instante resultante es SIEMPRE futuro respecto del inicio de ese día", () => {
    const iso = localDateEndOfDayISO("2026-07-01")
    expect(new Date(iso).getTime()).toBeGreaterThan(new Date(2026, 6, 1, 0, 0, 0).getTime())
    expect(formatDate(iso)).toBe("01/07/2026")
  })

  it("TRIANGULATE: contraejemplo — el camino ingenuo SÍ se corría de día", () => {
    // Documenta por qué existe este helper: en cualquier zona al oeste de UTC
    // (ART incluida) el parseo como medianoche UTC retrocede la fecha.
    const naive = new Date("2026-12-31").toISOString()
    const fixed = localDateEndOfDayISO("2026-12-31")
    expect(formatDate(fixed)).toBe("31/12/2026")
    if (new Date().getTimezoneOffset() > 0) {
      expect(formatDate(naive)).toBe("30/12/2026")
    }
  })
})
