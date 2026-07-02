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
    })
    expect(result.lines[1].amount).toBe("-350.00")
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

  it("rechaza fila con fecha inválida indicando la fila", () => {
    const csv = ["Fecha;Importe", "99/99/2026;100"].join("\n")
    const result = parseBankStatementText(csv)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.error).toContain("Fila 2")
  })
})

describe("parseAmount / parseDate", () => {
  it("acepta formato argentino, US y plano", () => {
    expect(parseAmount("1.234,56")).toBe("1234.56")
    expect(parseAmount("1,234.56")).toBe("1234.56")
    expect(parseAmount("-350")).toBe("-350")
    expect(parseAmount("$ -1.234,56")).toBe("-1234.56")
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
