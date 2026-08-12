/**
 * Tests directos de `supabase/functions/_shared/argentina-time.ts` — la
 * aritmética que consumen los fallbacks rolling de las Edge Functions IA
 * (app-timezone-argentina, tasks 4.1/4.2). El "cableado" (armar los params
 * dateFrom/dateTo en cada `index.ts`) NO es testeable desde vitest: cada
 * `index.ts` llama `Deno.serve(...)` a nivel de módulo, que revienta fuera
 * de un runtime Deno — por eso la aritmética vive acá, aislada y testeada,
 * y el wiring es una sustitución mecánica de una función ya probada (mismo
 * patrón que `_shared/reporting-canon.ts`).
 */

import { describe, it, expect } from "vitest"
import {
  argentinaToday,
  argentinaDaysAgoIso,
  argentinaMonthsAgoIso,
  argentinaFirstDayOfMonthIso,
} from "../../../supabase/functions/_shared/argentina-time"

describe("argentinaDaysAgoIso", () => {
  it("0 días atrás es la medianoche UTC del día argentino de hoy", () => {
    const instant = new Date("2026-06-17T15:00:00.000Z") // 12:00 ART
    expect(argentinaDaysAgoIso(0, instant)).toBe("2026-06-17T00:00:00.000Z")
  })

  it("REGRESSION: 21:00 ART del día D, 1 día atrás es medianoche UTC de D-1 (no de D)", () => {
    // ai-resumen 'daily': el bug clásico si se usara now.getUTCDate() en vez
    // del día argentino — a las 21:00 ART, UTC ya está en D+1.
    expect(argentinaDaysAgoIso(1, new Date("2026-06-09T00:00:00.000Z"))).toBe("2026-06-07T00:00:00.000Z")
  })

  it("7 días atrás (fallback 'weekly') cruza un borde de mes", () => {
    expect(argentinaDaysAgoIso(7, new Date("2026-06-05T15:00:00.000Z"))).toBe("2026-05-29T00:00:00.000Z")
  })
})

describe("argentinaMonthsAgoIso", () => {
  it("1 mes atrás (fallback 'monthly') conserva el día del mes", () => {
    expect(argentinaMonthsAgoIso(1, new Date("2026-06-17T15:00:00.000Z"))).toBe("2026-05-17T00:00:00.000Z")
  })

  it("REGRESSION: 21:00 ART del día D, 1 mes atrás parte del día D (ART), no de D+1 (UTC)", () => {
    // 21:00 ART, 8/jun (UTC ya es 9/jun) — 1 mes atrás debe partir del 8, no del 9.
    expect(argentinaMonthsAgoIso(1, new Date("2026-06-09T00:00:00.000Z"))).toBe("2026-05-08T00:00:00.000Z")
  })
})

describe("argentinaFirstDayOfMonthIso", () => {
  it("resuelve el primer día del mes argentino en curso", () => {
    expect(argentinaFirstDayOfMonthIso(new Date("2026-06-17T15:00:00.000Z"))).toBe("2026-06-01T00:00:00.000Z")
  })

  it("REGRESSION: 21:00 ART del 31/may (ai-simulador) sigue siendo mayo, no junio", () => {
    // UTC ya rolleó a 1/jun; el mes 'en curso' argentino sigue siendo mayo.
    expect(argentinaFirstDayOfMonthIso(new Date("2026-06-01T00:00:00.000Z"))).toBe("2026-05-01T00:00:00.000Z")
  })
})

describe("paridad interna: argentinaDaysAgoIso(0) vs argentinaToday", () => {
  it("el día calendario coincide con el prefijo de la ventana de 0 días atrás", () => {
    const instant = new Date("2026-06-09T00:00:00.000Z") // 21:00 ART, 8/jun
    expect(argentinaDaysAgoIso(0, instant).startsWith(argentinaToday(instant))).toBe(true)
  })
})
