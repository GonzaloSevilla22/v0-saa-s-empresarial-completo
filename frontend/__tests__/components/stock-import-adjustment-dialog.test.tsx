/**
 * StockImportAdjustmentDialog — cableado del parser extraído a
 * `lib/stock-import-parser` y coma decimal de punta a punta.
 *
 * `__tests__/stock-import-parser.test.ts` cubre el parseo en sí. Este test fija
 * la costura: el diálogo sigue montando con el módulo nuevo, documenta en el
 * paso 1 que la cantidad acepta coma o punto, la vista previa muestra la
 * cantidad YA INTERPRETADA (con el texto original al lado si difiere) y una
 * cantidad "1,5" cargada por el input de archivo real llega a
 * `rpc_stock_adjustment` como 1.5. Antes llegaba 1 mientras la vista previa
 * mostraba "1,5" — truncado en silencio.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { StockImportAdjustmentDialog } from "@/components/stock/stock-import-adjustment-dialog"

const { rpcMock, PRODUCT } = vi.hoisted(() => ({
  rpcMock: vi.fn(),
  PRODUCT: {
    id: "prod-harina",
    name: "Harina 000",
    category: "Otros",
    cost: 0,
    price: 0,
    margin: 0,
    stock: 10,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
  },
}))

vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc: rpcMock }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT] }) }))
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: vi.fn().mockResolvedValue(undefined) }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), warning: vi.fn() } }))

const HEADER = "Nombre;Tipo;Cantidad;Motivo"

function csvFile(content: string): File {
  return new File([content], "ajustes.csv", { type: "text/csv" })
}

function renderDialog() {
  return render(<StockImportAdjustmentDialog open onOpenChange={() => {}} />)
}

async function uploadCsv(content: string) {
  const user = userEvent.setup()
  const input = screen.getByLabelText(/Hacé clic o arrastrá tu archivo CSV/)
  await user.upload(input, csvFile(content))
  return user
}

describe("StockImportAdjustmentDialog", () => {
  beforeEach(() => {
    rpcMock.mockReset()
    rpcMock.mockResolvedValue({ data: null, error: null })
  })

  it("monta el paso 1 con el parser extraído y documenta que la cantidad acepta coma o punto", () => {
    renderDialog()
    expect(screen.getByText("Importar ajuste de stock")).toBeInTheDocument()
    expect(screen.getByText(/decimales con coma o punto/)).toBeInTheDocument()
  })

  it('una cantidad "1,5" cargada por archivo llega a rpc_stock_adjustment como 1.5 (antes: 1)', async () => {
    renderDialog()
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;1,5;Reposición`)

    // Paso 2: la vista previa muestra la cantidad interpretada; como coincide
    // con el texto del CSV no hace falta mostrar el original al lado.
    expect(await screen.findByText("1,5")).toBeInTheDocument()
    expect(screen.queryByText(/CSV:/)).not.toBeInTheDocument()
    expect(screen.queryByText("Cantidad inválida")).not.toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: /Aplicar 1 ajuste/ }))

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))
    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_stock_adjustment",
      expect.objectContaining({
        p_product_id: "prod-harina",
        p_type: "adjustment",
        p_quantity_delta: 1.5,
        p_reason: "Reposición",
      }),
    )
  })

  it('la vista previa muestra "1,250" interpretado como 1,25 junto al texto original, y viaja 1.25', async () => {
    renderDialog()
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;1,250;Fraccionado`)

    expect(await screen.findByText("1,25")).toBeInTheDocument()
    expect(screen.getByText(/CSV:\s*“1,250”/)).toBeInTheDocument()

    await user.click(screen.getByRole("button", { name: /Aplicar 1 ajuste/ }))

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(1))
    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_stock_adjustment",
      expect.objectContaining({ p_quantity_delta: 1.25 }),
    )
  })

  it('un conteo físico "12,25" viaja como p_target_quantity 12.25 y una pérdida "0,5" como delta -0.5', async () => {
    renderDialog()
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Conteo físico;12,25;Inventario\nHarina 000;Pérdida;0,5;Rotura`,
    )

    await user.click(await screen.findByRole("button", { name: /Aplicar 2 ajustes/ }))

    await waitFor(() => expect(rpcMock).toHaveBeenCalledTimes(2))
    expect(rpcMock).toHaveBeenNthCalledWith(
      1,
      "rpc_stock_adjustment",
      expect.objectContaining({ p_type: "physical_count", p_target_quantity: 12.25 }),
    )
    expect(rpcMock).toHaveBeenNthCalledWith(
      2,
      "rpc_stock_adjustment",
      expect.objectContaining({ p_type: "loss", p_quantity_delta: -0.5 }),
    )
  })

  it("una cantidad no numérica bloquea la fila, muestra el texto original y no se llama a la RPC", async () => {
    renderDialog()
    await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;abc;Reposición`)

    expect(await screen.findByText("Cantidad inválida")).toBeInTheDocument()
    expect(screen.getByText("abc")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Aplicar 0 ajustes/ })).toBeDisabled()
    expect(rpcMock).not.toHaveBeenCalled()
  })

  it('un CSV separado por coma con "1,5" sin comillas se rechaza en vez de aplicar 1', async () => {
    renderDialog()
    await uploadCsv("Nombre,Tipo,Cantidad,Motivo\nHarina 000,Ajuste entrada,1,5,Reposición")

    expect(await screen.findByText(/más columnas/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Aplicar 0 ajustes/ })).toBeDisabled()
    expect(rpcMock).not.toHaveBeenCalled()
  })
})
