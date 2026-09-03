/**
 * Accesibilidad — compras-proveedor-cuenta-corriente (task 14.4).
 *
 * RTL/testing-library sobre comportamiento real, no tautologías: labels
 * asociadas (getByLabelText), nombre accesible estable en el selector de
 * proveedor del form de compra (getByRole con name, no el texto visible que
 * cambia con la selección), la acción "Cuenta corriente" del listado como
 * elemento enfocable con nombre accesible, y el foco visible viniendo de las
 * clases compartidas del design system (Button/Input `focus-visible:ring-*`),
 * no de un outline custom. Mismo criterio que ClientesPage.test.tsx §7.6
 * ("the row is keyboard-focusable and activates with Enter").
 *
 * Dos gaps reales encontrados y corregidos acá (RED → GREEN):
 *  1. supplier-form.tsx: "Condición IVA" (Select de Radix) no tenía
 *     htmlFor/id — heredado sin querer del mismo gap en client-form.tsx.
 *  2. searchable-select.tsx: sin forma de fijar un nombre accesible, el
 *     trigger tomaba como nombre el label de la opción elegida — el
 *     selector de "Proveedor" del form de compra perdía su identidad de
 *     campo apenas el usuario elegía un proveedor.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SupplierForm } from "@/components/forms/supplier-form"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Purchase, Supplier } from "@/lib/types"

// ── Mocks compartidos (molde de supplier-form.test.tsx / ProveedoresPage.test.tsx /
//    purchase-form-supplier.test.tsx) ────────────────────────────────────────
const addSupplierMock = vi.fn().mockResolvedValue(undefined)
const updateSupplierMock = vi.fn().mockResolvedValue(undefined)
const deleteSupplierMock = vi.fn().mockResolvedValue(undefined)
const pushMock = vi.fn()

let suppliersMock: Supplier[] = []

// productos-categorias-sku: purchase-form monta ProductCategorySelect en el alta
// inline de producto → use-product-categories → python-client (explota sin
// NEXT_PUBLIC_BACKEND_URL) y useOrgRole → react-query real (mockeado acá).
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn(), createProductCategoryMutation: { isPending: false } }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    suppliers: suppliersMock,
    isLoading: false,
    error: null,
    addSupplier: addSupplierMock,
    updateSupplier: updateSupplierMock,
    deleteSupplier: deleteSupplierMock,
  }),
}))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: pushMock }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxSuppliers: 100 } }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

afterEach(() => {
  vi.clearAllMocks()
  suppliersMock = []
})

// ── 1. SupplierForm: todos los campos alcanzables por label ────────────────

describe("Accesibilidad — SupplierForm (task 14.4)", () => {
  it("los seis campos son alcanzables por getByLabelText, incluida Condición IVA", () => {
    render(<SupplierForm onSuccess={() => {}} />)

    expect(screen.getByLabelText(/^nombre$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^email$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^tel[ée]fono$/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/cuit \/ dni/i)).toBeInTheDocument()
    // RED antes del fix: el Select no tenía htmlFor/id, getByLabelText fallaba.
    expect(screen.getByLabelText(/condici[oó]n iva/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/raz[oó]n social/i)).toBeInTheDocument()
  })

  it("Condición IVA es también un combobox accesible por rol y nombre, no solo por texto suelto", () => {
    render(<SupplierForm onSuccess={() => {}} />)
    expect(screen.getByRole("combobox", { name: /condici[oó]n iva/i })).toBeInTheDocument()
  })

  it("el input Nombre usa el ring de foco compartido del design system (Input base), no un outline custom", () => {
    render(<SupplierForm onSuccess={() => {}} />)
    const nameInput = screen.getByLabelText(/^nombre$/i)
    expect(nameInput.className).toMatch(/focus-visible:ring-2/)
    expect(nameInput.className).toMatch(/focus-visible:ring-ring/)
  })
})

// ── 2. SearchableSelect: nombre accesible estable (unit, componente real) ──

describe("Accesibilidad — SearchableSelect con aria-label (D10, selector de proveedor)", () => {
  const options = [{ value: "sup-1", label: "Distribuidora Mendoza" }]

  it("sin selección: el nombre accesible es el aria-label del campo, no el placeholder solo", () => {
    render(
      <SearchableSelect
        options={options}
        value=""
        onValueChange={() => {}}
        placeholder="Seleccionar proveedor"
        aria-label="Proveedor"
      />,
    )
    expect(screen.getByRole("combobox", { name: /^proveedor$/i })).toBeInTheDocument()
  })

  it("con un valor elegido, el nombre accesible sigue siendo el del campo — no el nombre del proveedor seleccionado", () => {
    // RED antes del fix: sin aria-label, el nombre accesible del trigger es
    // su propio texto visible. Con un proveedor elegido, ese texto pasa a
    // ser "Distribuidora Mendoza" y "Proveedor" desaparece del nombre
    // accesible — justo el escenario que importa (formulario ya completado).
    render(
      <SearchableSelect
        options={options}
        value="sup-1"
        onValueChange={() => {}}
        placeholder="Seleccionar proveedor"
        aria-label="Proveedor"
      />,
    )
    expect(screen.getByRole("combobox", { name: /^proveedor$/i })).toBeInTheDocument()
    expect(screen.getByText("Distribuidora Mendoza")).toBeInTheDocument()
  })

  it("el trigger usa el ring de foco compartido de Button, no un outline custom", () => {
    render(<SearchableSelect options={options} value="" onValueChange={() => {}} aria-label="Proveedor" />)
    const trigger = screen.getByRole("combobox", { name: /proveedor/i })
    expect(trigger.className).toMatch(/focus-visible:ring-2/)
    expect(trigger.className).toMatch(/focus-visible:ring-ring/)
  })
})

// ── 3. El selector REAL de proveedor dentro de PurchaseForm (sin mockear
//    searchable-select — a diferencia de purchase-form-supplier.test.tsx,
//    que sí lo mockea para testear el flujo de datos). Verifica que
//    purchase-form.tsx efectivamente cablea aria-label="Proveedor". ────────

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: vi.fn(), updatePurchaseOperation: vi.fn() }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
// caja-compras-cobranzas: purchase-form.tsx ahora monta useCashOptin, que
// consulta useBranches/useCashboxes/useCurrentSession directo (no vía
// BranchSelect) — sin mockearlos, la cadena real llega a pythonClient y
// explota por falta de NEXT_PUBLIC_BACKEND_URL en el entorno de test.
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: null }) }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: () => <div data-testid="product-picker" />,
}))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({
    children,
    footerContent,
  }: {
    children: React.ReactNode
    footerContent?: React.ReactNode
  }) => (
    <>
      {children}
      {footerContent}
    </>
  ),
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: [], isLoading: false }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({ data: null }),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => <div data-testid="payment-method-select" />,
  BankAccountDestinationSelect: () => null,
}))

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "purchase-1", date: "2026-08-20", productId: "prod-1", productName: "Producto Test",
    quantity: 3, unitCost: 50, total: 150, operationId: "op-1",
    ...overrides,
  }
}

function makeOperation(overrides: Partial<PurchaseOperation> = {}): PurchaseOperation {
  return {
    key: "op-1", operationId: "op-1", date: "2026-08-20", items: [makePurchase()], total: 150,
    description: "", isGrouped: false, paymentMethodId: null, branchId: null, unitId: null,
    isPaymentLocked: false, hasAccountCharge: false, hasBankMovement: false,
    // caja-compras-cobranzas (D9): campos nuevos requeridos por PurchaseOperation.
    hasCashMovement: false, isDeleteBlocked: false,
    supplierId: null, supplierName: null, costCenterId: null,
    ...overrides,
  }
}

// review B (F7): purchase-form.tsx pasó de aria-label="Proveedor" (nombre
// FIJO, reemplaza el valor visible) a aria-labelledby apuntando al <Label
// id="purchase-supplier-label"> + el propio trigger (patrón "external label
// + self") — el nombre accesible ahora es la CONCATENACIÓN de "Proveedor"
// con el contenido visible del botón (placeholder o la opción elegida), así
// que dejó de ser un match exacto ('^proveedor$') para pasar a "contiene
// ambos" — exactamente lo que este describe verifica.
describe("Accesibilidad — selector de proveedor real dentro de PurchaseForm (D10)", () => {
  it("sin selección: el nombre accesible empieza con 'Proveedor' (label) seguido del placeholder", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(<PurchaseForm onSuccess={vi.fn()} />)
    expect(screen.getByRole("combobox", { name: /^proveedor\b/i })).toBeInTheDocument()
  })

  it("en edición, con un proveedor precargado, el nombre accesible incluye TANTO 'Proveedor' COMO el proveedor seleccionado", () => {
    // RED antes del fix: con aria-label a secas, elegir un proveedor no
    // cambiaba el nombre accesible (seguía siendo "Proveedor" a secas) — el
    // usuario de lector de pantalla no se enteraba de qué quedó
    // seleccionado. Con aria-labelledby (label + self), el nombre accesible
    // pasa a ser "Proveedor Distribuidora Mendoza".
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })}
      />,
    )
    expect(
      screen.getByRole("combobox", { name: /proveedor.*distribuidora mendoza/i }),
    ).toBeInTheDocument()
  })
})

// ── 4. /proveedores: la acción "Cuenta corriente" de cada fila ─────────────

describe("Accesibilidad — listado /proveedores, acción 'Cuenta corriente' (task 14.4)", () => {
  async function renderProveedoresPage() {
    const { default: ProveedoresPage } = await import("@/app/(dashboard)/proveedores/page")
    return render(<ProveedoresPage />)
  }

  it("cada fila expone la acción de cuenta corriente como botón enfocable con nombre accesible", async () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Mendoza" },
      { id: "sup-2", name: "Envases del Oeste" },
    ]
    await renderProveedoresPage()

    const accountButtons = screen.getAllByRole("button", { name: /cuenta corriente/i })
    // Mobile + desktop renderizan ambos bloques en jsdom (sin motor CSS real
    // las clases sm:hidden/hidden sm:grid no aplican) — mismo patrón
    // documentado en ClientesPage.test.tsx. 2 filas × 2 layouts = 4.
    expect(accountButtons.length).toBeGreaterThanOrEqual(2)
    for (const btn of accountButtons) {
      expect(btn.tagName).toBe("BUTTON")
      expect(btn).not.toBeDisabled()
      expect(btn).not.toHaveAttribute("tabindex", "-1")
    }
  })

  it("clickear la acción de cuenta corriente navega a /proveedores/[id]/cuenta", async () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    await renderProveedoresPage()

    const [btn] = screen.getAllByRole("button", { name: /cuenta corriente/i })
    fireEvent.click(btn)
    expect(pushMock).toHaveBeenCalledWith("/proveedores/sup-1/cuenta")
  })

  it("el botón de cuenta corriente usa el ring de foco compartido de Button, no un outline custom", async () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    await renderProveedoresPage()

    const [btn] = screen.getAllByRole("button", { name: /cuenta corriente/i })
    expect(btn.className).toMatch(/focus-visible:ring-2/)
    expect(btn.className).toMatch(/focus-visible:ring-ring/)
  })

  // review B (F6): los botones de fila Editar/Eliminar eran icon-only sin
  // aria-label — su único "nombre accesible" era el ícono SVG (aria-hidden),
  // así que un lector de pantalla los anunciaba sin ningún nombre.
  it("cada fila expone Editar y Eliminar como botones con nombre accesible que nombra al proveedor", async () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Mendoza" },
      { id: "sup-2", name: "Envases del Oeste" },
    ]
    await renderProveedoresPage()

    const editButtons = screen.getAllByRole("button", { name: /editar.*distribuidora mendoza/i })
    const deleteButtons = screen.getAllByRole("button", { name: /eliminar.*distribuidora mendoza/i })
    expect(editButtons.length).toBeGreaterThanOrEqual(1)
    expect(deleteButtons.length).toBeGreaterThanOrEqual(1)
    expect(
      screen.getAllByRole("button", { name: /editar.*envases del oeste/i }).length,
    ).toBeGreaterThanOrEqual(1)
  })
})
