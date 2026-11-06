/**
 * productos-padre-variantes (tasks 11.1/11.2) — ProductCatalog: «Modificar precios»
 * en lote y rango «desde $X» del padre.
 *
 *  - la acción vive junto a «Cambiar categoría» sobre la MISMA selección, y sólo
 *    aparece si la pantalla pasa `onBulkAdjustPrices` (dueño/administrador);
 *  - el diálogo pide dirección, modo y valor, y NO habilita confirmar hasta que
 *    hay una vista previa del servidor para esos mismos valores;
 *  - el resultado se informa por bloques: una falla parcial dice cuántos se aplicaron;
 *  - la fila del padre variant_only muestra «desde $X» (el menor precio de sus
 *    variantes), no su precio 0.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"
import type { ProductBulkPriceOutcome } from "@/hooks/data/use-products"
import { PythonApiError } from "@/lib/api/python-api-error"

const toastSuccess = vi.fn()
const toastWarning = vi.fn()
const toastInfo = vi.fn()
const toastError = vi.fn()

vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ unitsById: new Map() }) }))
vi.mock("@/lib/format", () => ({ formatMoney: (n: number) => `$${n}` }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
vi.mock("@/lib/excel", () => ({ exportToCSV: vi.fn() }))
vi.mock("sonner", () => ({
  toast: {
    success: (...a: unknown[]) => toastSuccess(...a),
    warning: (...a: unknown[]) => toastWarning(...a),
    info: (...a: unknown[]) => toastInfo(...a),
    error: (...a: unknown[]) => toastError(...a),
  },
}))
vi.mock("@/components/products/product-import-dialog", () => ({ ProductImportDialog: () => null }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: () => null,
}))

const { ProductCatalog } = await import("@/components/products/product-catalog")

const PARENT: Product = {
  id: "parent-1", name: "Zapatillas Nike", category: "Ropa", categoryId: "cat-ropa",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
}
const CHILD_A: Product = {
  id: "child-a", name: "Zapatillas Nike 41", category: "Ropa", categoryId: "cat-ropa",
  cost: 600, price: 1200, margin: 50, stock: 3, minStock: 1, isVariant: true, parentId: "parent-1", stockControlType: "tracked",
}
const CHILD_B: Product = { ...CHILD_A, id: "child-b", name: "Zapatillas Nike 42", price: 1500, cost: 700 }
const ACEITE: Product = {
  id: "aceite", name: "Aceite de oliva", category: "Alimentos", categoryId: "cat-otros",
  cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}
const EMPTY_PARENT: Product = {
  id: "parent-2", name: "Campera sin variantes", category: "Ropa", categoryId: "cat-ropa",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
}

function outcome(over: Partial<ProductBulkPriceOutcome["result"]> = {}, extra: Partial<ProductBulkPriceOutcome> = {}): ProductBulkPriceOutcome {
  return {
    result: {
      requested: 2, eligible: 3, changed: 2, unchanged: 1, skippedParents: 1, clamped: 1,
      sample: [
        { id: "aceite", name: "Aceite de oliva", priceBefore: 20, priceAfter: 22 },
        { id: "child-a", name: "Zapatillas Nike 41", priceBefore: 1200, priceAfter: 1320 },
      ],
      ...over,
    },
    failure: null,
    appliedIds: 2,
    totalIds: 2,
    ...extra,
  }
}

function renderCatalog(onBulkAdjustPrices?: (params: unknown) => Promise<ProductBulkPriceOutcome>) {
  render(
    <ProductCatalog
      products={[PARENT, CHILD_A, CHILD_B, ACEITE, EMPTY_PARENT]}
      onAdd={vi.fn()}
      onAddVariant={vi.fn()}
      onEdit={vi.fn()}
      onDelete={vi.fn()}
      isAtLimit={false}
      onBulkRecategorize={vi.fn().mockResolvedValue({ requested: 1, updated: 1 })}
      onBulkAdjustPrices={onBulkAdjustPrices as never}
    />,
  )
}

function desktopTable() {
  return screen.getByRole("table")
}

function selectAceite() {
  fireEvent.click(within(desktopTable()).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
}

describe("ProductCatalog — «Modificar precios» (barra de acciones en lote)", () => {
  beforeEach(() => vi.clearAllMocks())

  it("sin onBulkAdjustPrices (rol sin CAN_CONFIGURE) la acción no existe aunque haya selección", () => {
    renderCatalog(undefined)
    selectAceite()
    expect(screen.getByRole("button", { name: /cambiar categoría/i })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /modificar precios/i })).not.toBeInTheDocument()
  })

  it("con onBulkAdjustPrices la acción aparece junto a «Cambiar categoría», sólo con selección", () => {
    renderCatalog(vi.fn())
    expect(screen.queryByRole("button", { name: /modificar precios/i })).not.toBeInTheDocument()
    selectAceite()
    const bar = screen.getByRole("region", { name: /acciones en lote/i })
    expect(within(bar).getByRole("button", { name: /cambiar categoría/i })).toBeInTheDocument()
    expect(within(bar).getByRole("button", { name: /modificar precios/i })).toBeInTheDocument()
  })

  it("la confirmación está deshabilitada hasta tener la vista previa de ESTOS valores", async () => {
    const adjust = vi.fn().mockResolvedValue(outcome())
    renderCatalog(adjust)
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))

    const dialog = await screen.findByRole("dialog")
    const preview = within(dialog).getByRole("button", { name: /ver vista previa/i })
    const apply = within(dialog).getByRole("button", { name: /aplicar cambio/i })
    expect(preview).toBeDisabled() // sin valor
    expect(apply).toBeDisabled()

    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    expect(preview).toBeEnabled()
    expect(apply).toBeDisabled() // todavía sin vista previa
    expect(adjust).not.toHaveBeenCalled()

    await user.click(preview)
    await waitFor(() => expect(apply).toBeEnabled())
    expect(adjust).toHaveBeenCalledTimes(1)
    expect(adjust).toHaveBeenCalledWith({
      productIds: ["aceite"], mode: "percent", direction: "increase", value: 10, dryRun: true,
    })
  })

  it("la vista previa muestra cuántos cambian, quedan igual, padres omitidos, acotados a $0 y antes → después", async () => {
    renderCatalog(vi.fn().mockResolvedValue(outcome()))
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))

    expect(await within(dialog).findByText(/2 productos cambian/i)).toBeInTheDocument()
    expect(within(dialog).getByText(/1 queda igual/i)).toBeInTheDocument()
    expect(within(dialog).getByText(/1 producto con variantes omitido/i)).toBeInTheDocument()
    expect(within(dialog).getByText(/1 acotado a \$0/i)).toBeInTheDocument()
    const row = within(dialog).getByText("Aceite de oliva").closest("tr")!
    expect(within(row).getByText("$20")).toBeInTheDocument()
    expect(within(row).getByText("$22")).toBeInTheDocument()
    expect(within(dialog).getByText(/no es exacto/i)).toBeInTheDocument()
  })

  it("dirección y modo cambian el payload (bajar, importe fijo)", async () => {
    const adjust = vi.fn().mockResolvedValue(outcome())
    renderCatalog(adjust)
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")

    await user.click(within(dialog).getByRole("radio", { name: /bajar/i }))
    await user.click(within(dialog).getByRole("radio", { name: /importe/i }))
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "500" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))

    await waitFor(() => expect(adjust).toHaveBeenCalledWith({
      productIds: ["aceite"], mode: "amount", direction: "decrease", value: 500, dryRun: true,
    }))
  })

  it("cambiar un valor después de la vista previa la invalida: hay que verla de nuevo", async () => {
    renderCatalog(vi.fn().mockResolvedValue(outcome()))
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))
    const apply = within(dialog).getByRole("button", { name: /aplicar cambio/i })
    await waitFor(() => expect(apply).toBeEnabled())

    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "15" } })
    expect(apply).toBeDisabled()
    expect(within(dialog).queryByText(/2 productos cambian/i)).not.toBeInTheDocument()
  })

  it("confirmar aplica SIN dry-run, avisa el resultado, limpia la selección y cierra", async () => {
    const adjust = vi.fn()
      .mockResolvedValueOnce(outcome())
      .mockResolvedValueOnce(outcome({}, { failure: null }))
    renderCatalog(adjust)
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))
    await waitFor(() => expect(within(dialog).getByRole("button", { name: /aplicar cambio/i })).toBeEnabled())

    await user.click(within(dialog).getByRole("button", { name: /aplicar cambio/i }))

    await waitFor(() => expect(adjust).toHaveBeenCalledTimes(2))
    expect(adjust).toHaveBeenLastCalledWith({
      productIds: ["aceite"], mode: "percent", direction: "increase", value: 10, dryRun: false,
    })
    await waitFor(() => expect(toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/2/)))
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(screen.queryByText(/seleccionad/i)).not.toBeInTheDocument()
  })

  it("una falla parcial informa cuántos se aplicaron, muestra el motivo y deja el diálogo abierto", async () => {
    const partial = outcome(
      { changed: 480 },
      {
        failure: { index: 1, error: new PythonApiError("Rol de cuenta insuficiente", 403, { code: "insufficient_role" }) },
        appliedIds: 500,
        totalIds: 700,
      },
    )
    const adjust = vi.fn().mockResolvedValueOnce(outcome()).mockResolvedValueOnce(partial)
    renderCatalog(adjust)
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))
    await waitFor(() => expect(within(dialog).getByRole("button", { name: /aplicar cambio/i })).toBeEnabled())
    await user.click(within(dialog).getByRole("button", { name: /aplicar cambio/i }))

    const alert = await within(dialog).findByRole("alert")
    expect(alert).toHaveTextContent(/500 de 700/)
    expect(alert).toHaveTextContent(/administradores|dueño/i)
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: /aplicar cambio/i })).toBeDisabled()
    expect(toastSuccess).not.toHaveBeenCalled()
  })

  it("una vista previa rechazada por el servidor sale en castellano", async () => {
    const adjust = vi.fn().mockRejectedValue(new PythonApiError("fuera de rango", 422, { code: "bulk_price_out_of_range" }))
    renderCatalog(adjust)
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "5000" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))

    const alert = await within(dialog).findByRole("alert")
    expect(alert).toHaveTextContent(/rango/i)
    expect(alert).not.toHaveTextContent("bulk_price_out_of_range")
    expect(within(dialog).getByRole("button", { name: /aplicar cambio/i })).toBeDisabled()
  })

  it("sin cambios para aplicar (todo queda igual) no ofrece confirmar", async () => {
    renderCatalog(vi.fn().mockResolvedValue(outcome({ changed: 0, unchanged: 3, sample: [] })))
    selectAceite()
    const user = userEvent.setup()
    await user.click(screen.getByRole("button", { name: /modificar precios/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/^valor/i), { target: { value: "10" } })
    await user.click(within(dialog).getByRole("button", { name: /ver vista previa/i }))

    expect(await within(dialog).findByText(/ningún precio cambia/i)).toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: /aplicar cambio/i })).toBeDisabled()
  })
})

describe("ProductCatalog — rango «desde $X» del padre variant_only", () => {
  it("la fila del padre muestra el menor precio de sus variantes, no su precio 0", () => {
    renderCatalog(undefined)
    const row = within(desktopTable()).getByText("Zapatillas Nike").closest("tr")!
    expect(within(row).getByText("desde $1200")).toBeInTheDocument()
    expect(within(row).queryByText("$0")).not.toBeInTheDocument()
  })

  it("aunque todas las variantes valgan lo mismo, el padre sigue mostrando «desde»", () => {
    render(
      <ProductCatalog
        products={[PARENT, { ...CHILD_A, price: 900 }, { ...CHILD_B, price: 900 }]}
        onAdd={vi.fn()} onAddVariant={vi.fn()} onEdit={vi.fn()} onDelete={vi.fn()} isAtLimit={false}
      />,
    )
    const row = within(desktopTable()).getByText("Zapatillas Nike").closest("tr")!
    expect(within(row).getByText("desde $900")).toBeInTheDocument()
  })

  it("el rango sale de TODAS las variantes aunque la búsqueda deje sólo una a la vista", () => {
    renderCatalog(undefined)
    fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: "nike 42" } })
    const row = within(desktopTable()).getByText("Zapatillas Nike").closest("tr")!
    expect(within(row).getByText("desde $1200")).toBeInTheDocument()
  })

  it("un padre sin variantes dice que no tiene variantes en vez de mostrar $0", () => {
    renderCatalog(undefined)
    const row = within(desktopTable()).getByText("Campera sin variantes").closest("tr")!
    expect(within(row).getByText("Sin variantes")).toBeInTheDocument()
    expect(within(row).queryByText("$0")).not.toBeInTheDocument()
  })
})
