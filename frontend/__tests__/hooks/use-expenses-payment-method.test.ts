/**
 * useExpenses — forma de pago, contexto y listado paginado
 * (gastos-forma-pago, grupo 9).
 *
 * Ciclo: RED → GREEN → TRIANGULATE. Mock: `@/lib/api/python-client`.
 *
 * Cubre, en este orden:
 *   9.1 el alta manda `branch_id` (hoy el form lo manda y el hook lo tira:
 *       0 de 175 gastos en prod tienen sucursal);
 *   9.2 la edición manda `cost_center_id` (hoy se borra en cada edición, en
 *       silencio: 0 de 175 gastos tienen centro de costo);
 *   9.3 payload completo + contrato TRI-ESTADO en el PUT + `mapExpense` con
 *       los derivados de bloqueo;
 *   9.3b el hook es el origen de datos del listado: paginación y filtros
 *       server-side sobre el envelope `{items,total,page,pages}` (D18);
 *   9.4 el SET COMPLETO de invalidaciones de las tres mutaciones.
 *
 * Por qué 9.4 no es un test de ceremonia: el precedente ya se pagó una vez
 * en ventas (`fix-supplier-account-ui-post-delete`), donde faltaba
 * `customerAccounts` y la cuenta corriente quedaba stale en pantalla. Un
 * gasto en efectivo escribe en `cash_movements` y uno por transferencia en
 * `bank_movements`: invalidar sólo `expenses` deja /caja, /banco y la
 * conciliación mostrando un saldo que ya no existe.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useExpenses } from "@/hooks/data/use-expenses-query"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

// ── Fixtures ────────────────────────────────────────────────────────────────

const ROW = {
  id: "exp-1",
  user_id: "user-1",
  account_id: "acc-1",
  category: "Alquiler",
  amount: "5000",
  description: "Alquiler enero",
  date: "2026-01-15T00:00:00Z",
  created_at: "2026-01-15T10:00:00Z",
  cost_center_id: "cc-1",
  branch_id: "branch-1",
  payment_method_id: "pm-cash",
  payment_method_name: "Efectivo",
  payment_method_kind: "cash",
  is_payment_locked: true,
  has_cash_movement: true,
  has_bank_movement: false,
  is_delete_blocked: true,
}

function page(items: unknown[], total = items.length) {
  return { items, total, page: 0, pages: total === 0 ? 0 : 1 }
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

async function mounted() {
  vi.mocked(pythonClient.get).mockResolvedValue(page([ROW]))
  const { wrapper, queryClient } = makeWrapper()
  const spy = vi.spyOn(queryClient, "invalidateQueries")
  const { result } = renderHook(() => useExpenses(), { wrapper })
  await waitFor(() => expect(result.current.isLoading).toBe(false))
  return { result, spy }
}

const invalidatedRoots = (spy: ReturnType<typeof vi.spyOn>) =>
  spy.mock.calls.map((c: unknown[]) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0])

beforeEach(() => {
  vi.clearAllMocks()
})

// ── 9.1 / 9.3 — alta ────────────────────────────────────────────────────────

describe("useExpenses — alta (9.1, 9.3)", () => {
  it("BUG PREEXISTENTE: `branch_id` viaja en el payload del alta", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.post).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.addExpense({
        date: "2026-02-01",
        category: "Marketing",
        description: "Redes",
        amount: 800,
        branchId: "branch-9",
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      "/expenses",
      expect.objectContaining({ branch_id: "branch-9" }),
    )
  })

  it("manda los cinco campos nuevos del alta, y `null` cuando no se informan", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.post).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.addExpense({
        date: "2026-02-01",
        category: "Marketing",
        description: "Redes",
        amount: 800,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/expenses", {
      category: "Marketing",
      description: "Redes",
      amount: 800,
      date: "2026-02-01",
      cost_center_id: null,
      branch_id: null,
      payment_method_id: null,
      cash_session_id: null,
      bank_account_id: null,
    })
  })

  it("el opt-in de caja y la cuenta bancaria viajan cuando el formulario los informa", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.post).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.addExpense({
        date: "2026-02-01",
        category: "Servicios",
        description: "Luz",
        amount: 1200,
        paymentMethodId: "pm-cash",
        cashSessionId: "sess-1",
        bankAccountId: null,
      })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(
      "/expenses",
      expect.objectContaining({
        payment_method_id: "pm-cash",
        cash_session_id: "sess-1",
        bank_account_id: null,
      }),
    )
  })
})

// ── 9.2 / 9.3 — edición y contrato tri-estado ───────────────────────────────

describe("useExpenses — edición (9.2, 9.3)", () => {
  it("BUG PREEXISTENTE: `cost_center_id` viaja en el PUT y deja de borrarse solo", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1",
        date: "2026-01-15",
        category: "Alquiler",
        description: "Alquiler enero",
        amount: 5000,
        costCenterId: "cc-1",
      })
    })

    expect(pythonClient.put).toHaveBeenCalledWith(
      "/expenses/exp-1",
      expect.objectContaining({ cost_center_id: "cc-1" }),
    )
  })

  it("TRI-ESTADO: la clave AUSENTE del objeto no viaja en el JSON (preservar)", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1",
        date: "2026-01-15",
        category: "Alquiler",
        description: "Alquiler enero",
        amount: 5000,
      })
    })

    const body = vi.mocked(pythonClient.put).mock.calls[0][1] as Record<string, unknown>
    expect("cost_center_id" in body).toBe(false)
    expect("branch_id" in body).toBe(false)
    expect("payment_method_id" in body).toBe(false)
  })

  it("TRI-ESTADO: `null` explícito SÍ viaja (desimputar), y desimputar uno no toca a los otros", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1",
        date: "2026-01-15",
        category: "Alquiler",
        description: "Alquiler enero",
        amount: 5000,
        paymentMethodId: null,
      })
    })

    const body = vi.mocked(pythonClient.put).mock.calls[0][1] as Record<string, unknown>
    expect(body.payment_method_id).toBeNull()
    expect("cost_center_id" in body).toBe(false)
    expect("branch_id" in body).toBe(false)
  })

  it("TRI-ESTADO: un uuid reimputa, campo por campo", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1",
        date: "2026-01-15",
        category: "Alquiler",
        description: "Alquiler enero",
        amount: 5000,
        paymentMethodId: "pm-transfer",
        branchId: "branch-2",
        costCenterId: "cc-9",
      })
    })

    expect(pythonClient.put).toHaveBeenCalledWith("/expenses/exp-1", {
      category: "Alquiler",
      description: "Alquiler enero",
      amount: 5000,
      date: "2026-01-15",
      payment_method_id: "pm-transfer",
      branch_id: "branch-2",
      cost_center_id: "cc-9",
    })
  })

  it("la edición NO manda cash_session_id ni bank_account_id: la edición no postea movimientos (D11/D13)", async () => {
    const { result } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1",
        date: "2026-01-15",
        category: "Alquiler",
        description: "Alquiler enero",
        amount: 5000,
        paymentMethodId: "pm-cash",
      })
    })

    const body = vi.mocked(pythonClient.put).mock.calls[0][1] as Record<string, unknown>
    expect("cash_session_id" in body).toBe(false)
    expect("bank_account_id" in body).toBe(false)
  })
})

// ── 9.3 — mapExpense: derivados de bloqueo ──────────────────────────────────

describe("useExpenses — mapeo de lectura (9.3)", () => {
  it("mapea forma de pago, sucursal y los CUATRO derivados de bloqueo", async () => {
    const { result } = await mounted()

    expect(result.current.expenses[0]).toMatchObject({
      id: "exp-1",
      date: "2026-01-15",
      branchId: "branch-1",
      costCenterId: "cc-1",
      paymentMethodId: "pm-cash",
      paymentMethodName: "Efectivo",
      paymentMethodKind: "cash",
      isPaymentLocked: true,
      hasCashMovement: true,
      hasBankMovement: false,
      isDeleteBlocked: true,
    })
  })

  it("una fila sin derivados (gasto histórico) se lee como NO bloqueada, sin inventar imputaciones", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(
      page([{
        id: "exp-old",
        user_id: "u",
        category: "Otros",
        amount: "100",
        description: null,
        date: "2026-03-07T16:33:00Z",
        created_at: "2026-03-07T16:33:00Z",
      }]),
    )
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useExpenses(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.expenses[0]).toMatchObject({
      id: "exp-old",
      // La hora ≠ 00:00 de las filas históricas no se filtra a la UI.
      date: "2026-03-07",
      description: "",
      paymentMethodId: null,
      paymentMethodName: null,
      branchId: null,
      isPaymentLocked: false,
      hasCashMovement: false,
      hasBankMovement: false,
      isDeleteBlocked: false,
    })
  })
})

// ── 9.3b — listado paginado server-side (D18) ───────────────────────────────

describe("useExpenses — listado paginado (9.3b, D18)", () => {
  it("consume el envelope {items,total,page,pages} y expone la meta de paginación", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [ROW], total: 137, page: 0, pages: 6 })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useExpenses(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.expenses).toHaveLength(1)
    expect(result.current.meta.totalCount).toBe(137)
    expect(result.current.meta.pageCount).toBe(6)
    expect(result.current.meta.page).toBe(0)
  })

  it("arranca pidiendo page=0 con el page_size por defecto", async () => {
    await mounted()
    expect(pythonClient.get).toHaveBeenCalledWith("/expenses?page=0&page_size=25")
  })

  it("los filtros viajan como query params server-side y resetean la página a 0", async () => {
    const { result } = await mounted()

    await act(async () => { result.current.setPage(3) })
    await waitFor(() => {
      expect(vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0]).toContain("page=3")
    })

    await act(async () => { result.current.setPaymentMethodId("pm-transfer") })
    await waitFor(() => {
      expect(vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0]).toContain("payment_method_id=pm-transfer")
    })
    // El reseteo importa: filtrar quedándose en la página 3 muestra "sin
    // resultados" sobre un filtro que sí tiene filas. Se mide sobre la URL
    // pedida, no sobre `meta.page`, que buildPaginationMeta clampea al
    // pageCount del fixture.
    expect(vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0]).toContain("page=0")

    await act(async () => {
      result.current.setSearch("luz")
      result.current.setDateFrom("2026-01-01")
      result.current.setDateTo("2026-01-31")
      result.current.setCostCenterId("cc-1")
    })
    await waitFor(() => {
      const url = vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0] as string
      expect(url).toContain("search=luz")
      expect(url).toContain("date_from=2026-01-01")
      expect(url).toContain("date_to=2026-01-31")
      expect(url).toContain("cost_center_id=cc-1")
      expect(url).toContain("payment_method_id=pm-transfer")
    })
  })

  it("un filtro vacío NO viaja como parámetro en blanco", async () => {
    const { result } = await mounted()
    await act(async () => { result.current.setSearch("luz") })
    await waitFor(() => expect(vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0]).toContain("search=luz"))

    // Volver a vacío y además mover otro filtro, para forzar una petición
    // nueva: repetir exactamente los params anteriores pega en la caché de
    // TanStack y no emite request (por eso no alcanza con mirar la última).
    await act(async () => {
      result.current.setSearch("")
      result.current.setCostCenterId("cc-1")
    })
    await waitFor(() => {
      expect(vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0]).toContain("cost_center_id=cc-1")
    })

    // Ninguna de las URLs pedidas lleva un parámetro con valor vacío.
    const urls = vi.mocked(pythonClient.get).mock.calls.map((c) => c[0] as string)
    expect(urls.some((u) => /(?:^|[?&])[a-z_]+=(?:&|$)/.test(u))).toBe(false)
    expect(urls.at(-1)).not.toContain("search=")
  })

  it("envelope vacío: lista vacía, sin error y sin páginas", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue(page([], 0))
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useExpenses(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.expenses).toEqual([])
    expect(result.current.isError).toBe(false)
    expect(result.current.meta.totalCount).toBe(0)
  })
})

// ── 9.4 — set completo de invalidaciones ────────────────────────────────────

const LEDGER_KEYS = [
  "expenses",
  "cashSessions",
  "cashMovements",
  "bankAccounts",
  "bankReconciliation",
  "paymentMethods",
]

describe("useExpenses — invalidaciones (9.4)", () => {
  it("el ALTA invalida los seis grupos, no sólo `expenses`", async () => {
    const { result, spy } = await mounted()
    vi.mocked(pythonClient.post).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.addExpense({ date: "2026-02-01", category: "Otros", description: "x", amount: 1 })
    })

    const roots = invalidatedRoots(spy)
    for (const key of LEDGER_KEYS) expect(roots).toContain(key)
  })

  it("la EDICIÓN invalida los seis grupos", async () => {
    const { result, spy } = await mounted()
    vi.mocked(pythonClient.put).mockResolvedValueOnce(ROW)

    await act(async () => {
      await result.current.updateExpense({
        id: "exp-1", date: "2026-01-15", category: "Alquiler", description: "x", amount: 5000,
      })
    })

    const roots = invalidatedRoots(spy)
    for (const key of LEDGER_KEYS) expect(roots).toContain(key)
  })

  it("el BORRADO invalida los seis grupos — es el que compensa las dos patas", async () => {
    const { result, spy } = await mounted()
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    await act(async () => {
      await result.current.deleteExpense("exp-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/expenses/exp-1")
    const roots = invalidatedRoots(spy)
    for (const key of LEDGER_KEYS) expect(roots).toContain(key)
  })
})
