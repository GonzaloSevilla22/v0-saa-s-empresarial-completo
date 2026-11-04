/**
 * remitos-compra (tanda B, 7.3, D11) — `useDueDateCascade`: el vencimiento de una
 * deuda (cuenta corriente) pre-cargado por la cascada del plazo y EDITABLE.
 *
 * Se extrajo de `sale-form.tsx` (cobranzas-vencimientos D3/D11) para que lo use
 * también el diálogo que convierte un remito de compra, sin copiar la cascada:
 *   plazo de la CONTRAPARTE (cliente o proveedor) → plazo por defecto de la cuenta
 *   → sin plazo (el cargo nace sin vencimiento).
 * Sólo viaja al servidor lo que el usuario TOCÓ: sin tocar, la cascada
 * AUTORITATIVA se resuelve en `_pay_register_party_charge`, nunca acá.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"

const settings = vi.hoisted(() => ({ data: { defaultPaymentTermsDays: null as number | null } as { defaultPaymentTermsDays: number | null } | undefined }))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: settings.data }),
}))

import { useDueDateCascade } from "@/hooks/use-due-date-cascade"

beforeEach(() => {
  settings.data = { defaultPaymentTermsDays: null }
})

describe("useDueDateCascade", () => {
  it("sin plazo en ningún nivel: el vencimiento queda vacío y no hay origen", () => {
    const { result } = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: null }))
    expect(result.current.dueDate).toBe("")
    expect(result.current.effectiveTermsDays).toBeNull()
    expect(result.current.termsSource).toBeNull()
    expect(result.current.touched).toBe(false)
  })

  it("el plazo de la contraparte resuelve el vencimiento desde la fecha", () => {
    const { result } = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: 15 }))
    expect(result.current.dueDate).toBe("2026-10-30")
    expect(result.current.effectiveTermsDays).toBe(15)
    expect(result.current.termsSource).toBe("entity")
  })

  it("sin plazo propio, el de la cuenta; con ambos, gana el de la contraparte", () => {
    settings.data = { defaultPaymentTermsDays: 30 }
    const account = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: null }))
    expect(account.result.current.dueDate).toBe("2026-11-14")
    expect(account.result.current.termsSource).toBe("account")

    const both = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: 7 }))
    expect(both.result.current.dueDate).toBe("2026-10-22")
    expect(both.result.current.termsSource).toBe("entity")
  })

  it("un plazo de 0 días es un plazo (vence el mismo día), no la ausencia de plazo", () => {
    const { result } = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: 0 }))
    expect(result.current.dueDate).toBe("2026-10-15")
    expect(result.current.termsSource).toBe("entity")
  })

  it("mientras no se toca, cambiar la fecha de la operación recalcula el vencimiento", () => {
    const { result, rerender } = renderHook(
      ({ date }) => useDueDateCascade({ date, entityTermsDays: 10 }),
      { initialProps: { date: "2026-10-15" } },
    )
    expect(result.current.dueDate).toBe("2026-10-25")
    rerender({ date: "2026-10-20" })
    expect(result.current.dueDate).toBe("2026-10-30")
  })

  it("una vez tocado, el vencimiento elegido NO se pisa al cambiar la fecha ni el plazo", () => {
    const { result, rerender } = renderHook(
      ({ date, days }) => useDueDateCascade({ date, entityTermsDays: days }),
      { initialProps: { date: "2026-10-15", days: 10 as number | null } },
    )
    act(() => result.current.setDueDate("2026-12-01"))
    expect(result.current.dueDate).toBe("2026-12-01")
    expect(result.current.touched).toBe(true)

    rerender({ date: "2026-10-20", days: 3 })
    expect(result.current.dueDate).toBe("2026-12-01")
  })

  it("vaciar el campo a mano cuenta como tocado: no vuelve a pre-cargarse solo", () => {
    const { result, rerender } = renderHook(
      ({ date }) => useDueDateCascade({ date, entityTermsDays: 10 }),
      { initialProps: { date: "2026-10-15" } },
    )
    act(() => result.current.setDueDate(""))
    rerender({ date: "2026-10-16" })
    expect(result.current.dueDate).toBe("")
    expect(result.current.touched).toBe(true)
  })

  it("sin fecha todavía no hay vencimiento que calcular", () => {
    const { result } = renderHook(() => useDueDateCascade({ date: "", entityTermsDays: 10 }))
    expect(result.current.dueDate).toBe("")
  })

  it("`valueForServer` sólo devuelve lo tocado: sin tocar es null (la cascada es del servidor)", () => {
    const { result } = renderHook(() => useDueDateCascade({ date: "2026-10-15", entityTermsDays: 10 }))
    expect(result.current.dueDate).toBe("2026-10-25")
    expect(result.current.valueForServer).toBeNull()
    act(() => result.current.setDueDate("2026-11-02"))
    expect(result.current.valueForServer).toBe("2026-11-02")
    act(() => result.current.setDueDate(""))
    expect(result.current.valueForServer).toBeNull()
  })
})
