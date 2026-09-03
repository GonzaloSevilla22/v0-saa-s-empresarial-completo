/**
 * productos-categorias-sku — ProductCategorySelect (task 10.3 RED → 10.4 GREEN).
 *
 *  - ofrece SÓLO las activas, ordenadas por sort_order;
 *  - una categoría inactiva que ya es el valor seleccionado sigue siendo
 *    visible como "(inactiva)" (edición de un producto imputado a ella);
 *  - "+ Nueva categoría" al pie de la lista intercambia el Select por un
 *    Input EN EL LUGAR (D9, sin diálogo anidado), crea y deja seleccionada;
 *  - cuenta sin categorías activas: advierte y ofrece crear, sin bloquear;
 *  - un member (no escritor) no ve el alta inline.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { ProductCategory } from "@/lib/types"

const createMock = vi.fn()
let categoriesMock: ProductCategory[] = []
let isWriterMock = true

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({
    productCategories: categoriesMock,
    isLoading: false,
    isError: false,
    error: null,
    createProductCategory: createMock,
    createProductCategoryMutation: { isPending: false },
  }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: isWriterMock, role: isWriterMock ? "owner" : "member", isLoading: false }) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

const { ProductCategorySelect } = await import("@/components/product-categories/ProductCategorySelect")

function cat(id: string, name: string, sortOrder: number, isActive = true): ProductCategory {
  return { id, accountId: "acc-1", name, isActive, sortOrder, createdAt: "2026-09-03T00:00:00Z" }
}

describe("ProductCategorySelect", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    isWriterMock = true
    categoriesMock = [cat("otros", "Otros", 7), cat("ropa", "Ropa", 2), cat("salud", "Salud", 5, false)]
  })

  it("ofrece sólo las activas ordenadas por sort_order y el alta inline al pie", async () => {
    const user = userEvent.setup()
    render(<ProductCategorySelect value={null} onChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: /categoría/i }))

    const options = await screen.findAllByRole("option")
    const labels = options.map((o) => o.textContent?.trim())
    expect(labels).toEqual(["Ropa", "Otros", "+ Nueva categoría"])
    expect(labels).not.toContain("Salud")
  })

  it("una categoría inactiva ya seleccionada sigue visible como (inactiva)", () => {
    render(<ProductCategorySelect value="salud" onChange={vi.fn()} />)

    expect(screen.getByRole("combobox", { name: /categoría/i })).toHaveTextContent(/Salud/)
    expect(screen.getByRole("combobox", { name: /categoría/i })).toHaveTextContent(/inactiva/i)
  })

  it("el alta inline intercambia el select por un input, crea y deja seleccionada", async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    createMock.mockResolvedValue(cat("ferre", "Ferretería", 8))
    render(<ProductCategorySelect value={null} onChange={onChange} />)

    await user.click(screen.getByRole("combobox", { name: /categoría/i }))
    await user.click(await screen.findByRole("option", { name: /nueva categoría/i }))

    // D9: NO se abre un diálogo — el input reemplaza al select en la misma fila
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    const input = screen.getByRole("textbox", { name: /nueva categoría/i })
    expect(screen.queryByRole("combobox", { name: /categoría/i })).not.toBeInTheDocument()

    fireEvent.change(input, { target: { value: "  Ferretería " } })
    await user.click(screen.getByRole("button", { name: /crear categoría/i }))

    await waitFor(() => expect(createMock).toHaveBeenCalledWith({ name: "Ferretería" }))
    await waitFor(() => expect(onChange).toHaveBeenCalledWith("ferre"))
    // vuelve al select
    expect(await screen.findByRole("combobox", { name: /categoría/i })).toBeInTheDocument()
  })

  it("cancelar el alta inline vuelve al select sin crear", async () => {
    const user = userEvent.setup()
    render(<ProductCategorySelect value="ropa" onChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: /categoría/i }))
    await user.click(await screen.findByRole("option", { name: /nueva categoría/i }))
    await user.click(screen.getByRole("button", { name: /cancelar/i }))

    expect(createMock).not.toHaveBeenCalled()
    expect(screen.getByRole("combobox", { name: /categoría/i })).toHaveTextContent("Ropa")
  })

  it("cuenta sin categorías activas: advierte y ofrece crear en el lugar, sin bloquear", () => {
    categoriesMock = [cat("salud", "Salud", 5, false)]
    render(<ProductCategorySelect value={null} onChange={vi.fn()} />)

    expect(screen.getByText(/no tenés categorías activas/i)).toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: /nueva categoría/i })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /configuración/i })).toHaveAttribute("href", "/configuracion?tab=categorias")
  })

  it("un member no ve el alta inline", async () => {
    const user = userEvent.setup()
    isWriterMock = false
    render(<ProductCategorySelect value={null} onChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: /categoría/i }))

    const labels = (await screen.findAllByRole("option")).map((o) => o.textContent?.trim())
    expect(labels).toEqual(["Ropa", "Otros"])
  })
})
