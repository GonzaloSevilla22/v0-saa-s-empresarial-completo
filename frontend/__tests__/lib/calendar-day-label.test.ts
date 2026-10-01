import { describe, it, expect, afterEach } from "vitest"
import { formatCalendarDay } from "@/lib/format"

// tablero-menu-pulido (P1): `formatCalendarDay` rotula el día CALENDARIO de una
// clave "YYYY-MM-DD" sin que el huso del navegador lo corra. La clave nunca se
// interpreta como instante (`new Date("YYYY-MM-DD")` es medianoche UTC, que en
// UTC-3 cae el día anterior). Cada caso fija `process.env.TZ`, así protege la
// regresión igual con el huso de la máquina del dev que con el del CI.

const HUSOS = [
  "America/Argentina/Buenos_Aires",
  "Pacific/Honolulu",
  "UTC",
  "Pacific/Kiritimati",
] as const

const SEMANA = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"] as const

// Verdad independiente del formateador: el día de la semana sale de getUTCDay
// sobre el día calendario de la clave.
function diaEsperado(key: string): string {
  const [y, m, d] = key.split("-").map(Number)
  return `${SEMANA[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]} ${d}`
}

describe("formatCalendarDay", () => {
  const tzOriginal = process.env.TZ
  afterEach(() => {
    if (tzOriginal === undefined) delete process.env.TZ
    else process.env.TZ = tzOriginal
  })

  describe.each(HUSOS)("huso %s", (tz) => {
    it("7 claves consecutivas (cruzando fin de mes): weekday corto + día, sin corrimiento", () => {
      process.env.TZ = tz
      const claves = ["2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"]
      const rotulos = claves.map((k) => formatCalendarDay(k, { weekday: "short", day: "numeric" }))
      expect(rotulos).toEqual(claves.map(diaEsperado))
    })

    it("fin de año y bisiesto: 2027-01-01 es viernes y 2028-02-29 es martes", () => {
      process.env.TZ = tz
      expect(formatCalendarDay("2027-01-01", { weekday: "short", day: "numeric" })).toBe("vie 1")
      expect(formatCalendarDay("2028-02-29", { weekday: "short", day: "numeric" })).toBe("mar 29")
    })
  })

  it("respeta las opciones y el locale recibidos (mes corto)", () => {
    process.env.TZ = "America/Argentina/Buenos_Aires"
    expect(formatCalendarDay("2026-10-01", { day: "numeric", month: "short" })).toMatch(/^1 oct/)
    expect(formatCalendarDay("2026-10-01", { month: "long" }, "en-US")).toBe("October")
  })

  it("acepta un timestamp ISO y toma sólo su día calendario", () => {
    process.env.TZ = "America/Argentina/Buenos_Aires"
    expect(formatCalendarDay("2026-10-01T00:00:00.000Z", { weekday: "short", day: "numeric" })).toBe("jue 1")
  })

  it("una clave que no es fecha vuelve tal cual (nunca 'Invalid Date')", () => {
    expect(formatCalendarDay("no-es-fecha", { day: "numeric" })).toBe("no-es-fecha")
    expect(formatCalendarDay("", { day: "numeric" })).toBe("")
  })
})
