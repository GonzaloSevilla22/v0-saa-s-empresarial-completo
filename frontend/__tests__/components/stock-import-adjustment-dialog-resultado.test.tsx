/**
 * stock-import-resultado-parcial — el resultado del importador de ajustes de
 * /stock cuenta, lista y comunica igual cuando la importación sale a medias.
 *
 * Hallazgo del humo local de `stock-ledger-solo-rpc` (2026-10-09, paso 2e): con un
 * CSV de dos filas —una válida y una sin motivo— el panel de resultado decía
 * «1 OK · 1 con error», pero «Detalle de errores» quedaba VACÍO (la fila bloqueada
 * por el parser se contaba como error sin listarse), el toast decía «1 ajuste
 * registrado correctamente» (calculaba el error distinto que el panel) y los
 * textos de la revisión salían con plurales rotos («1 filas»).
 *
 * Contrato:
 *   - una fila bloqueada por el parser (motivo faltante, tipo inválido, producto no
 *     encontrado…) es OMITIDA: no es un error de la RPC, no toca el stock y se lista
 *     en el detalle con su motivo;
 *   - «con error» es sólo un rechazo REAL de la RPC al aplicar, con su mensaje en
 *     castellano en «Detalle de errores»;
 *   - el panel y el toast usan el MISMO texto de resumen;
 *   - todo texto que depende de un conteo concuerda en singular y plural.
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
const ROLE_ERROR =
  "insufficient_role: tu rol no permite ajustar el stock a mano (requiere depósito, administrador o dueño)"

async function uploadCsv(content: string, onSuccess?: () => void) {
  render(<StockImportAdjustmentDialog open onOpenChange={() => {}} onSuccess={onSuccess} />)
  const user = userEvent.setup()
  await user.upload(
    screen.getByLabelText(/Hacé clic o arrastrá tu archivo CSV/),
    new File([content], "ajustes.csv", { type: "text/csv" }),
  )
  return user
}

/** Todo el texto que ve el usuario en el diálogo (vive en un portal bajo <body>). */
function visibleText(): string {
  return (document.body.textContent ?? "").replace(/\s+/g, " ")
}

/** El renglón del detalle que contiene `text` (no el título ni el badge). */
function detailRowOf(text: string | RegExp): string {
  return screen.getByText(text).closest("div")?.textContent ?? ""
}

beforeEach(() => {
  rpcMock.mockReset()
  rpcMock.mockResolvedValue({ data: null, error: null })
  Object.values(toastMock).forEach((m) => m.mockReset())
})

describe("revisión — los conteos concuerdan en singular y plural", () => {
  it("una sola fila: «1 fila» y «Aplicar 1 ajuste»", async () => {
    await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición`)
    expect(await screen.findByRole("button", { name: "Aplicar 1 ajuste" })).toBeEnabled()
    expect(visibleText()).toContain("1 fila · Archivo: ajustes.csv")
    expect(visibleText()).not.toContain("1 filas")
  })

  it("dos filas válidas: «2 filas» y «Aplicar 2 ajustes»", async () => {
    await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;1;Rotura`)
    expect(await screen.findByRole("button", { name: "Aplicar 2 ajustes" })).toBeEnabled()
    expect(visibleText()).toContain("2 filas · Archivo: ajustes.csv")
  })

  it("1 válida + 1 bloqueada: «1 fila con error — se omitirá» y «Se aplicará la fila válida»", async () => {
    await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;2;`)
    expect(await screen.findByRole("button", { name: "Aplicar 1 ajuste" })).toBeEnabled()
    expect(visibleText()).toContain("2 filas · Archivo: ajustes.csv")
    expect(visibleText()).toContain("1 fila con error — se omitirá al confirmar. Se aplicará la fila válida.")
    expect(visibleText()).not.toContain("1 filas")
  })

  it("2 válidas + 2 bloqueadas: «2 filas con error — se omitirán» y «Se aplicarán las 2 filas válidas»", async () => {
    await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;1;Rotura\nHarina 000;Pérdida;2;\nAceite 1L;Pérdida;3;`,
    )
    expect(await screen.findByRole("button", { name: "Aplicar 2 ajustes" })).toBeEnabled()
    expect(visibleText()).toContain("2 filas con error — se omitirán al confirmar. Se aplicarán las 2 filas válidas.")
  })
})

