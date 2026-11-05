import { describe, it, expect, vi } from "vitest"
import { useRef, useState } from "react"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { OperationEditPlanDialog } from "@/components/shared/OperationEditPlanDialog"
import { planNeedsConfirmation, type EditPreview, type MoneyPlan } from "@/lib/money-plan"
import { formatMoney } from "@/lib/format"

// edicion-operaciones-con-dinero (tanda C, 13.1): el diálogo muestra el plan que calculó el SERVIDOR, por libro y con el
// sentido real del dinero; con un bloqueo deshabilita la confirmación y deja el motivo visible; si el plan no cambia
// ningún libro no aparece; y el foco vuelve al control que lo abrió.

const EMPTY: MoneyPlan = {
  writes_money: false,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}

function preview(over: Partial<MoneyPlan> = {}, voided: EditPreview["voided_fiscal_document"] = null): EditPreview {
  return { dry_run: true, plan: { ...EMPTY, ...over }, voided_fiscal_document: voided }
}

// El texto del DOM llega normalizado (el espacio duro de Intl pasa a espacio común).
const moneyText = (n: number) => (content: string) => content.replace(/\s/g, " ").includes(formatMoney(n).replace(/\s/g, " "))

const SALE_CASH_UP: Partial<MoneyPlan> = {
  writes_money: true,
  cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "200.00", movement_type: "sale" }, reverse: [] },
}

const BLOCK_NO_SESSION = {
  book: "cash",
  code: "P0426",
  token: "no_open_session_for_reversal",
  message: "no_open_session_for_reversal: abrí la caja…",
}

function renderDialog(props: Partial<React.ComponentProps<typeof OperationEditPlanDialog>> = {}) {
  const onConfirm = vi.fn()
  const onOpenChange = vi.fn()
  render(
    <OperationEditPlanDialog
      open
      onOpenChange={onOpenChange}
      preview={preview(SALE_CASH_UP)}
      party="cliente"
      documentLabel="esta venta"
      onConfirm={onConfirm}
      {...props}
    />,
  )
  return { onConfirm, onOpenChange }
}

