/**
 * app-timezone-argentina, task 6.2 — verificación end-to-end (a nivel de
 * unit test, instante inyectado) del escenario nocturno descripto en el
 * proposal: "una venta cargada a las 22:00 hora argentina se guarda con
 * fecha de mañana".
 *
 * Con el reloj del sistema simulado a las 22:00 ART (01:00Z del día
 * siguiente):
 *   1. El default de fecha del formulario de venta (`argentinaToday()`,
 *      mismo helper que usa `sale-form.tsx`) resuelve al día D.
 *   2. La ventana "ventas hoy" del dashboard (`utcDayRange()`, mismo helper
 *      que usa `dashboard/page.tsx` vía `ai-summary-card.tsx`) incluye ese
 *      mismo día D — una venta guardada con `date = argentinaToday()` cae
 *      dentro de esa ventana.
 *
 * Ambos consumidores derivan del mismo instante vía el mismo helper
 * (`lib/date-range.ts`), así que esta prueba es la garantía estructural de
 * que "el form defaultea a HOY" y "el dashboard incluye la venta recién
 * cargada" son la MISMA fecha — no dos cálculos que puedan divergir.
 *
 * Verificación E2E contra la app desplegada (browser real, sesión
 * autenticada) queda PENDIENTE PO — no se falsea acá: este test cubre la
 * lógica, no el pixel en pantalla post-deploy.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { argentinaToday, utcDayRange } from "@/lib/date-range"

describe("Escenario nocturno 21:00-24:00 ART (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("una venta cargada a las 22:00 ART queda fechada HOY, y esa fecha cae en la ventana 'ventas hoy'", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun — UTC ya rolleó a 9/jun

    // 1. Default del formulario de venta (sale-form.tsx / purchase-form.tsx / expense-form-v2.tsx).
    const saleDefaultDate = argentinaToday()
    expect(saleDefaultDate).toBe("2026-06-08") // NO "2026-06-09" (el bug original)

    // La fila se guarda como `date`-typed a medianoche UTC de esa fecha calendario
    // (ver comentario de storage en lib/date-range.ts).
    const saleStoredAtUtcMidnight = `${saleDefaultDate}T00:00:00.000Z`

    // 2. Ventana "ventas hoy" del dashboard (dashboard/page.tsx, ai-summary-card.tsx).
    const { from: todayFrom, to: todayTo } = utcDayRange()

    expect(todayFrom <= saleStoredAtUtcMidnight && saleStoredAtUtcMidnight <= todayTo).toBe(true)
  })
})