describe("resultado — la fila omitida por el parser se lista y no cuenta como error", () => {
  it("1 válida + 1 sin motivo: «1 aplicado · 1 omitida», la omitida listada con su motivo y el toast dice lo mismo", async () => {
    const onSuccess = vi.fn()
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;2;`,
      onSuccess,
    )
    await user.click(await screen.findByRole("button", { name: "Aplicar 1 ajuste" }))

    // Panel: el resumen distingue omitida de error de la RPC.
    expect(await screen.findByText("1 aplicado · 1 omitida")).toBeInTheDocument()
    expect(screen.queryByText(/con error/)).not.toBeInTheDocument()
    expect(screen.queryByText(/errores?$/)).not.toBeInTheDocument()
    expect(screen.getByText("Las filas omitidas no modificaron el stock.")).toBeInTheDocument()

    // Detalle: la fila omitida, con su número, su producto y SU motivo.
    const row = detailRowOf("Falta el motivo")
    expect(row).toContain("Fila 3")
    expect(row).toContain("Aceite 1L")

    // Sólo la válida llegó a la RPC.
    expect(rpcMock).toHaveBeenCalledTimes(1)

    // Toast: el mismo texto que el panel, nunca «registrado correctamente» a secas.
    expect(toastMock.success).not.toHaveBeenCalled()
    expect(toastMock.warning).toHaveBeenCalledTimes(1)
    expect(String(toastMock.warning.mock.calls[0][0])).toContain("1 aplicado · 1 omitida")

    // El stock sí cambió: el padre se entera igual que antes.
    expect(onSuccess).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("button", { name: /Importar otro archivo/ })).toBeInTheDocument()
  })

  it("plurales del resumen: «2 aplicados · 2 omitidas» y cada omitida con su propio motivo", async () => {
    const user = await uploadCsv(
      [
        HEADER,
        "Harina 000;Ajuste entrada;10;Reposición",
        "Aceite 1L;Pérdida;1;Rotura",
        "Harina 000;Pérdida;2;",
        "Producto fantasma;Pérdida;1;Rotura",
      ].join("\n"),
    )
    await user.click(await screen.findByRole("button", { name: "Aplicar 2 ajustes" }))

    expect(await screen.findByText("2 aplicados · 2 omitidas")).toBeInTheDocument()
    expect(detailRowOf("Falta el motivo")).toContain("Fila 4")
    expect(detailRowOf('Producto "Producto fantasma" no encontrado')).toContain("Fila 5")
    expect(String(toastMock.warning.mock.calls[0][0])).toContain("2 aplicados · 2 omitidas")
  })

  it("una fila omitida por DOS motivos los lista a los dos, uno bajo otro, en su renglón", async () => {
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nProducto fantasma;Pérdida;1;`)
    await user.click(await screen.findByRole("button", { name: "Aplicar 1 ajuste" }))

    expect(await screen.findByText("1 aplicado · 1 omitida")).toBeInTheDocument()
    const row = detailRowOf("Falta el motivo")
    expect(row).toContain("Fila 3")
    expect(row).toContain("Producto fantasma")
    expect(row).toContain('Producto "Producto fantasma" no encontrado')
  })

  it("todo aplicado, sin omitidas: «2 ajustes registrados correctamente» en panel y toast, sin detalle", async () => {
    const onSuccess = vi.fn()
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;1;Rotura`,
      onSuccess,
    )
    await user.click(await screen.findByRole("button", { name: "Aplicar 2 ajustes" }))

    expect(await screen.findByText("2 ajustes registrados correctamente")).toBeInTheDocument()
    expect(toastMock.success).toHaveBeenCalledWith("2 ajustes registrados correctamente")
    expect(toastMock.warning).not.toHaveBeenCalled()
    expect(screen.queryByText(/Detalle de errores/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Filas omitidas/i)).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Importar otro archivo/ })).not.toBeInTheDocument()
    expect(onSuccess).toHaveBeenCalledTimes(1)
  })

  it("un solo ajuste: «1 ajuste registrado correctamente» en singular", async () => {
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición`)
    await user.click(await screen.findByRole("button", { name: "Aplicar 1 ajuste" }))

    expect(await screen.findByText("1 ajuste registrado correctamente")).toBeInTheDocument()
    expect(toastMock.success).toHaveBeenCalledWith("1 ajuste registrado correctamente")
  })
})

