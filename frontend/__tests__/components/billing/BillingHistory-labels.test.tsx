import { describe, it, expect } from "vitest"
import { render, screen, within } from "@testing-library/react"
import { BillingHistory } from "@/components/billing/BillingHistory"
import type { Plan } from "@/lib/types"

/**
 * El historial de /facturacion le muestra al CLIENTE el tipo de evento. Sin
 * etiqueta, cae al string crudo de la base (`trial_pro_granted`,
 * `exemption_granted`…), en inglés y con guiones bajos. Medido en prod el
 * 2026-09-21: 32 filas `trial_pro_granted`, 1 `exemption_granted`,
 * 1 `subscription_payment_approved`, 1 `subscription_ambiguous_resolved`, todas
 * sin etiqueta. Este test fija que todo tipo que existe en la base tenga la suya.
 */

function event(id: string, event_type: string, from_plan: Plan | null, to_plan: Plan | null) {
  return { id, event_type, from_plan, to_plan, amount: null, created_at: "2026-09-21T20:00:00Z" }
}

const LIVE_EVENT_TYPES: Array<[string, string]> = [
  ["exemption_granted", "Acceso de cortesía"],
  ["trial_pro_granted", "Prueba del plan Pro"],
  ["subscription_payment_approved", "Pago de suscripción acreditado"],
  ["subscription_ambiguous_resolved", "Suscripción asociada a la cuenta"],
  ["subscription_cancelled", "Suscripción cancelada"],
]

describe("BillingHistory — etiquetas de los tipos de evento", () => {
  it.each(LIVE_EVENT_TYPES)("%s se muestra como «%s», nunca como el string crudo", (type, label) => {
    render(<BillingHistory events={[event("e1", type, "inicial", "pro")]} />)

    expect(screen.getByText(label)).toBeInTheDocument()
    expect(screen.queryByText(type)).not.toBeInTheDocument()
  })

  it("la cortesía muestra el salto de plan efectivo en su fila", () => {
    render(<BillingHistory events={[event("e1", "exemption_granted", "inicial", "pro")]} />)

    const row = screen.getByText("Acceso de cortesía").closest("tr")
    expect(row).not.toBeNull()
    const cells = within(row as HTMLTableRowElement).getAllByRole("cell")
    expect(cells[2]).toHaveTextContent("Inicial")
    expect(cells[3]).toHaveTextContent("Pro")
  })

  it("las etiquetas que ya existían no cambian", () => {
    render(
      <BillingHistory
        events={[event("a", "plan_upgraded", "gratis", "inicial"), event("b", "trial_expired", "pro", "gratis")]}
      />,
    )

    expect(screen.getByText("Upgrade de plan")).toBeInTheDocument()
    expect(screen.getByText("Trial vencido")).toBeInTheDocument()
  })

  it("un tipo desconocido sigue cayendo al string de la base (no rompe la tabla)", () => {
    render(<BillingHistory events={[event("z", "tipo_futuro", null, null)]} />)

    expect(screen.getByText("tipo_futuro")).toBeInTheDocument()
  })
})
