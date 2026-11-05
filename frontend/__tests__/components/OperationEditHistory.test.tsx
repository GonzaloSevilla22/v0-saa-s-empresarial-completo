import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"

const historyMock = vi.fn()
vi.mock("@/hooks/data/use-operation-edit", () => ({
  useOperationEditHistory: (...args: unknown[]) => historyMock(...args),
}))

import { OperationEditHistory } from "@/components/shared/OperationEditHistory"
import { formatMoney } from "@/lib/format"

// edicion-operaciones-con-dinero (tanda C, 14.1): el detalle expandido de una operación muestra su "Historial de cambios",
// con carga DIFERIDA (no consulta hasta que el usuario lo pide), fecha, quién y un resumen. Vacío sin ediciones.

function entry(over: Record<string, unknown> = {}) {
  return {
    id: "e1",
    created_at: "2026-11-03T15:30:00Z",
    user_id: "u1",
    user_name: "Laura Gómez",
    action: "sale_operation.edited",
    entity_type: "sale_operation",
    entity_id: "op1",
    before: { total: "1000.00", date: "2026-11-01" },
    after: { total: "1200.00", date: "2026-11-01" },
    money: {
      writes_money: true,
      blocks: [],
      account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
      cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "200.00", movement_type: "sale" }, reverse: [] },
      bank: { action: "none", register: null, reverse: [] },
    },
    voided_fiscal_document: null,
    reason: null,
    ...over,
  }
}

function state(over: Record<string, unknown> = {}) {
  return { data: undefined, isLoading: false, isError: false, refetch: vi.fn(), ...over }
}

beforeEach(() => {
  historyMock.mockReset()
  historyMock.mockReturnValue(state())
})

describe("OperationEditHistory — carga diferida", () => {
  it("no consulta nada hasta que el usuario abre el historial", () => {
    render(<OperationEditHistory kind="sale" entityId="op1" document="venta" />)
    expect(historyMock).not.toHaveBeenCalled()
    expect(screen.getByRole("button", { name: /historial de cambios/i })).toHaveAttribute("aria-expanded", "false")
  })

  it("al abrirlo pide el historial", () => {
    render(<OperationEditHistory kind="purchase" entityId="p1" document="compra" />)
    fireEvent.click(screen.getByRole("button", { name: /historial de cambios/i }))
    expect(historyMock).toHaveBeenLastCalledWith("purchase", "p1", true)
    expect(screen.getByRole("button", { name: /historial de cambios/i })).toHaveAttribute("aria-expanded", "true")
  })
})

describe("OperationEditHistory — contenido", () => {
  async function open(data: unknown[] | undefined, extra: Record<string, unknown> = {}) {
    historyMock.mockReturnValue(state({ data, ...extra }))
    render(<OperationEditHistory kind="sale" entityId="op1" document="venta" defaultOpen />)
  }

  it("lista fecha, quién y el resumen de cada edición", async () => {
    await open([entry()])
    const item = screen.getByRole("listitem")
    expect(item.textContent).toContain("Laura Gómez")
    expect(item.textContent).toContain("03/11/2026")
    expect(item.textContent).toContain(`Total ${formatMoney(1000)} → ${formatMoney(1200)}`)
    expect(item.textContent).toMatch(/entran/i)
  })

  it("muestra el motivo cuando el usuario lo escribió", async () => {
    await open([entry({ reason: "Cobré de más" })])
    expect(screen.getByRole("listitem").textContent).toContain("Cobré de más")
  })

  it("una edición sin usuario conocido no inventa un nombre", async () => {
    await open([entry({ user_name: null, user_id: null })])
    expect(screen.getByRole("listitem").textContent).toMatch(/usuario desconocido/i)
  })

  it("sin ediciones: lo dice, sin lista", async () => {
    await open([])
    expect(screen.getByText(/no tiene cambios registrados/i)).toBeInTheDocument()
    expect(screen.queryByRole("list")).toBeNull()
  })

  it("cargando: estado de carga anunciado", async () => {
    await open(undefined, { isLoading: true })
    expect(screen.getByRole("status")).toHaveTextContent(/cargando/i)
  })

  it("error: lo dice y ofrece reintentar", async () => {
    const refetch = vi.fn()
    await open(undefined, { isError: true, refetch })
    expect(screen.getByRole("alert")).toHaveTextContent(/no se pudo cargar/i)
    fireEvent.click(screen.getByRole("button", { name: /reintentar/i }))
    expect(refetch).toHaveBeenCalled()
  })

  it("el gasto resume 'Importe', no 'Total'", async () => {
    historyMock.mockReturnValue(state({ data: [entry({ action: "expense.edited", before: { amount: 500, date: "2026-10-30" }, after: { amount: 300, date: "2026-10-30" }, money: null })] }))
    render(<OperationEditHistory kind="expense" entityId="g1" document="gasto" defaultOpen />)
    expect(screen.getByRole("listitem").textContent).toContain(`Importe ${formatMoney(500)} → ${formatMoney(300)}`)
  })
})

describe("OperationEditHistory — accesibilidad", () => {
  it("el botón controla la región del historial y la región tiene nombre", async () => {
    historyMock.mockReturnValue(state({ data: [entry()] }))
    render(<OperationEditHistory kind="sale" entityId="op1" document="venta" defaultOpen />)
    const button = screen.getByRole("button", { name: /historial de cambios/i })
    const region = screen.getByRole("region", { name: /historial de cambios/i })
    expect(button.getAttribute("aria-controls")).toBe(region.id)
  })

  it("operable por teclado: Enter sobre el botón lo abre", async () => {
    render(<OperationEditHistory kind="sale" entityId="op1" document="venta" />)
    const button = screen.getByRole("button", { name: /historial de cambios/i })
    button.focus()
    fireEvent.keyDown(button, { key: "Enter" })
    fireEvent.click(button) // jsdom no sintetiza el click del Enter: se verifica que es un <button> nativo
    await waitFor(() => expect(button).toHaveAttribute("aria-expanded", "true"))
    expect(button.tagName).toBe("BUTTON")
  })
})
