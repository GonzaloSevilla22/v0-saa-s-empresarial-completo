/**
 * usePaginatedQuery — filtros extra (cost-center-surface)
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 *
 * Por qué existe este test: hasta este change el hook tenía un set de filtros
 * CERRADO (search / dateFrom / dateTo). `applyFilters` se guarda en un ref y
 * las deps de `fetchPage` no incluían ningún filtro externo, así que un filtro
 * capturado en el closure del caller actualizaba el ref pero NO disparaba
 * refetch: el filtro se aplicaba recién en la próxima búsqueda o cambio de
 * página. Era un bug latente para cualquier filtro que se agregara desde
 * afuera, no solo para el de centro de costo.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"

const { createClientMock } = vi.hoisted(() => ({ createClientMock: vi.fn() }))

vi.mock("@/lib/supabase/client", () => ({ createClient: createClientMock }))

import { usePaginatedQuery } from "@/hooks/use-paginated-query"
import type { FilterParams } from "@/lib/pagination-utils"

// ── Mock del query builder de supabase-js ────────────────────────────────────

interface AppliedCall { method: string; args: unknown[] }

let applied: AppliedCall[] = []
let selectCalls = 0

function makeQueryBuilder() {
  const qb: Record<string, unknown> = {}
  const chain = (method: string) => (...args: unknown[]) => {
    applied.push({ method, args })
    return qb
  }
  for (const m of ["ilike", "gte", "lte", "eq", "in", "order", "range"]) {
    qb[m] = vi.fn(chain(m))
  }
  // Thenable: `await qb` resuelve con la forma que esperan las dos queries
  // (la de count lee `count`, la de datos lee `data`). El count es 100 (4
  // páginas de 25) porque `buildPaginationMeta` acota la página al total: con
  // count 0 no se puede estar parado en la página 3.
  qb.then = (resolve: (v: unknown) => unknown) =>
    Promise.resolve({ data: [], count: 100, error: null }).then(resolve)
  return qb
}

beforeEach(() => {
  applied = []
  selectCalls = 0
  createClientMock.mockReturnValue({
    from: vi.fn(() => ({
      select: vi.fn(() => {
        selectCalls += 1
        return makeQueryBuilder()
      }),
    })),
  })
})

// `applyFilters` de la pantalla de gastos, extendido con el centro de costo.
function applyFilters(base: unknown, { search, dateFrom, dateTo, extraFilters }: FilterParams) {
  const q = base as Record<string, (...args: unknown[]) => unknown>
  let out: unknown = base
  if (search)   out = q.ilike("description", `%${search}%`)
  if (dateFrom) out = q.gte("date", dateFrom)
  if (dateTo)   out = q.lte("date", dateTo)
  const costCenterId = extraFilters?.cost_center_id
  if (costCenterId) out = q.eq("cost_center_id", costCenterId)
  return out
}

const eqCalls = () => applied.filter((c) => c.method === "eq")

describe("usePaginatedQuery — extraFilters", () => {
  it("aplica el filtro extra en la query", async () => {
    renderHook(() =>
      usePaginatedQuery({
        table: "expenses",
        applyFilters,
        extraFilters: { cost_center_id: "cc-1" },
      }),
    )

    await waitFor(() => expect(eqCalls().length).toBeGreaterThan(0))
    expect(eqCalls()[0].args).toEqual(["cost_center_id", "cc-1"])
  })

  it("cambiar el filtro extra dispara un refetch con el valor nuevo", async () => {
    const { rerender } = renderHook(
      ({ costCenterId }: { costCenterId: string | null }) =>
        usePaginatedQuery({
          table: "expenses",
          applyFilters,
          extraFilters: { cost_center_id: costCenterId },
        }),
      { initialProps: { costCenterId: "cc-1" as string | null } },
    )

    await waitFor(() => expect(eqCalls().length).toBeGreaterThan(0))
    const callsAfterFirst = selectCalls

    rerender({ costCenterId: "cc-2" })

    // El refetch tiene que ocurrir por el cambio de filtro, sin que medie una
    // búsqueda ni un cambio de página.
    await waitFor(() => expect(selectCalls).toBeGreaterThan(callsAfterFirst))
    await waitFor(() =>
      expect(eqCalls().some((c) => c.args[1] === "cc-2")).toBe(true),
    )
  })

  it("cambiar el filtro extra vuelve a la página 0", async () => {
    const { result, rerender } = renderHook(
      ({ costCenterId }: { costCenterId: string | null }) =>
        usePaginatedQuery({
          table: "expenses",
          applyFilters,
          extraFilters: { cost_center_id: costCenterId },
        }),
      { initialProps: { costCenterId: "cc-1" as string | null } },
    )

    await waitFor(() => expect(eqCalls().length).toBeGreaterThan(0))
    act(() => result.current.setPage(3))
    await waitFor(() => expect(result.current.meta.page).toBe(3))

    rerender({ costCenterId: "cc-2" })

    await waitFor(() => expect(result.current.meta.page).toBe(0))
  })

  it("quitar el filtro extra (null) deja de aplicarlo", async () => {
    const { rerender } = renderHook(
      ({ costCenterId }: { costCenterId: string | null }) =>
        usePaginatedQuery({
          table: "expenses",
          applyFilters,
          extraFilters: { cost_center_id: costCenterId },
        }),
      { initialProps: { costCenterId: "cc-1" as string | null } },
    )

    await waitFor(() => expect(eqCalls().length).toBeGreaterThan(0))
    applied = []

    rerender({ costCenterId: null })

    await waitFor(() => expect(selectCalls).toBeGreaterThan(0))
    await waitFor(() => expect(eqCalls().length).toBe(0))
  })

  it("TRIANGULATE: sin extraFilters el comportamiento previo no cambia", async () => {
    const seen: FilterParams[] = []
    const { result, rerender } = renderHook(() =>
      usePaginatedQuery({
        table: "clients",
        applyFilters: (base, params) => {
          seen.push(params)
          return applyFilters(base, params)
        },
      }),
    )

    await waitFor(() => expect(seen.length).toBeGreaterThan(0))
    expect(eqCalls().length).toBe(0)
    expect(seen[0].extraFilters).toBeUndefined()

    // Un re-render sin cambios no debe disparar fetches nuevos.
    const callsBefore = selectCalls
    rerender()
    await new Promise((r) => setTimeout(r, 20))
    expect(selectCalls).toBe(callsBefore)
    expect(result.current.meta.page).toBe(0)
  })

  it("TRIANGULATE: clearFilters sigue funcionando con extraFilters presente", async () => {
    const { result } = renderHook(() =>
      usePaginatedQuery({
        table: "expenses",
        applyFilters,
        extraFilters: { cost_center_id: "cc-1" },
      }),
    )

    await waitFor(() => expect(eqCalls().length).toBeGreaterThan(0))
    act(() => result.current.setSearch("alquiler"))
    act(() => result.current.setDateFrom("2026-01-01"))
    await waitFor(() => expect(result.current.dateFrom).toBe("2026-01-01"))

    act(() => result.current.clearFilters())

    expect(result.current.search).toBe("")
    expect(result.current.dateFrom).toBe("")
    expect(result.current.dateTo).toBe("")
    expect(result.current.meta.page).toBe(0)
  })
})
