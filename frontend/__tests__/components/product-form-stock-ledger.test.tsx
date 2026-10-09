/**
 * stock-ledger-solo-rpc (tanda B, task 12.5) — `ProductForm` ya no edita el stock.
 *
 * Contrato (spec branch-stock «El formulario de producto no edita el stock», D9):
 *   - ALTA: «Stock inicial» sólo se ofrece a quien puede ajustar stock (CAN_STOCK) y
 *     sólo para productos con stock propio; sin el rol, una línea explica quién lo
 *     carga y el alta viaja con stock 0;
 *   - EDICIÓN: «Stock actual: N» en sólo lectura y, a quien puede ajustar, la acción
 *     «Ajustar stock» que abre el modal de ajuste existente con el producto
 *     preseleccionado; la edición NO manda `stock`;
 *   - un padre `variant_only` y un servicio no muestran stock en ninguna variante;
 *   - al cerrar el modal anidado el foco vuelve al botón que lo abrió.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { Product } from "@/lib/types"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()
const toastMock = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }))

type OrgState = { role: string | null; roles: string[]; rolesResolved: boolean; isWriter: boolean; isLoading: boolean }
const org = vi.hoisted(() => ({
  value: { role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false } as OrgState,
}))

vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => org.value }))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ rpc: vi.fn() }) }))
vi.mock("sonner", () => ({ toast: toastMock }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Categoría" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">—</option>
      <option value="cat-food">Alimentos</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")
const { PythonApiError } = await import("@/lib/api/python-api-error")

const EXISTING: Product = {
  id: "p1", name: "Tomate", category: "Alimentos", categoryId: "cat-food", cost: 500, price: 1000,
  margin: 50, stock: 10, minStock: 2, isVariant: false, stockControlType: "tracked",
}
const PARENT: Product = { ...EXISTING, id: "p-parent", name: "Remera", stock: 0, stockControlType: "variant_only" }
const SERVICE: Product = { ...EXISTING, id: "p-svc", name: "Flete", stock: 0, stockControlType: "untracked" }

function setRoles(roles: string[], resolved = true) {
  org.value = { role: "member", roles, rolesResolved: resolved, isWriter: true, isLoading: false }
}

function renderForm(props: Partial<React.ComponentProps<typeof ProductForm>> = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ProductForm onSuccess={vi.fn()} {...props} />
    </QueryClientProvider>,
  )
}

function fillNew() {
  fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Tomate" } })
  fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-food" } })
}

const stockInitialInput = () => screen.queryByLabelText(/stock inicial/i)
const adjustButton = () => screen.queryByRole("button", { name: /ajustar stock/i })

describe("ProductForm — alta: «Stock inicial» sólo con CAN_STOCK", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    setRoles(["owner"])
  })

  it.each([["owner"], ["admin"], ["stock"]])("el rol %s ve el campo y el alta viaja con el stock cargado", async (role) => {
    setRoles([role])
    renderForm()
    const input = stockInitialInput()
    expect(input).toBeInTheDocument()
    fillNew()
    fireEvent.change(input!, { target: { value: "7" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    expect((addProductMock.mock.calls[0][0] as Product).stock).toBe(7)
  })

  it.each([["seller"], ["cashier"], ["purchases"], ["accountant"], ["viewer"]])(
    "un miembro %s NO ve el campo, ve quién lo carga, y el alta viaja con stock 0",
    async (role) => {
      setRoles([role])
      renderForm()
      expect(stockInitialInput()).not.toBeInTheDocument()
      const note = screen.getByText(/el stock inicial lo carga/i)
      expect(note.textContent).toMatch(/dep[óo]sito/i)
      expect(note.textContent).toMatch(/administrador/i)
      expect(note.textContent).toMatch(/due[ñn]o/i)
      fillNew()
      fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
      await waitFor(() => expect(addProductMock).toHaveBeenCalled())
      expect((addProductMock.mock.calls[0][0] as Product).stock).toBe(0)
    },
  )

  it("con el conjunto de roles sin resolver el campo es visible (fail-open: la barrera real es la base)", () => {
    setRoles(["member"], false)
    renderForm()
    expect(stockInitialInput()).toBeInTheDocument()
  })

  it("un servicio (Servicio / Digital) no tiene stock: ni campo ni explicación", async () => {
    const user = userEvent.setup()
    renderForm()
    await user.click(screen.getAllByRole("combobox").find((el) => /inventario físico/i.test(el.textContent ?? ""))!)
    await user.click(await screen.findByRole("option", { name: /servicio/i }))
    expect(stockInitialInput()).not.toBeInTheDocument()
    expect(screen.queryByText(/el stock inicial lo carga/i)).not.toBeInTheDocument()
  })

  it("el stock mínimo sigue siendo editable por cualquier rol (no es un ajuste)", () => {
    setRoles(["seller"])
    renderForm()
    expect(screen.getByLabelText(/stock mínimo/i)).toBeInTheDocument()
  })
})

describe("ProductForm — el rechazo del backend por el stock llega en castellano", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setRoles(["owner"])
  })

  it("403 de require_account_role (rol sin CAN_STOCK que igual mandó stock) -> «tu rol no permite ajustar el stock a mano»", async () => {
    addProductMock.mockRejectedValue(new PythonApiError("Rol de cuenta insuficiente: se requiere admin o owner o stock", 403))
    renderForm()
    fillNew()
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalled())
    const msg = String(toastMock.error.mock.calls[0][0])
    expect(msg).toMatch(/tu rol no permite ajustar el stock a mano/i)
    expect(msg).not.toMatch(/Rol de cuenta insuficiente/)
  })

  it("422 stock_adjust_required (pestaña vieja que mandó stock en la edición) -> deriva a «Ajustar stock»", async () => {
    updateProductMock.mockRejectedValue(
      new PythonApiError("El stock se ajusta desde «Ajustar stock», con un motivo.", 422, { code: "stock_adjust_required", field: "stock" }),
    )
    renderForm({ initialData: EXISTING })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalled())
    expect(String(toastMock.error.mock.calls[0][0])).toMatch(/ajustar stock/i)
  })

  it("cualquier otro error del backend sigue mostrándose tal cual (p. ej. el 409 de SKU)", async () => {
    addProductMock.mockRejectedValue(new PythonApiError('El SKU "X" ya pertenece a otro producto de tu cuenta.', 409))
    renderForm()
    fillNew()
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(toastMock.error).toHaveBeenCalledWith('El SKU "X" ya pertenece a otro producto de tu cuenta.'))
  })
})

describe("ProductForm — edición: «Stock actual» de sólo lectura y «Ajustar stock»", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    updateProductMock.mockResolvedValue(undefined)
    setRoles(["owner"])
  })

  it("muestra «Stock actual: 10» sin ningún campo de stock editable", () => {
    renderForm({ initialData: EXISTING })
    expect(screen.getByText(/stock actual/i)).toBeInTheDocument()
    expect(screen.getByText("10", { exact: false, selector: "[data-testid='current-stock']" })).toBeInTheDocument()
    expect(stockInitialInput()).not.toBeInTheDocument()
    expect(screen.queryByLabelText(/stock actual/i)).not.toBeInTheDocument()
  })

  it.each([["owner"], ["admin"], ["stock"]])("el rol %s ve «Ajustar stock»", (role) => {
    setRoles([role])
    renderForm({ initialData: EXISTING })
    expect(adjustButton()).toBeInTheDocument()
  })

  it.each([["seller"], ["cashier"], ["viewer"]])(
    "un miembro %s ve el stock actual pero no «Ajustar stock»; la línea dice quién ajusta",
    (role) => {
      setRoles([role])
      renderForm({ initialData: EXISTING })
      expect(screen.getByText(/stock actual/i)).toBeInTheDocument()
      expect(adjustButton()).not.toBeInTheDocument()
      expect(screen.getByText(/lo ajusta/i)).toBeInTheDocument()
    },
  )

  it("«Ajustar stock» abre el modal de ajuste con el producto preseleccionado", async () => {
    const user = userEvent.setup()
    renderForm({ initialData: EXISTING })
    await user.click(adjustButton()!)
    const dialog = await screen.findByRole("dialog", { name: /ajuste de inventario/i })
    expect(dialog).toHaveTextContent("Tomate")
    expect(dialog).toHaveTextContent(/stock actual/i)
  })

  it("al cerrar el modal anidado el foco vuelve al botón «Ajustar stock» del formulario", async () => {
    const user = userEvent.setup()
    renderForm({ initialData: EXISTING })
    const trigger = adjustButton()!
    await user.click(trigger)
    await screen.findByRole("dialog", { name: /ajuste de inventario/i })
    await user.keyboard("{Escape}")
    await waitFor(() => expect(screen.queryByRole("dialog", { name: /ajuste de inventario/i })).not.toBeInTheDocument())
    await waitFor(() => expect(adjustButton()).toHaveFocus())
  })

  it("guardar un cambio de precio NO manda el stock (la edición nunca ajusta)", async () => {
    renderForm({ initialData: EXISTING })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const payload = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(payload).not.toHaveProperty("stock")
    expect(payload.id).toBe("p1")
  })

  it("un padre variant_only no muestra stock ni «Ajustar stock» (sus variantes se ajustan)", () => {
    renderForm({ initialData: PARENT })
    expect(screen.queryByText(/stock actual/i)).not.toBeInTheDocument()
    expect(adjustButton()).not.toBeInTheDocument()
    expect(stockInitialInput()).not.toBeInTheDocument()
  })

  it("un servicio no muestra stock ni «Ajustar stock»", () => {
    renderForm({ initialData: SERVICE })
    expect(screen.queryByText(/stock actual/i)).not.toBeInTheDocument()
    expect(adjustButton()).not.toBeInTheDocument()
  })
})