describe("OperationEditPlanDialog — el plan del servidor", () => {
  it("muestra el plan por libro con el sentido real: en una venta el efectivo ENTRA a la caja", () => {
    renderDialog()
    expect(screen.getByRole("alertdialog")).toBeInTheDocument()
    expect(screen.getByText(/entran/i)).toBeInTheDocument()
    expect(screen.getByText(moneyText(200))).toBeInTheDocument()
    expect(screen.getByText(/^Caja:/)).toBeInTheDocument()
  })

  it("en una compra el mismo registro es una SALIDA de la caja (el signo lo manda el servidor)", () => {
    renderDialog({
      party: "proveedor",
      documentLabel: "esta compra",
      preview: preview({
        writes_money: true,
        cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "-350.00", movement_type: "purchase_payment" }, reverse: [] },
      }),
    })
    expect(screen.getByText(/salen/i)).toBeInTheDocument()
    expect(screen.queryByText(/entran/i)).toBeNull()
  })

  it("lo que se muestra sale de la RESPUESTA del servidor: cambiar la respuesta cambia el texto", () => {
    const { rerender } = render(
      <OperationEditPlanDialog open onOpenChange={() => {}} preview={preview(SALE_CASH_UP)} party="cliente" documentLabel="esta venta" onConfirm={() => {}} />,
    )
    expect(screen.getByText(moneyText(200))).toBeInTheDocument()
    rerender(
      <OperationEditPlanDialog
        open
        onOpenChange={() => {}}
        preview={preview({ ...SALE_CASH_UP, cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "999.00" }, reverse: [] } })}
        party="cliente"
        documentLabel="esta venta"
        onConfirm={() => {}}
      />,
    )
    expect(screen.getByText(moneyText(999))).toBeInTheDocument()
  })

  it("confirmar llama onConfirm", () => {
    const { onConfirm } = renderDialog()
    fireEvent.click(screen.getByRole("button", { name: /confirmar y guardar/i }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("el comprobante pendiente que se anula encabeza la lista", () => {
    renderDialog({
      preview: preview(SALE_CASH_UP, { fiscal_document_id: "fd", punto_de_venta: 3, number: 5, label: "0003-00000005" }),
    })
    const items = screen.getAllByRole("listitem")
    expect(items[0].textContent).toContain("0003-00000005")
    expect(items[0].textContent).toMatch(/anulará el comprobante pendiente/i)
  })
})

describe("OperationEditPlanDialog — bloqueos", () => {
  it("con un bloqueo, la confirmación queda deshabilitada y el motivo visible", () => {
    const { onConfirm } = renderDialog({
      preview: preview({ ...SALE_CASH_UP, blocks: [BLOCK_NO_SESSION] }),
    })
    const confirm = screen.getByRole("button", { name: /confirmar y guardar/i })
    expect(confirm).toBeDisabled()
    expect(screen.getByRole("alert").textContent).toMatch(/abr[ií] la caja/i)
    fireEvent.click(confirm)
    expect(onConfirm).not.toHaveBeenCalled()
    // volver a editar sigue disponible
    expect(screen.getByRole("button", { name: /volver a editar/i })).toBeEnabled()
  })

  it("la confirmación deshabilitada apunta al motivo con aria-describedby (no queda un botón mudo)", () => {
    renderDialog({ preview: preview({ ...SALE_CASH_UP, blocks: [BLOCK_NO_SESSION] }) })
    const confirm = screen.getByRole("button", { name: /confirmar y guardar/i })
    const id = confirm.getAttribute("aria-describedby")
    expect(id).toBeTruthy()
    expect(document.getElementById(id as string)?.textContent).toMatch(/abr[ií] la caja/i)
  })

  it("varios bloqueos se listan todos", () => {
    renderDialog({
      preview: preview({
        ...SALE_CASH_UP,
        blocks: [
          BLOCK_NO_SESSION,
          { book: "bank", code: "P0424", token: "bank_period_reconciled", message: "bank_period_reconciled: la fecha cae" },
        ],
      }),
    })
    const alert = screen.getByRole("alert")
    expect(alert.textContent).toMatch(/abr[ií] la caja/i)
    expect(alert.textContent).toMatch(/per[ií]odo conciliado/i)
  })
})

describe("OperationEditPlanDialog — cuándo aparece y a dónde vuelve el foco", () => {
  it("no aparece si el plan no cambia ningún libro", () => {
    renderDialog({ preview: preview() })
    expect(screen.queryByRole("alertdialog")).toBeNull()
    expect(planNeedsConfirmation(preview())).toBe(false)
  })

  it("planNeedsConfirmation: efectos, bloqueos o un comprobante a anular piden confirmar", () => {
    expect(planNeedsConfirmation(preview(SALE_CASH_UP))).toBe(true)
    expect(planNeedsConfirmation(preview({ blocks: [BLOCK_NO_SESSION] }))).toBe(true)
    expect(planNeedsConfirmation(preview({}, { fiscal_document_id: "f", punto_de_venta: 1, number: 1, label: "0001-00000001" }))).toBe(true)
  })

  it("sin preview (todavía calculando) no muestra nada", () => {
    renderDialog({ preview: null })
    expect(screen.queryByRole("alertdialog")).toBeNull()
  })

  it("al cerrar, el foco vuelve al control que lo abrió", async () => {
    function Harness() {
      const [open, setOpen] = useState(false)
      const ref = useRef<HTMLButtonElement>(null)
      return (
        <>
          <button ref={ref} onClick={() => setOpen(true)}>Guardar cambios</button>
          <OperationEditPlanDialog
            open={open}
            onOpenChange={setOpen}
            preview={preview(SALE_CASH_UP)}
            party="cliente"
            documentLabel="esta venta"
            onConfirm={() => setOpen(false)}
            returnFocusRef={ref}
          />
        </>
      )
    }
    render(<Harness />)
    const opener = screen.getByRole("button", { name: "Guardar cambios" })
    opener.focus()
    fireEvent.click(opener)
    fireEvent.click(await screen.findByRole("button", { name: /volver a editar/i }))
    await waitFor(() => expect(opener).toHaveFocus())
  })

  it("mientras guarda, la confirmación está deshabilitada y lo dice", () => {
    renderDialog({ executing: true })
    const confirm = screen.getByRole("button", { name: /guardando/i })
    expect(confirm).toBeDisabled()
  })
})
