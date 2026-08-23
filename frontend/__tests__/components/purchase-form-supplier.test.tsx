import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { Purchase } from "@/lib/types"
import { formatMoney } from "@/lib/format"

// compras-proveedor-cuenta-corriente (D10/D6, task 12.1-12.6): espejo exacto
// de sale-form-payment-effects.test.tsx para el bloque cliente→proveedor —
//   1) selector buscable de proveedor + alta inline preselecciona el creado;
//   2) bloque de cuenta corriente (saldo actual/proyectado) cuando
//      resolvedKind === 'credit', aviso "elegí un proveedor" si falta;
//   3) el botón de confirmar se deshabilita con kind=credit sin proveedor
//      (la UI impide llegar al P0400, el servidor sigue siendo quien decide).

const addPurchaseOperationMock = vi.fn().mockResolvedValue(undefined)
const updatePurchaseOperationMock = vi.fn().mockResolvedValue(undefined)
const addSupplierMock = vi.fn()

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let supplierAccountMock: { balance: number } | null = null
let suppliersMock: Array<{ id: string; name: string }> = []

const PRODUCT = { id: "prod-1", name: "Insumo Test", cost: 10, baseUnitId: "" }
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [PRODUCT], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({ addPurchaseOperation: addPurchaseOperationMock, updatePurchaseOperation: updatePurchaseOperationMock }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => <div data-testid="branch-select" /> }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({
    products,
    onValueChange,
  }: {
    products: Array<{ id: string; name: string }>
    onValueChange: (v: string) => void
  }) => (
    <div data-testid="product-picker">
      {products.map((p) => (
        <button key={p.id} type="button" data-testid={`product-option-${p.id}`} onClick={() => onValueChange(p.id)}>
          {p.name}
        </button>
      ))}
    </div>
  ),
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
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({ data: supplierAccountMock }),
}))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({ suppliers: suppliersMock, addSupplier: addSupplierMock }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

// review B (F8): el mock ahora expone `data-value` — antes solo se podía
// verificar el prefill/reimputación de supplierId indirectamente vía el
// payload de submit; con `data-value` se verifica el prop `value` que
// purchase-form.tsx le pasa al selector directamente (prefill Y alta inline).
vi.mock("@/components/ui/searchable-select", () => ({
  SearchableSelect: ({
    options,
    value,
    onValueChange,
  }: {
    options: Array<{ value: string; label: string }>
    value: string
    onValueChange: (v: string) => void
  }) => (
    <div data-testid="searchable-select" data-value={value}>
      {options.map((o) => (
        <button key={o.value} type="button" data-testid={`supplier-option-${o.value}`} onClick={() => onValueChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  ),
}))

vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <div data-testid="payment-method-select">
      {paymentMethodsMock.map((pm) => (
        <button key={pm.id} type="button" data-testid={`pm-option-${pm.id}`} onClick={() => onChange(pm.id)}>
          {pm.name}
        </button>
      ))}
      <span data-testid="pm-selected-value">{value ?? "null"}</span>
    </div>
  ),
  BankAccountDestinationSelect: () => null,
}))

function selectPaymentMethod(id: string) {
  fireEvent.click(screen.getByTestId(`pm-option-${id}`))
}

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
    supplierId: null, supplierName: null, costCenterId: null,
    ...overrides,
  }
}

const PM_CREDIT = { id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true }
const PM_CASH   = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }

afterEach(() => {
  vi.clearAllMocks()
  paymentMethodsMock = []
  supplierAccountMock = null
  suppliersMock = []
})

describe("PurchaseForm — selector de proveedor (D10)", () => {
  it("el alta envía supplierId en el payload (task 12.1)", async () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await vi.waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = addPurchaseOperationMock.mock.calls[0][0]
    expect(call.meta.supplierId).toBe("sup-1")
  })

  it("sin elegir proveedor, el alta manda supplierId=null (task 12.1, TRIANGULATE)", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    fireEvent.click(screen.getByRole("button", { name: /confirmar compra/i }))

    await vi.waitFor(() => expect(addPurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = addPurchaseOperationMock.mock.calls[0][0]
    expect(call.meta.supplierId).toBeNull()
  })
})

