/**
 * stock-ledger-solo-rpc (tanda B, task 12.3) — el importador CSV de ajustes de
 * /stock exige el MOTIVO y ya no acepta transferencias.
 *
 * Contrato (spec branch-stock «La superficie de ajuste manual…», escenarios «El CSV
 * sin motivo bloquea la fila» y «Un rechazo de rol del servidor se explica en
 * castellano»):
 *   - sin la columna «Motivo» el ARCHIVO se rechaza antes de la vista previa;
 *   - una fila con la celda vacía queda bloqueada («Falta el motivo») y no se aplica;
 *     las demás filas siguen siendo aplicables;
 *   - los alias de transferencia bloquean la fila y derivan a «Transferir stock»;
 *   - el paso 1 documenta «Motivo» como obligatorio y no lista transferencias;
 *   - el rechazo del servidor sale por el mapa canónico, en castellano.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { StockImportAdjustmentDialog } from "@/components/stock/stock-import-adjustment-dialog"

const { rpcMock, toastMock, PRODUCTS } = vi.hoisted(() => ({
  rpcMock: vi.fn(),
  toastMock: { success: vi.fn(), error: vi.fn(), warning: vi.fn() },
  PRODUCTS: [
    { id: "prod-harina", name: "Harina 000", category: "Otros", cost: 0, price: 0, margin: 0, stock: 10, minStock: 0, isVariant: false, stockControlType: "tracked" },
    { id: "prod-aceite", name: "Aceite 1L", category: "Otros", cost: 0, price: 0, margin: 0, stock: 4, minStock: 0, isVariant: false, stockControlType: "tracked" },
  ],
}))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc: rpcMock }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: PRODUCTS }) }))
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: vi.fn().mockResolvedValue(undefined) }),
}))
vi.mock("sonner", () => ({ toast: toastMock }))

const HEADER = "Nombre;Tipo;Cantidad;Motivo"

async function uploadCsv(content: string) {
  render(<StockImportAdjustmentDialog open onOpenChange={() => {}} />)
  const user = userEvent.setup()
  await user.upload(
    screen.getByLabelText(/Hacé clic o arrastrá tu archivo CSV/),
    new File([content], "ajustes.csv", { type: "text/csv" }),
  )
  return user
}

describe("StockImportAdjustmentDialog — paso 1 documenta el contrato nuevo", () => {
  beforeEach(() => {
    rpcMock.mockReset()
    Object.values(toastMock).forEach((m) => m.mockReset())
  })

  it("«Motivo» figura como obligatorio y no como opcional", () => {
    render(<StockImportAdjustmentDialog open onOpenChange={() => {}} />)
    const motivo = screen.getByText("Motivo", { selector: "span" })
    expect(motivo.parentElement?.textContent).toMatch(/obligatorio/i)
    expect(motivo.parentElement?.textContent).not.toMatch(/opcional/i)
  })

  it("la lista de tipos válidos no ofrece transferencias y manda a «Transferir stock»", () => {
    render(<StockImportAdjustmentDialog open onOpenChange={() => {}} />)
    expect(screen.queryByText(/Transferencia entrada/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Transferencia salida/i)).not.toBeInTheDocument()
    expect(screen.getByText(/Transferir stock/i)).toBeInTheDocument()
    expect(screen.getByText("Ajuste entrada")).toBeInTheDocument()
    expect(screen.getByText("Conteo físico")).toBeInTheDocument()
  })
})

describe("StockImportAdjustmentDialog — motivo obligatorio", () => {
  beforeEach(() => {
    rpcMock.mockReset()
    rpcMock.mockResolvedValue({ data: null, error: null })
    Object.values(toastMock).forEach((m) => m.mockReset())
  })

  it("un archivo sin la columna «Motivo» se rechaza como error de ARCHIVO: no hay vista previa ni llamadas", async () => {
    await uploadCsv("Nombre;Tipo;Cantidad\nHarina 000;Ajuste entrada;10")
    await waitFor(() => expect(toastMock.error).toHaveBeenCalled())
    expect(String(toastMock.error.mock.calls[0][0])).toMatch(/motivo/i)
    expect(screen.queryByRole("button", { name: /Aplicar/ })).not.toBeInTheDocument()
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it("la fila con la celda de motivo vacía queda bloqueada con «Falta el motivo» y NO se aplica", async () => {
    await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;`)
    expect(await screen.findByText("Falta el motivo")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Aplicar 0 ajustes/ })).toBeDisabled()
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it("sólo la fila sin motivo se omite: la que lo trae se aplica con el motivo recortado", async () => {
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;  Reposición  \nAceite 1L;Pérdida;2;`,
    )
    expect(await screen.findByText("Falta el motivo")).toBeInTheDocument()
    await user.click(screen.getByRole("button", { name: /Aplicar 1 ajuste/ }))
    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))
    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_stock_adjustment",
      expect.objectContaining({ p_product_id: "prod-harina", p_reason: "Reposición" }),
    )
  })

  it.each(["Transferencia entrada", "Transferencia salida"])(
    "«%s» bloquea la fila y deriva a «Transferir stock»: jamás llega a la RPC",
    async (alias) => {
      await uploadCsv(`${HEADER}\nHarina 000;${alias};4;Movimiento de depósito`)
      expect(await screen.findByText(/Transferir stock/i, { selector: "p" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /Aplicar 0 ajustes/ })).toBeDisabled()
      expect(rpcMock).not.toHaveBeenCalled()
    },
  )
})

describe("StockImportAdjustmentDialog — el rechazo del servidor llega en castellano", () => {
  beforeEach(() => {
    rpcMock.mockReset()
    Object.values(toastMock).forEach((m) => m.mockReset())
  })

  it("insufficient_role → «tu rol no permite ajustar el stock a mano», sin el token, en el detalle de errores", async () => {
    rpcMock.mockResolvedValue({
      data: null,
      error: { message: "insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)" },
    })
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición`)
    await user.click(await screen.findByRole("button", { name: /Aplicar 1 ajuste/ }))
    expect(await screen.findByText(/tu rol no permite ajustar el stock a mano/i)).toBeInTheDocument()
    expect(screen.queryByText(/insufficient_role/)).not.toBeInTheDocument()
  })
})
