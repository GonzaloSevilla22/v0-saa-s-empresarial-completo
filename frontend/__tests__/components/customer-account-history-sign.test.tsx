/**
 * Regresión visual reportada por el PO (2026-08-21): el cobro se veía
 * "−$-58.750,00" — el componente antepone el signo ("+"/"−") pero el monto
 * de cobros/NC/ajustes vive NEGATIVO en el ledger y toLocaleString le
 * agregaba el suyo. El monto debe formatearse en valor absoluto.
 */
import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { CustomerAccountHistory } from "@/components/customer-accounts/CustomerAccountHistory"
import type { CustomerAccountMovement } from "@/hooks/data/use-customer-account"

const MOVEMENTS: CustomerAccountMovement[] = [
  {
    id: "m1",
    movementType: "payment_received",
    amount: -58750,
    balanceAfter: 114550,
    createdAt: "2026-08-21T15:19:54.000Z",
  } as CustomerAccountMovement,
  {
    id: "m2",
    movementType: "sale",
    amount: 98150,
    balanceAfter: 173300,
    createdAt: "2026-08-20T23:49:37.000Z",
  } as CustomerAccountMovement,
  {
    id: "m3",
    movementType: "adjustment",
    amount: -75150,
    balanceAfter: 39400,
    createdAt: "2026-08-21T15:24:22.000Z",
  } as CustomerAccountMovement,
]

describe("CustomerAccountHistory — signo único en importes", () => {
  it("un cobro (monto negativo en el ledger) muestra −$ una sola vez", () => {
    render(<CustomerAccountHistory movements={MOVEMENTS} />)

    // Mobile + desktop renderizan el mismo importe: al menos una ocurrencia
    // del formato correcto y NINGUNA del doble signo.
    expect(screen.getAllByText("−$58.750,00").length).toBeGreaterThan(0)
    expect(screen.queryByText(/−\$-/)).toBeNull()
    expect(screen.queryByText("−$-58.750,00")).toBeNull()
  })

  it("una venta a crédito conserva el + con el monto positivo", () => {
    render(<CustomerAccountHistory movements={MOVEMENTS} />)

    expect(screen.getAllByText("+$98.150,00").length).toBeGreaterThan(0)
  })

  it("un ajuste negativo también muestra un solo signo y su etiqueta", () => {
    render(<CustomerAccountHistory movements={MOVEMENTS} />)

    expect(screen.getAllByText("−$75.150,00").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Ajuste").length).toBeGreaterThan(0)
  })
})
