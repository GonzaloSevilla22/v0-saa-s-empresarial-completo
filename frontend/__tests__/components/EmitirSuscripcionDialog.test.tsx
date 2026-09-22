/**
 * EmitirSuscripcionDialog — fiscal-emision-segura (G5/H3, task 5.5).
 *
 * Hasta este change el diálogo EXIGÍA identificar al receptor con CUIT o DNI:
 * `canConfirm` pedía `isDocValid && docTipo !== null`, así que no había forma de
 * emitir la Factura C de una suscripción a consumidor final. El bloqueo era sólo
 * de esta pantalla y del schema Pydantic — la RPC ya aceptaba
 * `p_receptor_doc_tipo DEFAULT 99` con `NULLIF(..., 99)` y el adapter ya resuelve
 * un receptor sin identificar como DocTipo=99 / DocNro=0.
 *
 * Los tres casos que cubren el modo nuevo sin romper el viejo:
 *   1. modo "Consumidor final": el CTA se habilita SIN tocar el input y
 *      onConfirm recibe los dos campos en null;
 *   2. modo "Identificado": el comportamiento previo no cambia (CUIT módulo-11);
 *   3. al cambiar de modo se limpia lo tipeado — sin esto, un CUIT inválido
 *      escrito antes podía volver al confirmar.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

import { EmitirSuscripcionDialog, type SubscriptionReceipt } from "@/components/fiscal/EmitirSuscripcionDialog"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { EmitSubscriptionPaymentInput } from "@/hooks/data/use-emit-subscription-payment"

type ConfirmFn = (payload: EmitSubscriptionPaymentInput) => void

const RECEIPT: SubscriptionReceipt = {
  id: "rcpt-1",
  receipt_number: "RC-2026-000002",
  payment_id: "mp-1",
  plan: "inicial",
  amount: 12000,
  customer_email: "cliente@test.local",
  customer_name: "Cliente de Prueba",
}

const PVS: PointOfSale[] = [
  {
    id: "pv-3",
    fiscalProfileId: "fp-1",
    accountId: "acc-1",
    branchId: null,
    numero: 3,
    isActive: true,
    createdAt: "2026-06-24T00:00:00Z",
  },
]

let onConfirm: Mock<ConfirmFn>

function renderDialog() {
  return render(
    <EmitirSuscripcionDialog
      open
      onOpenChange={() => {}}
      receipt={RECEIPT}
      pointsOfSale={PVS}
      onConfirm={onConfirm}
      isSubmitting={false}
    />,
  )
}

const confirmButton = () =>
  screen.getByRole("button", { name: /Confirmar y enviar al ARCA/i })

beforeEach(() => {
  onConfirm = vi.fn<ConfirmFn>()
})

describe("EmitirSuscripcionDialog — receptor opcional (G5/H3)", () => {
  it("por defecto arranca en modo identificado y el CTA está deshabilitado", () => {
    renderDialog()

    expect(screen.getByRole("radio", { name: /Identificado con CUIT o DNI/i })).toBeChecked()
    expect(confirmButton()).toBeDisabled()
    expect(screen.getByLabelText(/CUIT o DNI del receptor/i)).toBeInTheDocument()
  })

  it("en modo Consumidor final habilita el CTA sin tocar el input y manda los dos campos en null", async () => {
    const user = userEvent.setup()
    renderDialog()

    await user.click(screen.getByRole("radio", { name: /Consumidor final/i }))

    // El input de documento deja de existir (se oculta, no se desactiva).
    expect(screen.queryByLabelText(/CUIT o DNI del receptor/i)).not.toBeInTheDocument()
    expect(confirmButton()).toBeEnabled()

    await user.click(confirmButton())

    expect(onConfirm).toHaveBeenCalledTimes(1)
    expect(onConfirm).toHaveBeenCalledWith({
      receipt_id: "rcpt-1",
      receptor_doc_tipo: null,
      receptor_doc_nro: null,
      point_of_sale_id: "pv-3",
    })
  })

  it("en modo Identificado el comportamiento previo no cambia (CUIT módulo-11)", async () => {
    const user = userEvent.setup()
    renderDialog()

    const input = screen.getByLabelText(/CUIT o DNI del receptor/i)

    // CUIT con dígito verificador inválido → CTA sigue deshabilitado
    await user.type(input, "20-42266245-0")
    expect(confirmButton()).toBeDisabled()
    expect(screen.getByText(/CUIT inválido/i)).toBeInTheDocument()

    await user.clear(input)
    await user.type(input, "20-42266245-7")
    expect(confirmButton()).toBeEnabled()

    await user.click(confirmButton())

    expect(onConfirm).toHaveBeenCalledWith({
      receipt_id: "rcpt-1",
      receptor_doc_tipo: 80,
      receptor_doc_nro: "20422662457",
      point_of_sale_id: "pv-3",
    })
  })

  it("al cambiar de modo limpia el valor y el error del input", async () => {
    const user = userEvent.setup()
    renderDialog()

    await user.type(screen.getByLabelText(/CUIT o DNI del receptor/i), "20-42266245-0")
    expect(screen.getByText(/CUIT inválido/i)).toBeInTheDocument()

    await user.click(screen.getByRole("radio", { name: /Consumidor final/i }))
    await user.click(screen.getByRole("radio", { name: /Identificado con CUIT o DNI/i }))

    expect(screen.getByLabelText(/CUIT o DNI del receptor/i)).toHaveValue("")
    expect(screen.queryByText(/CUIT inválido/i)).not.toBeInTheDocument()
    expect(confirmButton()).toBeDisabled()
  })
})
