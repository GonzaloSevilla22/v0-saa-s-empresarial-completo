/**
 * `useSaleCheckout` — bloqueo de «confirmar» y sesión de caja a mandar
 * (presupuestos-modulo D12 / remitos-venta), con el estado de CARGA del opt-in de
 * caja (fix `caja-optin-carga`).
 *
 * El hook ya bloqueaba la venta en efectivo SIN sesión («Abrí la caja…»), pero ese
 * bloqueo se disparaba también mientras la sesión todavía cargaba: el botón no
 * dejaba confirmar (bien) pero el texto afirmaba «abrí la caja» cuando en realidad
 * sólo faltaba esperar un instante. Ahora la espera tiene su propio bloqueo.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook } from "@testing-library/react"

const paymentMethodsMock = vi.fn()
const cashOptinMock = vi.fn()

vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: (...args: unknown[]) => paymentMethodsMock(...args),
}))
vi.mock("@/hooks/use-cash-optin", () => ({
  useCashOptin: (...args: unknown[]) => cashOptinMock(...args),
}))

import {
  useSaleCheckout,
  SALE_CHECKOUT_NO_CASH_SESSION_REASON,
} from "@/hooks/use-sale-checkout"

const METHODS = [
  { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true },
  { id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true },
  { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true },
]

function cashState(over: Record<string, unknown> = {}) {
  return {
    isCashSelected: false,
    isDateToday: true,
    effectiveBranchId: "branch-1",
    cashboxId: null,
    session: null,
    eligible: false,
    isLoading: false,
    reason: "Sólo un pago en efectivo puede registrarse en la caja.",
    ...over,
  }
}

const base = { paymentMethodId: null, branchId: "branch-1", clientId: null }

beforeEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
  cashOptinMock.mockReturnValue(cashState())
})

describe("useSaleCheckout — caja cargando (caja-optin-carga)", () => {
  it("efectivo con la caja todavía cargando: block='cash_loading', motivo «Verificando la caja…» y NO manda sesión", () => {
    cashOptinMock.mockReturnValue(cashState({ isCashSelected: true, isLoading: true }))
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.block).toBe("cash_loading")
    expect(result.current.blockedReason).toBe("Verificando la caja…")
    expect(result.current.cashSessionId).toBeNull()
  })

  it("la espera NO se disfraza de «abrí la caja»: el motivo de caja cerrada es otro", () => {
    cashOptinMock.mockReturnValue(cashState({ isCashSelected: true, isLoading: true }))
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.blockedReason).not.toBe(SALE_CHECKOUT_NO_CASH_SESSION_REASON)
  })

  it("resuelta CON sesión: se desbloquea y manda la sesión", () => {
    cashOptinMock.mockReturnValue(
      cashState({ isCashSelected: true, session: { id: "session-1" }, eligible: true }),
    )
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.block).toBeNull()
    expect(result.current.blockedReason).toBeNull()
    expect(result.current.cashSessionId).toBe("session-1")
  })

  it("resuelta SIN sesión: sigue bloqueando como antes («abrí la caja»), no como carga", () => {
    cashOptinMock.mockReturnValue(cashState({ isCashSelected: true }))
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.block).toBe("cash_session")
    expect(result.current.blockedReason).toBe(SALE_CHECKOUT_NO_CASH_SESSION_REASON)
    expect(result.current.cashSessionId).toBeNull()
  })

  it("forma de pago que no es efectivo: no hay espera ni bloqueo", () => {
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-transfer" }))

    expect(result.current.block).toBeNull()
    expect(result.current.cashSessionId).toBeNull()
  })

  it("sin forma de pago elegida: manda el bloqueo de forma de pago aunque la caja diga que carga", () => {
    cashOptinMock.mockReturnValue(cashState({ isCashSelected: true, isLoading: true }))
    const { result } = renderHook(() => useSaleCheckout(base))

    expect(result.current.block).toBe("payment_method")
  })

  it("pasa a useCashOptin el kind, la sucursal y requiresDate=false (la venta se cierra en el instante)", () => {
    renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(cashOptinMock).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "cash", branchId: "branch-1", document: "venta", requiresDate: false }),
    )
  })
})

describe("useSaleCheckout — bloqueos que no son de caja (sin regresión)", () => {
  it("cuenta corriente sin cliente: block='client'", () => {
    const { result } = renderHook(() => useSaleCheckout({ ...base, paymentMethodId: "pm-credit" }))
    expect(result.current.block).toBe("client")
  })

  it("cuenta corriente con cliente: sin bloqueo", () => {
    const { result } = renderHook(() =>
      useSaleCheckout({ ...base, paymentMethodId: "pm-credit", clientId: "client-1" }),
    )
    expect(result.current.block).toBeNull()
  })
})
