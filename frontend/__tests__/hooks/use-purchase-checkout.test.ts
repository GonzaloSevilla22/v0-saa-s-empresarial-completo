/**
 * remitos-compra (tanda B, 7.3, D11) — `usePurchaseCheckout`: lo que se DERIVA de
 * los campos de cierre de una compra (forma de pago, sucursal, fecha, proveedor),
 * extraído de `purchase-form.tsx` para que el formulario y el diálogo que convierte
 * un remito de compra lo compartan sin copiarlo.
 *
 * Es el espejo de `useSaleCheckout`: resuelve el `kind` de la forma de pago, las
 * tres condiciones del opt-in de caja (`useCashOptin`, tercer consumidor), la
 * intención de registrar en caja (PRE-MARCADA: caja-compras-cobranzas D4) y el saldo
 * del proveedor a crédito. No decide nada: la autoridad es la RPC.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"

const paymentMethodsMock = vi.fn()
const cashOptinMock = vi.fn()
const supplierAccountMock = vi.fn()

vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: (...args: unknown[]) => paymentMethodsMock(...args),
}))
vi.mock("@/hooks/use-cash-optin", () => ({
  useCashOptin: (...args: unknown[]) => cashOptinMock(...args),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: (...args: unknown[]) => supplierAccountMock(...args),
}))

import { usePurchaseCheckout } from "@/hooks/use-purchase-checkout"

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

beforeEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock.mockReturnValue({ paymentMethods: METHODS, isLoading: false })
  cashOptinMock.mockReturnValue(cashState())
  supplierAccountMock.mockReturnValue({ data: undefined })
})

const base = { paymentMethodId: null, branchId: "branch-1", date: "2026-10-15", supplierId: null, total: 0 }

describe("usePurchaseCheckout", () => {
  it("resuelve el kind de la forma de pago elegida; sin forma de pago, null", () => {
    const none = renderHook(() => usePurchaseCheckout(base))
    expect(none.result.current.kind).toBeNull()
    expect(none.result.current.isCredit).toBe(false)

    const credit = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-credit" }))
    expect(credit.result.current.kind).toBe("credit")
    expect(credit.result.current.isCredit).toBe(true)
  })

  it("pasa a useCashOptin el kind, la sucursal, la fecha y el documento «compra»", () => {
    renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash", date: "2026-10-14" }))
    expect(cashOptinMock).toHaveBeenCalledWith({
      kind: "cash", branchId: "branch-1", date: "2026-10-14", document: "compra",
    })
  })

  it("en el alta pide sólo las formas de pago activas; en la edición, el catálogo completo", () => {
    renderHook(() => usePurchaseCheckout(base))
    expect(paymentMethodsMock).toHaveBeenLastCalledWith(false)
    renderHook(() => usePurchaseCheckout({ ...base, isEdit: true }))
    expect(paymentMethodsMock).toHaveBeenLastCalledWith(true)
  })

  it("expone el catálogo que usó (el formulario lo necesita para el kind ORIGINAL de la edición)", () => {
    const { result } = renderHook(() => usePurchaseCheckout(base))
    expect(result.current.paymentMethods).toEqual(METHODS)
  })

  describe("opt-in de caja", () => {
    const eligible = cashState({ isCashSelected: true, eligible: true, session: { id: "session-abcdef123456" } })

    it("arranca PRE-MARCADO y manda la sesión sólo si las tres condiciones se cumplen", () => {
      cashOptinMock.mockReturnValue(eligible)
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))
      expect(result.current.registerInCash).toBe(true)
      expect(result.current.cashSessionId).toBe("session-abcdef123456")
      expect(result.current.showCashBlock).toBe(true)
    })

    it("destildar manda null (la compra no toca caja)", () => {
      cashOptinMock.mockReturnValue(eligible)
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))
      act(() => result.current.setRegisterInCash(false))
      expect(result.current.registerInCash).toBe(false)
      expect(result.current.cashSessionId).toBeNull()
    })

    it("sin sesión abierta (no elegible) manda null aunque esté tildado, pero muestra el bloque con su motivo", () => {
      cashOptinMock.mockReturnValue(
        cashState({ isCashSelected: true, eligible: false, session: null, reason: "No hay caja abierta en esta sucursal" }),
      )
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))
      expect(result.current.registerInCash).toBe(true)
      expect(result.current.cashSessionId).toBeNull()
      expect(result.current.showCashBlock).toBe(true)
    })

    it("con otra forma de pago no hay bloque de caja ni sesión", () => {
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-transfer" }))
      expect(result.current.showCashBlock).toBe(false)
      expect(result.current.cashSessionId).toBeNull()
    })

    it("en la edición NO se ofrece la caja (D8: una compra con caja posteada es inmutable)", () => {
      cashOptinMock.mockReturnValue(eligible)
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash", isEdit: true }))
      expect(result.current.showCashBlock).toBe(false)
      expect(result.current.cashSessionId).toBeNull()
    })
  })

  describe("cuenta corriente del proveedor", () => {
    it("a crédito consulta la cuenta del proveedor y proyecta el saldo con el total", () => {
      supplierAccountMock.mockReturnValue({ data: { balance: 1000 } })
      const { result } = renderHook(() =>
        usePurchaseCheckout({ ...base, paymentMethodId: "pm-credit", supplierId: "sup-1", total: 250 }),
      )
      expect(supplierAccountMock).toHaveBeenLastCalledWith("sup-1")
      expect(result.current.supplierBalance).toBe(1000)
      expect(result.current.projectedBalance).toBe(1250)
      expect(result.current.creditBlockedNoSupplier).toBe(false)
    })

    it("sin la cuenta resuelta, el saldo es 0 y el proyectado es el total", () => {
      const { result } = renderHook(() =>
        usePurchaseCheckout({ ...base, paymentMethodId: "pm-credit", supplierId: "sup-1", total: 80 }),
      )
      expect(result.current.supplierBalance).toBe(0)
      expect(result.current.projectedBalance).toBe(80)
    })

    it("a crédito sin proveedor bloquea y no consulta ninguna cuenta", () => {
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-credit", supplierId: null }))
      expect(result.current.creditBlockedNoSupplier).toBe(true)
      expect(supplierAccountMock).toHaveBeenLastCalledWith(null)
    })

    it("con otra forma de pago no consulta la cuenta aunque haya proveedor", () => {
      const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-transfer", supplierId: "sup-1" }))
      expect(supplierAccountMock).toHaveBeenLastCalledWith(null)
      expect(result.current.creditBlockedNoSupplier).toBe(false)
    })
  })
})

describe("usePurchaseCheckout — caja cargando (caja-optin-carga)", () => {
  const loading = cashState({ isCashSelected: true, isLoading: true })

  it("efectivo con la caja todavía cargando: cashPending=true y NO manda sesión (confirmar ahora la perdería en silencio)", () => {
    cashOptinMock.mockReturnValue(loading)
    const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.cashPending).toBe(true)
    expect(result.current.cashSessionId).toBeNull()
    // El bloque de caja se muestra (ahí vive el «Verificando la caja…»).
    expect(result.current.showCashBlock).toBe(true)
  })

  it("resuelta CON sesión: cashPending=false y manda la sesión pre-marcada", () => {
    cashOptinMock.mockReturnValue(
      cashState({ isCashSelected: true, eligible: true, session: { id: "session-abcdef123456" } }),
    )
    const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.cashPending).toBe(false)
    expect(result.current.cashSessionId).toBe("session-abcdef123456")
  })

  it("resuelta SIN sesión: cashPending=false — no se bloquea para siempre cuando NO hay caja abierta", () => {
    cashOptinMock.mockReturnValue(cashState({ isCashSelected: true }))
    const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash" }))

    expect(result.current.cashPending).toBe(false)
    expect(result.current.cashSessionId).toBeNull()
  })

  it("en la edición no hay caja que esperar (D8): cashPending=false aunque el hook diga que carga", () => {
    cashOptinMock.mockReturnValue(loading)
    const { result } = renderHook(() =>
      usePurchaseCheckout({ ...base, paymentMethodId: "pm-cash", isEdit: true }),
    )

    expect(result.current.cashPending).toBe(false)
  })

  it("forma de pago que no es efectivo: cashPending=false", () => {
    const { result } = renderHook(() => usePurchaseCheckout({ ...base, paymentMethodId: "pm-transfer" }))

    expect(result.current.cashPending).toBe(false)
  })
})