describe("resultado — un rechazo REAL de la RPC sigue siendo «con error» y se lista", () => {
  it("1 de 2 rechazada por la RPC: «Detalle de errores» con el mensaje en castellano, sin hablar de omitidas", async () => {
    rpcMock
      .mockResolvedValueOnce({ data: null, error: null })
      .mockResolvedValueOnce({ data: null, error: { message: ROLE_ERROR } })
    const onSuccess = vi.fn()
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;1;Rotura`,
      onSuccess,
    )
    await user.click(await screen.findByRole("button", { name: "Aplicar 2 ajustes" }))

    // Guarda de regresión: lo que ya estaba bien sigue estándolo.
    expect(await screen.findByText(/Detalle de errores/i)).toBeInTheDocument()
    expect(screen.getByText(/tu rol no permite ajustar el stock a mano/i)).toBeInTheDocument()
    expect(screen.queryByText(/insufficient_role/)).not.toBeInTheDocument()
    expect(screen.getByText("Las filas con error no modificaron el stock.")).toBeInTheDocument()
    expect(onSuccess).not.toHaveBeenCalled()

    // Resumen y toast, mismo texto.
    expect(screen.getByText("1 aplicado · 1 con error")).toBeInTheDocument()
    expect(screen.queryByText(/omitida/i)).not.toBeInTheDocument()
    expect(String(toastMock.warning.mock.calls[0][0])).toContain("1 aplicado · 1 con error")
    expect(detailRowOf("Aceite 1L")).toContain("Fila 3")
  })

  it("todas rechazadas: «No se pudo aplicar ningún ajuste» y el detalle de cada una", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { message: ROLE_ERROR } })
    const user = await uploadCsv(`${HEADER}\nHarina 000;Ajuste entrada;10;Reposición`)
    await user.click(await screen.findByRole("button", { name: "Aplicar 1 ajuste" }))

    expect(await screen.findByText("No se pudo aplicar ningún ajuste")).toBeInTheDocument()
    expect(screen.getByText(/tu rol no permite ajustar el stock a mano/i)).toBeInTheDocument()
    expect(toastMock.warning).toHaveBeenCalledTimes(1)
  })

  it("mezcla de las tres: «1 aplicado · 1 con error · 1 omitida», cada fila en su sección", async () => {
    rpcMock
      .mockResolvedValueOnce({ data: null, error: null })
      .mockResolvedValueOnce({ data: null, error: { message: ROLE_ERROR } })
    const user = await uploadCsv(
      `${HEADER}\nHarina 000;Ajuste entrada;10;Reposición\nAceite 1L;Pérdida;1;Rotura\nHarina 000;Pérdida;2;`,
    )
    await user.click(await screen.findByRole("button", { name: "Aplicar 2 ajustes" }))

    expect(await screen.findByText("1 aplicado · 1 con error · 1 omitida")).toBeInTheDocument()
    expect(screen.getByText("Las filas omitidas o con error no modificaron el stock.")).toBeInTheDocument()
    expect(detailRowOf("Falta el motivo")).toContain("Fila 4")
    expect(detailRowOf(/tu rol no permite ajustar el stock a mano/i)).toContain("Fila 3")
    await waitFor(() => expect(toastMock.warning).toHaveBeenCalledTimes(1))
    expect(String(toastMock.warning.mock.calls[0][0])).toContain("1 aplicado · 1 con error · 1 omitida")
  })
})
