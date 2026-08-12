import { describe, it, expect, vi, afterEach } from "vitest"

// parseAndValidate is a pure module-level function, but importing the file
// pulls in useAddExpense (react-query + the Python backend client, which
// throws without NEXT_PUBLIC_BACKEND_URL in a test env) — stub it out.
vi.mock("@/hooks/data/use-expenses-query", () => ({ useAddExpense: () => ({ mutateAsync: vi.fn() }) }))

import { parseAndValidate } from "@/components/gastos/expense-import-dialog"

// app-timezone-argentina, task 2.4: la comparación "¿parseDate cayó al
// fallback de hoy?" (línea 166) debe usar el mismo día argentino que
// parseDate — si divergieran (uno ART, otro UTC) el warning de "fecha no
// reconocida" se dispararía (o se ocultaría) incorrectamente en la franja
// 21:00–24:00 ART.

const HEADER = ["Descripción", "Categoría", "Monto", "Fecha"]

describe("parseAndValidate — comparación 'es hoy' (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART, una fecha vacía resuelve a HOY sin warning espurio", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    const [row] = parseAndValidate([HEADER, ["Publicidad", "Marketing", "12000", ""]])
    expect(row.resolvedDate).toBe("2026-06-08")
    expect(row.warnings).not.toContain(expect.stringMatching(/no reconocida/))
  })

  it("una fecha con formato no reconocido cae a HOY (ART) con warning explícito", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    const [row] = parseAndValidate([HEADER, ["Publicidad", "Marketing", "12000", "31 de mayo"]])
    expect(row.resolvedDate).toBe("2026-06-08")
    expect(row.warnings.some((w) => w.includes("no reconocida"))).toBe(true)
  })

  it("una fecha ISO válida se conserva tal cual, sin comparar contra hoy", () => {
    const [row] = parseAndValidate([HEADER, ["Alquiler", "Alquiler", "85000", "2026-05-01"]])
    expect(row.resolvedDate).toBe("2026-05-01")
    expect(row.warnings).toHaveLength(0)
  })
})
