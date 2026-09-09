/**
 * productos-categorias-sku — ProductCategoryManager (task 10.5 RED → 10.6 GREEN).
 *
 * Molde de PaymentMethodManager: lectura para todo miembro, acciones sólo
 * para isWriter — crear, renombrar, reordenar (subir/bajar = intercambio de
 * sort_order con el vecino), desactivar, reactivar y eliminar (soft).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { ProductCategory } from "@/lib/types"

const createMock = vi.fn().mockResolvedValue(undefined)
const updateMock = vi.fn().mockResolvedValue(undefined)
const deactivateMock = vi.fn().mockResolvedValue(undefined)
const deleteMock = vi.fn().mockResolvedValue(undefined)
const setDefaultMock = vi.fn().mockResolvedValue(undefined)
let categoriesMock: ProductCategory[] = []
let isWriterMock = true
let defaultCategoryIdMock: string | null = null

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({
    productCategories: categoriesMock,
    isLoading: false,
    isError: false,
    error: null,
    createProductCategory: createMock,
    updateProductCategory: updateMock,
    deactivateProductCategory: deactivateMock,
    deleteProductCategory: deleteMock,
    createProductCategoryMutation: { isPending: false },
    updateProductCategoryMutation: { isPending: false },
    deactivateProductCategoryMutation: { isPending: false },
    deleteProductCategoryMutation: { isPending: false },
  }),
  useDefaultProductCategory: () => ({
    defaultCategoryId: defaultCategoryIdMock,
    isLoading: false,
    setDefaultProductCategory: setDefaultMock,
    setDefaultProductCategoryMutation: { isPending: false },
  }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: isWriterMock, role: isWriterMock ? "owner" : "member", isLoading: false }) }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

const { ProductCategoryManager } = await import("@/components/product-categories/ProductCategoryManager")

function cat(id: string, name: string, sortOrder: number, isActive = true): ProductCategory {
  return { id, accountId: "acc-1", name, isActive, sortOrder, createdAt: "2026-09-03T00:00:00Z" }
}

describe("ProductCategoryManager", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    isWriterMock = true
    defaultCategoryIdMock = null
    categoriesMock = [cat("ropa", "Ropa", 2), cat("elec", "Electrónica", 1), cat("salud", "Salud", 5, false)]
  })

  it("member: lee el catálogo ordenado por sort_order, sin acciones", () => {
    isWriterMock = false
    render(<ProductCategoryManager />)

    const items = screen.getAllByRole("listitem").map((li) => li.textContent)
    expect(items[0]).toContain("Electrónica")
    expect(items[1]).toContain("Ropa")
    expect(items[2]).toContain("Salud")
    expect(items[2]).toContain("Inactiva")
    expect(screen.queryByRole("button", { name: /nueva/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /editar/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /desactivar/i })).not.toBeInTheDocument()
  })

  it("writer: crea desde el diálogo", async () => {
    render(<ProductCategoryManager />)

    fireEvent.click(screen.getByRole("button", { name: /nueva/i }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.change(within(dialog).getByLabelText(/nombre/i), { target: { value: " Ferretería " } })
    fireEvent.click(within(dialog).getByRole("button", { name: /crear/i }))

    await waitFor(() => expect(createMock).toHaveBeenCalledWith({ name: "Ferretería" }))
  })

  it("writer: renombra desde el diálogo de edición", async () => {
    render(<ProductCategoryManager />)

    const ropa = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Ropa"))!
    fireEvent.click(within(ropa).getByRole("button", { name: /editar/i }))
    const dialog = await screen.findByRole("dialog")
    const input = within(dialog).getByLabelText(/nombre/i) as HTMLInputElement
    expect(input.value).toBe("Ropa")
    fireEvent.change(input, { target: { value: "Indumentaria" } })
    fireEvent.click(within(dialog).getByRole("button", { name: /guardar/i }))

    await waitFor(() => expect(updateMock).toHaveBeenCalledWith({ id: "ropa", name: "Indumentaria" }))
  })

  it("writer: bajar intercambia el sort_order con el vecino (dos PATCH)", async () => {
    render(<ProductCategoryManager />)

    const elec = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Electrónica"))!
    fireEvent.click(within(elec).getByRole("button", { name: /bajar/i }))

    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(2))
    expect(updateMock).toHaveBeenCalledWith({ id: "elec", sortOrder: 2 })
    expect(updateMock).toHaveBeenCalledWith({ id: "ropa", sortOrder: 1 })
  })

  it("writer: desactivar una activa, reactivar y eliminar una inactiva", async () => {
    render(<ProductCategoryManager />)

    const ropa = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Ropa"))!
    fireEvent.click(within(ropa).getByRole("button", { name: /desactivar/i }))
    await waitFor(() => expect(deactivateMock).toHaveBeenCalledWith("ropa"))

    const salud = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Salud"))!
    expect(within(salud).queryByRole("button", { name: /desactivar/i })).not.toBeInTheDocument()
    fireEvent.click(within(salud).getByRole("button", { name: /reactivar/i }))
    await waitFor(() => expect(updateMock).toHaveBeenCalledWith({ id: "salud", isActive: true }))

    fireEvent.click(within(salud).getByRole("button", { name: /eliminar/i }))
    const confirm = await screen.findByRole("alertdialog")
    fireEvent.click(within(confirm).getByRole("button", { name: /^eliminar$/i }))
    await waitFor(() => expect(deleteMock).toHaveBeenCalledWith("salud"))
  })

  it("los objetivos táctiles de las acciones son de 44px en móvil (h-11 w-11)", () => {
    render(<ProductCategoryManager />)
    const ropa = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Ropa"))!
    const edit = within(ropa).getByRole("button", { name: /editar/i })
    expect(edit.className).toMatch(/h-11/)
    expect(edit.className).toMatch(/w-11/)
  })

  // ── categoria-default-configurable ─────────────────────────────────────────

  it("marca con el badge 'Por defecto' la categoría configurada como default", () => {
    defaultCategoryIdMock = "ropa"
    render(<ProductCategoryManager />)

    const ropa = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Ropa"))!
    const elec = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Electrónica"))!
    expect(within(ropa).getByText("Por defecto")).toBeInTheDocument()
    expect(within(elec).queryByText("Por defecto")).not.toBeInTheDocument()
  })

  it("writer: usa una categoría activa como default", async () => {
    render(<ProductCategoryManager />)

    const elec = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Electrónica"))!
    fireEvent.click(within(elec).getByRole("button", { name: /usar electrónica como categoría por defecto/i }))

    await waitFor(() => expect(setDefaultMock).toHaveBeenCalledWith("elec"))
  })

  it("writer: quita el default de la categoría que lo tenía", async () => {
    defaultCategoryIdMock = "ropa"
    render(<ProductCategoryManager />)

    const ropa = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Ropa"))!
    fireEvent.click(within(ropa).getByRole("button", { name: /quitar ropa como categoría por defecto/i }))

    await waitFor(() => expect(setDefaultMock).toHaveBeenCalledWith(null))
  })

  it("member: no ve ninguna acción de categoría por defecto", () => {
    isWriterMock = false
    defaultCategoryIdMock = "ropa"
    render(<ProductCategoryManager />)

    expect(screen.queryByRole("button", { name: /por defecto/i })).not.toBeInTheDocument()
  })

  it("una categoría desactivada no ofrece la acción de fijar default", () => {
    render(<ProductCategoryManager />)

    const salud = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Salud"))!
    expect(within(salud).queryByRole("button", { name: /por defecto/i })).not.toBeInTheDocument()
  })

  it("una categoría desactivada que sigue siendo el default ofrece 'Quitar por defecto' (sin 'Usar por defecto')", async () => {
    defaultCategoryIdMock = "salud"
    render(<ProductCategoryManager />)

    const salud = screen.getAllByRole("listitem").find((li) => li.textContent?.includes("Salud"))!
    expect(within(salud).queryByRole("button", { name: /usar salud como categoría por defecto/i })).not.toBeInTheDocument()
    const clearBtn = within(salud).getByRole("button", { name: /quitar salud como categoría por defecto/i })

    fireEvent.click(clearBtn)
    await waitFor(() => expect(setDefaultMock).toHaveBeenCalledWith(null))
  })
})