describe("PurchaseForm — alta inline 'Nuevo proveedor' (task 12.3)", () => {
  it("crea el proveedor vía useSuppliers().addSupplier y lo preselecciona", async () => {
    suppliersMock = []
    addSupplierMock.mockResolvedValueOnce({ id: "sup-new", account_id: "acc-1", name: "Nuevo Proveedor", created_at: "2026-08-20T00:00:00Z" })
    render(<PurchaseForm onSuccess={vi.fn()} />)

    fireEvent.click(screen.getByRole("button", { name: /nuevo proveedor/i }))
    const input = screen.getByPlaceholderText(/nombre del proveedor/i)
    fireEvent.change(input, { target: { value: "Nuevo Proveedor" } })
    fireEvent.click(screen.getByRole("button", { name: /crear y seleccionar/i }))

    await vi.waitFor(() => expect(addSupplierMock).toHaveBeenCalledTimes(1))
    expect(addSupplierMock).toHaveBeenCalledWith(expect.objectContaining({ name: "Nuevo Proveedor" }))
    // review B (F8): el alta inline vuelve a mostrar el selector (se cierra
    // el formulario inline) con el proveedor recién creado YA seleccionado.
    await vi.waitFor(() =>
      expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-value", "sup-new"),
    )
  })
})

describe("PurchaseForm — bloque de cuenta corriente (D6/task 12.4-12.6)", () => {
  it("kind=credit sin proveedor: advierte y NO muestra saldo", () => {
    paymentMethodsMock = [PM_CREDIT]
    render(<PurchaseForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByText(/eleg[íi] un proveedor/i)).toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual/i)).not.toBeInTheDocument()
  })

  it("kind=credit con proveedor: muestra saldo actual y proyectado", () => {
    // review B (F8): antes solo se afirmaba "Saldo actual" está en el
    // documento — un texto sin cambiar el mock de useSupplierAccount habría
    // dejado pasar el bug igual. Se agrega un ítem al carrito para poder
    // distinguir el monto actual del proyectado con valores formateados
    // reales, no solo la etiqueta.
    paymentMethodsMock = [PM_CREDIT]
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    supplierAccountMock = { balance: 300 }
    render(<PurchaseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    selectPaymentMethod(PM_CREDIT.id)

    // "Saldo actual: $ 300" es un único nodo de texto dentro del <span> (el
    // literal JSX y la interpolación no quedan en elementos separados), así
    // que se afirma el monto formateado como SUBSTRING del textContent del
    // span encontrado por getByText — no como nodo propio.
    expect(screen.getByText(/Saldo actual/i).textContent).toContain(formatMoney(300))
    expect(screen.getByText(/Después de esta compra/i).textContent).toContain(formatMoney(310))
  })

  it("kind=cash: no muestra ningún bloque de cuenta corriente", () => {
    paymentMethodsMock = [PM_CASH]
    render(<PurchaseForm onSuccess={vi.fn()} />)
    selectPaymentMethod(PM_CASH.id)

    expect(screen.queryByText(/eleg[íi] un proveedor/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual/i)).not.toBeInTheDocument()
  })

  it("sin forma de pago: no muestra ni promete cuenta corriente", () => {
    render(<PurchaseForm onSuccess={vi.fn()} />)
    expect(screen.queryByText(/eleg[íi] un proveedor/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Saldo actual/i)).not.toBeInTheDocument()
  })

  it("task 12.5: kind=credit sin proveedor deshabilita el botón de confirmar aunque haya ítems en el carrito", () => {
    paymentMethodsMock = [PM_CREDIT]
    render(<PurchaseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByRole("button", { name: /confirmar compra/i })).toBeDisabled()
  })

  it("task 12.5: kind=credit CON proveedor y carrito no vacío habilita el botón", () => {
    paymentMethodsMock = [PM_CREDIT]
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(<PurchaseForm onSuccess={vi.fn()} />)
    fireEvent.click(screen.getByTestId("product-option-prod-1"))
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    fireEvent.click(screen.getByTestId("supplier-option-sup-1"))
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByRole("button", { name: /confirmar compra/i })).not.toBeDisabled()
  })
})

