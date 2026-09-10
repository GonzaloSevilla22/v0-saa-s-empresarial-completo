import { describe, it, expect, vi, afterEach } from "vitest"

// parseAndValidate is a pure module-level function, but importing the file
// pulls in useImportExpenses (react-query + the Python backend client, which
// throws without NEXT_PUBLIC_BACKEND_URL in a test env) — stub it out. The
// four selectores canónicos también tiran de ese cliente transitivamente
// (usePaymentMethods/useBranches/useCostCenters/useBankAccounts), así que se
// mockean igual que en los otros tests del diálogo.
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useImportExpenses: () => ({ importMutation: { mutateAsync: vi.fn() }, invalidateLedgers: vi.fn() }),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

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

// ── importador-gastos-transaccional (task 8.1, D4) ──────────────────────────
//
// El template pasa a SIETE columnas (Forma de pago / Sucursal / Centro de
// costo, las tres OPCIONALES). Compatibilidad hacia atrás EXPLÍCITA: un CSV
// de cuatro columnas (los casos de arriba) sigue funcionando exactamente
// igual — es requisito, no cortesía (hay usuarios con su planilla armada).

const HEADER_7 = ["Descripción", "Categoría", "Monto", "Fecha", "Forma de pago", "Sucursal", "Centro de costo"]

describe("parseAndValidate — las 3 columnas nuevas (importador-gastos-transaccional, D4)", () => {
  it("extrae forma de pago, sucursal y centro de costo TAL CUAL vienen en la celda (sin resolver — eso lo hace el servidor)", () => {
    const [row] = parseAndValidate([
      HEADER_7,
      ["Internet", "Servicios", "4500", "2026-05-02", "Transferencia bancaria", "Sucursal Centro", "Administración"],
    ])
    expect(row.rawPaymentMethod).toBe("Transferencia bancaria")
    expect(row.rawBranch).toBe("Sucursal Centro")
    expect(row.rawCostCenter).toBe("Administración")
  })

  it("celdas vacías de las tres columnas nuevas quedan como string vacío, no error ni warning de cliente", () => {
    const [row] = parseAndValidate([HEADER_7, ["Alquiler", "Alquiler", "85000", "2026-05-01", "", "", ""]])
    expect(row.rawPaymentMethod).toBe("")
    expect(row.rawBranch).toBe("")
    expect(row.rawCostCenter).toBe("")
    expect(row.errors).toHaveLength(0)
    // Categoría SÍ está informada y es válida acá, así que no hay warning de
    // categoría — el punto del test es que las 3 columnas nuevas, vacías, no
    // generan NINGÚN error/warning de cliente (su validación es del servidor).
    expect(row.warnings).toHaveLength(0)
  })

  it("un CSV de CUATRO columnas (compatibilidad hacia atrás) deja las tres columnas nuevas vacías, sin romper el parseo", () => {
    const [row] = parseAndValidate([HEADER, ["Alquiler", "Alquiler", "85000", "2026-05-01"]])
    expect(row.rawPaymentMethod).toBe("")
    expect(row.rawBranch).toBe("")
    expect(row.rawCostCenter).toBe("")
    // Y el resto del parseo sigue funcionando exactamente igual que antes.
    expect(row.resolvedDate).toBe("2026-05-01")
    expect(row.status).toBe("ok")
  })

  it("las columnas nuevas no alteran la resolución de Monto/Categoría/Fecha existente", () => {
    const [row] = parseAndValidate([
      HEADER_7,
      ["Publicidad en redes", "Marketing", "12000", "", "Efectivo", "", ""],
    ])
    expect(row.resolvedAmount).toBe(12000)
    expect(row.resolvedCategory).toBe("Marketing")
    expect(row.rawPaymentMethod).toBe("Efectivo")
  })
})
