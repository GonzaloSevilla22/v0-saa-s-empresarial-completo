/**
 * bank-reconciliation C3 — Frontend TDD tests (Strict TDD Mode)
 *
 * Cycle: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 *
 * Comportamientos cubiertos:
 *  - parseBankStatementText: CSV es-AR (`;`, dd/mm/yyyy, "1.234,56"), CSV plano,
 *    headers no reconocidos → error, fila con fecha inválida → error
 *  - parseAmount / parseDate: formatos argentino, US y plano; inválidos → null
 *  - useReconciliationSessions: fetch + mapeo camelCase
 *  - useCreateMatch: POST con statement_line_ids/bank_movement_ids (snake_case)
 *  - useCloseSession: propaga close_reason (null cuando no hay motivo)
 *  - useUndoMatch: exige matchGroup + undoReason en el POST
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

import {
  parseBankStatementText,
  parseAmount,
  parseDate,
} from "@/lib/bank-statement-parser"
import {
  useReconciliationSessions,
  useCreateMatch,
  useCloseSession,
  useUndoMatch,
  useImportStatement,
} from "@/hooks/data/use-bank-reconciliation"

// ── Mocks ──────────────────────────────────────────────────────────────────────

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const BANK_ACCOUNT_ID = "99999999-9999-9999-9999-999999999999"
const SESSION_ID      = "33333333-3333-3333-3333-333333333333"
const MATCH_GROUP     = "44444444-4444-4444-4444-444444444444"
const LINE_ID         = "55555555-5555-5555-5555-555555555555"
const MOVEMENT_ID     = "66666666-6666-6666-6666-666666666666"

function wrapper({ children }: { children: React.ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return React.createElement(QueryClientProvider, { client: queryClient }, children)
}

beforeEach(() => {
  vi.clearAllMocks()
})

// ═══════════════════════════════════════════════════════════════════════════════
// Parser de extracto (puro)
// ═══════════════════════════════════════════════════════════════════════════════

describe("parseBankStatementText", () => {
  it("parsea CSV es-AR con ; y montos con coma decimal", () => {
    const csv = [
      "Fecha;Concepto;Importe;Saldo",
      "15/07/2026;Transferencia recibida;5.000,00;15.000,00",
      "20/07/2026;Comisión mantenimiento;-350,00;14.650,00",
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines).toHaveLength(2)
    expect(result.lines[0]).toEqual({
      line_no: 1,
      value_date: "2026-07-15",
      description: "Transferencia recibida",
      amount: "5000.00",
      balance: "15000.00",
      warnings: [],
      source_row: 2, // F5: fila física del archivo (1 = encabezado)
    })
    expect(result.lines[1].amount).toBe("-350.00")
    expect(result.lines[1].source_row).toBe(3)
  })

  it("parsea CSV plano con , e ISO dates, sin saldo", () => {
    const csv = [
      "date,description,amount",
      "2026-07-15,Wire in,5000.00",
      "2026-07-25,Wire out,-100.5",
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines[0].value_date).toBe("2026-07-15")
    expect(result.lines[1].amount).toBe("-100.5")
    expect(result.lines[0].balance).toBeNull()
  })

  it("rechaza headers no reconocidos con mensaje claro", () => {
    const csv = ["col1;col2", "a;b"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.error).toContain("fecha")
  })

  it("F8: fecha inválida en la única fila descarta esa fila (mismo canal que importe) y el archivo queda sin filas válidas", () => {
    const csv = ["Fecha;Importe", "99/99/2026;100"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.error).toContain("no contiene filas de movimientos válidas")
    expect(result.error).toContain("fila 2")
    expect(result.error).toContain('Fecha inválida: "99/99/2026"')
  })
})

// F8 — una fecha inválida ya NO aborta el archivo completo: se descarta esa
// fila puntual por el mismo canal `discarded` que el importe ilegible, con
// motivo, y el resto del archivo se sigue procesando.
describe("parseBankStatementText — F8: fecha inválida descarta solo esa línea", () => {
  it("no aborta el resto del archivo: la fila con fecha inválida se descarta y la válida se importa", () => {
    const csv = [
      "Fecha;Importe",
      "99/99/2026;100",
      "16/07/2026;200,00",
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].amount).toBe("200.00")
    expect(result.discarded).toEqual([
      { row: 2, reason: 'Fecha inválida: "99/99/2026".' },
    ])
  })
})

// candidatos-importadores (2026-09-09): guard de importe inválido REAL — una
// fila con importe ilegible o vacío se descarta individualmente (con motivo
// en `discarded`), en vez de abortar el archivo completo o convertirse en un
// valor silencioso.
describe("parseBankStatementText — descarte de líneas con importe ilegible", () => {
  it('descarta una fila con importe ilegible ("abc") sin abortar el resto del archivo', () => {
    const csv = [
      "Fecha;Concepto;Importe",
      "15/07/2026;Movimiento raro;abc",
      "16/07/2026;Movimiento ok;100,00",
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].description).toBe("Movimiento ok")
    expect(result.discarded).toEqual([
      { row: 2, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
    ])
  })

  it("descarta una fila con importe vacío (fecha presente, importe en blanco)", () => {
    const csv = [
      "Fecha;Concepto;Importe",
      "15/07/2026;Sin importe;",
      "16/07/2026;Movimiento ok;100,00",
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines).toHaveLength(1)
    expect(result.discarded).toEqual([
      { row: 2, reason: "Importe vacío — no se puede registrar un movimiento sin importe." },
    ])
  })

  it("si TODAS las filas tienen importe ilegible, el resultado es ok:false (sin filas válidas)", () => {
    const csv = ["Fecha;Importe", "15/07/2026;abc"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.error).toContain("no contiene filas de movimientos válidas")
  })

  it("F4: si TODAS las filas se descartan, el error incluye el conteo y el motivo de cada descarte (no se pierden)", () => {
    const csv = ["Fecha;Importe", "15/07/2026;abc", "16/07/2026;xyz"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.error).toContain("no contiene filas de movimientos válidas")
    expect(result.error).toContain("2 filas descartadas")
    expect(result.error).toContain("fila 2")
    expect(result.error).toContain('"abc"')
    expect(result.error).toContain("fila 3")
    expect(result.error).toContain('"xyz"')
  })
})

// candidatos-importadores: canal de avisos por línea — importe/saldo con
// punto de miles ambiguo ("1.500") avisa sin bloquear, igual que los
// importadores de productos/gastos (mismo helper `amountAmbiguityWarning`).
describe("parseBankStatementText — avisos de ambigüedad (importe y saldo)", () => {
  it('"1.500" en Importe → el punto se lee como decimal (string preservado, "1.500" = 1,5) CON warning de ambigüedad', () => {
    const csv = ["Fecha;Importe", "15/07/2026;1.500"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    // El importe se preserva como string (RN-D4, sin pasar por float): "1.500"
    // literal, que representa el mismo valor que "1.5" — el warning sí
    // muestra el valor numérico interpretado ($ 1,5) para que quede claro.
    expect(result.lines[0].amount).toBe("1.500")
    expect(result.lines[0].warnings).toEqual([
      'Importe ambiguo: "1.500" — se interpretó como $ 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it('"1.500,00" en Importe → SIN warning (no es ambiguo, coma decimal explícita)', () => {
    const csv = ["Fecha;Importe", "15/07/2026;1.500,00"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines[0].amount).toBe("1500.00")
    expect(result.lines[0].warnings).toEqual([])
  })

  it('"1.500" en Saldo (opcional) → mismo aviso de ambigüedad, en la misma línea', () => {
    const csv = ["Fecha;Importe;Saldo", "15/07/2026;100,00;1.500"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines[0].balance).toBe("1.500")
    expect(result.lines[0].warnings).toEqual([
      'Saldo ambiguo: "1.500" — se interpretó como $ 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })

  it("saldo ilegible NO descarta la fila: importe válido queda, saldo null + warning", () => {
    const csv = ["Fecha;Importe;Saldo", "15/07/2026;100,00;abc"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines).toHaveLength(1)
    expect(result.lines[0].amount).toBe("100.00")
    expect(result.lines[0].balance).toBeNull()
    expect(result.lines[0].warnings).toEqual([
      'Saldo ilegible: "abc" — se ignora (no bloquea la fila; el saldo es informativo).',
    ])
  })

  it("F11: un importe ilegible con texto crudo largo se acota en el motivo del descarte (no infla el mensaje sin límite)", () => {
    const longRaw = "x".repeat(80)
    const csv = ["Fecha;Importe", `15/07/2026;${longRaw}`, "16/07/2026;100,00"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.discarded).toHaveLength(1)
    // El mensaje fijo alrededor del valor trunca ya suma ~70 caracteres —
    // 130 deja margen sin dejar de probar que el crudo de 80 no viaja entero.
    expect(result.discarded[0].reason.length).toBeLessThan(130)
    expect(result.discarded[0].reason).toContain(longRaw.slice(0, 40))
    expect(result.discarded[0].reason).not.toContain(longRaw)
  })

  it('F6: "1,500" en Importe (coma, dominio bancario con loneCommaIsDecimal) avisa igual que el punto', () => {
    const csv = ["Fecha;Importe", "15/07/2026;1,500"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.lines[0].amount).toBe("1.500")
    expect(result.lines[0].warnings).toEqual([
      'Importe ambiguo: "1,500" — se interpretó como $ 1,5. Usá coma para decimales y ningún separador para miles.',
    ])
  })
})

// F5 — la línea normalizada lleva la fila física del archivo (`source_row`),
// la MISMA convención numérica que usa `discarded[].row` — antes los avisos
// se numeraban con `line_no` (índice entre filas válidas, se renumera tras
// cada descarte) mientras los descartes usaban la fila física, dos
// numeraciones distintas conviviendo en la misma lista de la UI.
describe("parseBankStatementText — F5: source_row unifica la numeración con `discarded`", () => {
  it("source_row de una línea válida coincide con la convención física que ya usa `discarded[].row`", () => {
    const csv = [
      "Fecha;Importe",
      "15/07/2026;abc",   // fila física 2 → descartada
      "16/07/2026;1.500", // fila física 3 → válida, con warning
    ].join("\n")

    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.discarded).toEqual([
      { row: 2, reason: 'Importe ilegible: "abc" — no se puede registrar un movimiento sin importe.' },
    ])
    // line_no se renumera (única línea válida = 1), pero source_row conserva
    // la fila física real del archivo (3) — la misma que usaría `discarded`
    // si esta línea también se hubiese descartado.
    expect(result.lines[0].line_no).toBe(1)
    expect(result.lines[0].source_row).toBe(3)
  })
})

// F10 — el hook NO debe mandar `warnings`/`source_row` al backend (Pydantic
// los ignora — peso muerto en el payload). Sólo viajan los 5 campos que el
// backend modela.
describe("useImportStatement — F10: mapea las líneas al shape del backend antes de postear", () => {
  it("no manda warnings ni source_row: sólo {line_no, value_date, description, amount, balance}", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      import_id: "imp-1",
      line_count: 1,
      period_from: "2026-07-15",
      period_to: "2026-07-15",
      replayed: false,
    })

    const { result } = renderHook(() => useImportStatement(BANK_ACCOUNT_ID), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotencyKey: "import-abc",
        fileName: "extracto.csv",
        fileHash: "abc123",
        lines: [
          {
            line_no: 1,
            value_date: "2026-07-15",
            description: "Movimiento",
            amount: "100.00",
            balance: null,
            warnings: ["Importe ambiguo: ..."],
            source_row: 2,
          },
        ],
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/bank-accounts/${BANK_ACCOUNT_ID}/statement-imports`,
      {
        file_name: "extracto.csv",
        file_hash: "abc123",
        lines: [
          {
            line_no: 1,
            value_date: "2026-07-15",
            description: "Movimiento",
            amount: "100.00",
            balance: null,
          },
        ],
      },
      { "Idempotency-Key": "import-abc" }
    )
  })
})

describe("parseAmount / parseDate", () => {
  it("acepta formato argentino, US y plano", () => {
    expect(parseAmount("1.234,56")).toBe("1234.56")
    expect(parseAmount("1,234.56")).toBe("1234.56")
    expect(parseAmount("-350")).toBe("-350")
    expect(parseAmount("$ -1.234,56")).toBe("-1234.56")
  })

  it("acepta la convención contable de paréntesis para negativos", () => {
    expect(parseAmount("(1.234,56)")).toBe("-1234.56")
  })

  it("devuelve null en montos inválidos", () => {
    expect(parseAmount("abc")).toBeNull()
    expect(parseAmount("")).toBeNull()
  })

  it("normaliza dd/mm/yyyy y dd-mm-yyyy a ISO", () => {
    expect(parseDate("15/07/2026")).toBe("2026-07-15")
    expect(parseDate("5-7-2026")).toBe("2026-07-05")
    expect(parseDate("2026-07-15")).toBe("2026-07-15")
  })

  it("devuelve null en fechas inválidas", () => {
    expect(parseDate("31/02/2026")).toBeNull()
    expect(parseDate("no-fecha")).toBeNull()
  })
})

// ═══════════════════════════════════════════════════════════════════════════════
// Hooks
// ═══════════════════════════════════════════════════════════════════════════════

describe("useReconciliationSessions", () => {
  it("mapea la sesión API (snake_case) al dominio (camelCase)", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      {
        id: SESSION_ID,
        bank_account_id: BANK_ACCOUNT_ID,
        status: "open",
        period_from: "2026-07-01",
        period_to: "2026-07-31",
        statement_closing_balance: "14750.00",
        ledger_closing_balance: null,
        difference: null,
        close_reason: null,
        opened_at: "2026-07-02T10:00:00Z",
        closed_at: null,
      },
    ])

    const { result } = renderHook(() => useReconciliationSessions(BANK_ACCOUNT_ID), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith(
      `/bank-accounts/${BANK_ACCOUNT_ID}/reconciliation-sessions`
    )
    expect(result.current.data![0]).toMatchObject({
      id: SESSION_ID,
      bankAccountId: BANK_ACCOUNT_ID,
      status: "open",
      statementClosingBalance: 14750,
      ledgerClosingBalance: null,
    })
  })
})

describe("useCreateMatch", () => {
  it("postea statement_line_ids/bank_movement_ids en snake_case", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      match_group: MATCH_GROUP,
      session_id: SESSION_ID,
      line_count: 1,
      movement_count: 1,
      amount: "5000.00",
    })

    const { result } = renderHook(() => useCreateMatch(SESSION_ID), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        statementLineIds: [LINE_ID],
        bankMovementIds: [MOVEMENT_ID],
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/reconciliation-sessions/${SESSION_ID}/matches`,
      {
        statement_line_ids: [LINE_ID],
        bank_movement_ids: [MOVEMENT_ID],
      }
    )
  })
})

describe("useCloseSession", () => {
  it("envía close_reason null cuando no hay motivo", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      session_id: SESSION_ID,
      status: "closed",
      difference: "0.00",
    })

    const { result } = renderHook(() => useCloseSession(SESSION_ID), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ closeReason: null })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/reconciliation-sessions/${SESSION_ID}/close`,
      { close_reason: null }
    )
  })

  it("propaga el motivo cuando existe (RN-A5)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      session_id: SESSION_ID,
      status: "closed",
      difference: "100.00",
    })

    const { result } = renderHook(() => useCloseSession(SESSION_ID), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ closeReason: "transferencia pendiente" })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/reconciliation-sessions/${SESSION_ID}/close`,
      { close_reason: "transferencia pendiente" }
    )
  })
})

describe("useUndoMatch", () => {
  it("postea el undo con match_group en la URL y undo_reason en el body", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      match_group: MATCH_GROUP,
      undone_rows: 2,
      movement_count: 1,
      status: "undone",
    })

    const { result } = renderHook(() => useUndoMatch(SESSION_ID), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        matchGroup: MATCH_GROUP,
        undoReason: "monto correspondía a otra transferencia",
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      `/reconciliation-sessions/${SESSION_ID}/matches/${MATCH_GROUP}/undo`,
      { undo_reason: "monto correspondía a otra transferencia" }
    )
  })
})