describe("PurchaseForm — edición: supplierId precargado (D7)", () => {
  it("prefillea supplierId desde editingOperation en el selector", () => {
    // review B (F8): antes solo se verificaba que el mock estuviera montado
    // — con `data-value` (F8) se afirma el prop `value` real que
    // purchase-form.tsx le pasa al selector.
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })} />)

    expect(screen.getByTestId("searchable-select")).toHaveAttribute("data-value", "sup-1")
  })

  // review B (F2): el hallazgo real — antes supplierId SIEMPRE viajaba en
  // el payload de edición, tocado o no. Estos cuatro tests reemplazan al
  // único test anterior ("el payload de edición incluye supplierId
  // vigente"), cuya premisa (sin tocar el selector, igual se manda) era
  // justamente el bug.

  it("sin tocar el selector, supplierId NO viaja en el payload (preserva el vigente)", async () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })} />)

    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))

    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = updatePurchaseOperationMock.mock.calls[0][0]
    expect("supplierId" in call.meta).toBe(false)
  })

  it("tocando el selector, el payload de edición incluye el supplierId elegido", async () => {
    suppliersMock = [
      { id: "sup-1", name: "Distribuidora Mendoza" },
      { id: "sup-2", name: "Envases del Oeste" },
    ]
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })} />)

    fireEvent.click(screen.getByTestId("supplier-option-sup-2"))
    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))

    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = updatePurchaseOperationMock.mock.calls[0][0]
    expect(call.meta.supplierId).toBe("sup-2")
  })

  it("F2: proveedor dado de baja (no está en la lista) — editar cantidad sin tocar el selector NO manda supplierId, evita un 404", async () => {
    // El proveedor prefillado ("sup-deleted") ya no existe en `suppliers`
    // (soft-deleted, RN-B1 lo saca de la lista) — el selector cae al
    // placeholder, pero el usuario nunca lo tocó: el payload de edición NO
    // debe reimputar ni desimputar nada, solo preservar lo que ya hay en DB.
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ supplierId: "sup-deleted", supplierName: "Proveedor de baja" })}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))

    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
    const call = updatePurchaseOperationMock.mock.calls[0][0]
    expect("supplierId" in call.meta).toBe(false)
  })

  it("F2: proveedor dado de baja muestra el hint 'no disponible' en vez de quedar en blanco sin explicación", () => {
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ supplierId: "sup-deleted", supplierName: "Proveedor de baja" })}
      />,
    )

    expect(screen.getByText(/proveedor actual no disponible/i)).toBeInTheDocument()
  })
})

// review B (F3 + regla batch A): la edición NUNCA postea ni revierte cargos
// de cuenta corriente (D7) — el bloque visual y el guard de habilitación
// tienen que reflejar eso, distinto del alta.
describe("PurchaseForm — edición: bloque de crédito (F3)", () => {
  it("kind=credit sin proveedor deshabilita 'Guardar cambios' igual que en el alta", () => {
    paymentMethodsMock = [PM_CASH, PM_CREDIT]
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id })}
      />,
    )
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByRole("button", { name: /Guardar cambios/i })).toBeDisabled()
  })

  it("la operación YA era crédito (con proveedor, sin tocar la forma de pago): NO muestra el aviso de transición, solo el saldo actual", () => {
    paymentMethodsMock = [PM_CREDIT]
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    supplierAccountMock = { balance: 500 }
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({
          paymentMethodId: PM_CREDIT.id,
          supplierId: "sup-1",
          supplierName: "Distribuidora Mendoza",
        })}
      />,
    )

    expect(screen.getByText(/Saldo actual/i)).toBeInTheDocument()
    expect(screen.queryByText(/no postea cargos/i)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Guardar cambios/i })).not.toBeDisabled()
  })

  it("la edición NUNCA muestra 'Después de esta compra' (nunca postea cargos), a diferencia del alta", () => {
    paymentMethodsMock = [PM_CREDIT]
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    supplierAccountMock = { balance: 500 }
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({
          paymentMethodId: PM_CREDIT.id,
          supplierId: "sup-1",
          supplierName: "Distribuidora Mendoza",
        })}
      />,
    )

    expect(screen.queryByText(/Después de esta compra/i)).not.toBeInTheDocument()
  })

  it("transicionando de cash a credit CON proveedor: avisa el camino de corrección pero no bloquea el submit", async () => {
    paymentMethodsMock = [PM_CASH, PM_CREDIT]
    suppliersMock = [{ id: "sup-1", name: "Distribuidora Mendoza" }]
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, supplierId: "sup-1", supplierName: "Distribuidora Mendoza" })}
      />,
    )
    selectPaymentMethod(PM_CREDIT.id)

    expect(screen.getByText(/no postea cargos/i)).toBeInTheDocument()
    const submitButton = screen.getByRole("button", { name: /Guardar cambios/i })
    expect(submitButton).not.toBeDisabled()

    fireEvent.click(submitButton)
    await vi.waitFor(() => expect(updatePurchaseOperationMock).toHaveBeenCalledTimes(1))
  })
})
