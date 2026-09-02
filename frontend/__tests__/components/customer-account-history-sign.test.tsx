/**
 * Regresión visual reportada por el PO (2026-08-21): el cobro se veía
 * "−$-58.750,00" — el componente antepone el signo ("+"/"−") pero el monto
 * de cobros/NC/ajustes vive NEGATIVO en el ledger y toLocaleString le
 * agregaba el suyo. El monto debe formatearse en valor absoluto.
 */
import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

// cobranzas-reverso (task 13.1): el componente llama a
// useReversePaymentReceived incondicionalmente — mockeado por completo (sin
// vi.importActual) para no arrastrar el módulo real, que importa
// pythonClient y explota sin NEXT_PUBLIC_BACKEND_URL en el entorno de test
// (mismo motivo por el que RegisterPaymentForms.test.tsx mockea sus hooks en
// vez de stubear la env var). El test file sólo necesita el tipo
// CustomerAccountMovement, que es type-only y se borra en compilación — no
// pasa por este mock.
vi.mock("@/hooks/data/use-customer-account", () => ({
  useReversePaymentReceived: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

import { CustomerAccountHistory } from "@/components/customer-accounts/CustomerAccountHistory"
import type { CustomerAccountMovement } from "@/hooks/data/use-customer-account"

function renderWithClient(ui: React.ReactElement) {
  return render(ui)
}

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
    renderWithClient(<CustomerAccountHistory movements={MOVEMENTS} clientId="c1" />)

    // Mobile + desktop renderizan el mismo importe: al menos una ocurrencia
    // del formato correcto y NINGUNA del doble signo.
    expect(screen.getAllByText("−$58.750,00").length).toBeGreaterThan(0)
    expect(screen.queryByText(/−\$-/)).toBeNull()
    expect(screen.queryByText("−$-58.750,00")).toBeNull()
  })

  it("una venta a crédito conserva el + con el monto positivo", () => {
    renderWithClient(<CustomerAccountHistory movements={MOVEMENTS} clientId="c1" />)

    expect(screen.getAllByText("+$98.150,00").length).toBeGreaterThan(0)
  })

  it("un ajuste negativo también muestra un solo signo y su etiqueta", () => {
    renderWithClient(<CustomerAccountHistory movements={MOVEMENTS} clientId="c1" />)

    expect(screen.getAllByText("−$75.150,00").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Ajuste").length).toBeGreaterThan(0)
  })
})
