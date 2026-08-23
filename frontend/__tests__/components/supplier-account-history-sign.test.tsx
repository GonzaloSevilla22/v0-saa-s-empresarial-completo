/**
 * Regresión reportada por el PO (2026-08-22): tras crear un proveedor, una
 * compra a crédito (+8.400), pagarla, crear otra compra a crédito (+8.400) y
 * borrarla, la DB quedó correcta (debit_note −8.400, balance 0) pero la UI
 * mostraba "−$-8.400,00" en el pago (doble signo, mismo bug que
 * customer-account-history-sign.test.tsx) Y, además, derivaba la dirección
 * (+/−) del TIPO de movimiento en vez del SIGNO del monto: la reversa
 * (debit_note, monto negativo, REDUCE la deuda) se hubiera pintado como
 * cargo positivo porque "purchase || debit_note" ⇒ isDebit=true por tipo.
 *
 * Fix: Math.abs para el monto (como en el mold de clientes) + dirección
 * derivada del SIGNO de m.amount (no del tipo).
 */
import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { SupplierAccountHistory } from "@/components/supplier-accounts/SupplierAccountHistory"
import type { SupplierAccountMovement } from "@/hooks/data/use-supplier-account"

const MOVEMENTS: SupplierAccountMovement[] = [
  {
    id: "m1",
    movementType: "purchase",
    amount: 8400,
    balanceAfter: 8400,
    createdAt: "2026-08-20T23:49:37.000Z",
  } as SupplierAccountMovement,
  {
    id: "m2",
    movementType: "payment_made",
    amount: -8400,
    balanceAfter: 0,
    createdAt: "2026-08-21T10:00:00.000Z",
  } as SupplierAccountMovement,
  {
    id: "m3",
    movementType: "debit_note",
    amount: -8400,
    balanceAfter: 0,
    createdAt: "2026-08-22T15:19:54.000Z",
  } as SupplierAccountMovement,
  {
    id: "m4",
    movementType: "adjustment",
    amount: 500,
    balanceAfter: 500,
    createdAt: "2026-08-22T16:00:00.000Z",
  } as SupplierAccountMovement,
  {
    id: "m5",
    movementType: "adjustment",
    amount: -500,
    balanceAfter: 0,
    createdAt: "2026-08-22T16:05:00.000Z",
  } as SupplierAccountMovement,
]

describe("SupplierAccountHistory — signo único y por SIGNO de monto (no por tipo)", () => {
  it("una compra (monto positivo) muestra +$ una sola vez", () => {
    render(<SupplierAccountHistory movements={MOVEMENTS} />)

    expect(screen.getAllByText("+$8.400,00").length).toBeGreaterThan(0)
  })

  it("un pago (monto negativo en el ledger) muestra −$ una sola vez, sin doble signo", () => {
    render(<SupplierAccountHistory movements={MOVEMENTS} />)

    expect(screen.getAllByText("−$8.400,00").length).toBeGreaterThan(0)
    expect(screen.queryByText(/−\$-/)).toBeNull()
    expect(screen.queryByText("−$-8.400,00")).toBeNull()
  })

  it("una nota de débito de REVERSA (monto negativo) se pinta como reducción de deuda, no como cargo", () => {
    render(<SupplierAccountHistory movements={MOVEMENTS} />)

    // Dos movimientos negativos (pago + reversa) × 2 layouts (mobile+desktop
    // renderizan ambos en jsdom, ocultos por CSS) = 4 ocurrencias del "−". La
    // dirección viene del SIGNO del monto, no del tipo "debit_note".
    const minusOccurrences = screen.getAllByText("−$8.400,00")
    expect(minusOccurrences.length).toBe(4)
    expect(screen.getAllByText(/Nota de débito/).length).toBeGreaterThan(0)
  })

  it("un ajuste positivo y uno negativo muestran cada uno su propio signo, con la misma etiqueta", () => {
    render(<SupplierAccountHistory movements={MOVEMENTS} />)

    expect(screen.getAllByText("+$500,00").length).toBeGreaterThan(0)
    expect(screen.getAllByText("−$500,00").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Ajuste").length).toBeGreaterThan(0)
  })
})
