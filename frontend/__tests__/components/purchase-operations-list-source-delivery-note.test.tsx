/**
 * remitos-compra (tanda B, 7.7, D9/D11) — `/compras`:
 *  - la compra nacida de un remito muestra "Desde remito RC-00000007" con enlace
 *    a él, en el listado (móvil y escritorio);
 *  - "Editar" queda deshabilitado con el motivo y el número del remito (el
 *    servidor responde P0423 `delivery_note_purchase_locked`); ese motivo gana al
 *    de cargo posteado porque es el PRIMER guard de la RPC de edición;
 *  - el diálogo de borrado cambia la línea de reversa de stock por la de D9 (el
 *    stock no vuelve y el remito queda pendiente); la compra directa conserva la
 *    suya;
 *  - "Eliminar" queda deshabilitado con su motivo si el usuario no puede anular el
 *    remito (`CAN_VOID_DELIVERY_NOTE`: borrar la compra lo reabre) o si la
 *    sucursal del remito está desactivada o cerrada (mismo predicado que el
 *    servidor, derivado en la lectura).
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, within, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1",
    date: "2026-10-15",
    productId: "p1",
    productName: "Insumo Test",
    quantity: 1,
    unitCost: 50,
    total: 50,
    operationId: "op1",
    ...overrides,
  }
}

const FROM_REMITO: Partial<Purchase> = {
  sourceDeliveryNoteId: "dn-7",
  sourceDeliveryNoteNumber: 7,
  sourceDeliveryNoteBranchActive: true,
  editLockedReason: "delivery_note_purchase_locked",
}

function baseProps(purchases: Purchase[], extra: Record<string, unknown> = {}) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(),
    dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    ...extra,
  }
}

function pencilButtons(): HTMLElement[] {
  return screen.getAllByRole("button").filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
}

const LOCK_REASON = /la compra nació del remito RC-00000007/i

describe("PurchaseOperationsList — badge 'Desde remito'", () => {
  it("una compra nacida de un remito muestra 'Desde remito RC-00000007' con enlace a él", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    const links = screen.getAllByRole("link", { name: "Desde remito RC-00000007" })
    expect(links.length).toBeGreaterThan(0)
    for (const link of links) expect(link).toHaveAttribute("href", "/remitos/dn-7")
  })

  it("el badge no lleva el prefijo R de venta: el remito de compra se rotula con RC", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    expect(screen.queryByRole("link", { name: "Desde remito R-00000007" })).not.toBeInTheDocument()
  })

  it("una compra directa no muestra ningún badge de origen", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase()])} />)
    expect(screen.queryByText(/desde remito/i)).not.toBeInTheDocument()
  })

  it("un remito anterior a la numeración enlaza igual y no inventa un número", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ ...FROM_REMITO, sourceDeliveryNoteNumber: null })])}
      />,
    )
    expect(screen.getAllByRole("link", { name: "Desde remito" }).length).toBeGreaterThan(0)
  })

  it("el enlace del badge no expande ni colapsa la fila", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    const row = screen.getAllByRole("button").find((b) => b.tagName === "DIV" && b.hasAttribute("aria-expanded"))!
    expect(row).toHaveAttribute("aria-expanded", "false")
    screen.getAllByRole("link", { name: /desde remito/i })[0].click()
    expect(row).toHaveAttribute("aria-expanded", "false")
  })

  it("en escritorio el badge va fuera de la celda que trunca el nombre del producto", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    const desktop = document.querySelector('[class*="sm:grid"][class*="items-center"]') as HTMLElement
    const badge = within(desktop).getByRole("link", { name: /desde remito rc-00000007/i })
    const nameCell = within(desktop).getByText(/Insumo Test/).closest(".truncate") as HTMLElement
    expect(nameCell.contains(badge)).toBe(false)
  })
})

describe("PurchaseOperationsList — 'Editar' en una compra nacida de un remito (D9)", () => {
  it("queda deshabilitado con el motivo, el número del remito y la salida", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    const locked = screen.getAllByTitle(LOCK_REASON)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) {
      expect(b).toBeDisabled()
      expect(b.getAttribute("title")).toMatch(/para corregirla, eliminá la compra, editá el remito y volvé a convertirlo/i)
    }
    expect(pencilButtons()).toHaveLength(0)
  })

  it("el motivo también es el nombre accesible del botón deshabilitado", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    expect(screen.getAllByRole("button", { name: LOCK_REASON }).length).toBeGreaterThan(0)
  })

  it("PRIORIDAD: gana al bloqueo de pago, porque el servidor lo evalúa primero", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ ...FROM_REMITO, isPaymentLocked: true })])} />)
    expect(screen.getAllByTitle(LOCK_REASON).length).toBeGreaterThan(0)
    expect(screen.queryAllByTitle(/cargo de cuenta corriente del proveedor/i)).toHaveLength(0)
  })

  it("el motivo viene del servidor: sin `editLockedReason` el lápiz sigue habilitado aunque haya un origen remito", () => {
    render(
      <PurchaseOperationsList {...baseProps([makePurchase({ sourceDeliveryNoteId: "dn-7", sourceDeliveryNoteNumber: 7 })])} />,
    )
    expect(pencilButtons().length).toBeGreaterThan(0)
  })

  it("un token de motivo desconocido también bloquea (fail-closed), con un texto genérico", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ editLockedReason: "otro_motivo_futuro" })])} />)
    expect(pencilButtons()).toHaveLength(0)
    expect(screen.getAllByRole("button", { name: /no editable/i }).length).toBeGreaterThan(0)
  })

  it("una compra directa se sigue pudiendo editar", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase()])} />)
    expect(pencilButtons().length).toBeGreaterThan(0)
  })
})

describe("PurchaseOperationsList — borrar una compra nacida de un remito (D9)", () => {
  it("el diálogo avisa que el stock no vuelve y que el remito queda pendiente, SIN la línea de reversa de stock", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])

    expect(
      screen.getByText(/el stock no vuelve: la mercadería quedó recibida con el remito RC-00000007, que vuelve a quedar pendiente/i),
    ).toBeInTheDocument()
    expect(screen.getByText(/para sacarla del stock, anulá el remito/i)).toBeInTheDocument()
    expect(screen.queryByText(/se revertirá el ingreso de stock/i)).not.toBeInTheDocument()
  })

  it("una compra directa conserva la línea de reversa de stock y no habla de remitos", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase()])} />)
    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])

    expect(screen.getByText(/se revertirá el ingreso de stock de esta compra/i)).toBeInTheDocument()
    expect(screen.queryByText(/el stock no vuelve/i)).not.toBeInTheDocument()
  })

  it("con origen de remito y dinero posteado enumera igual las compensaciones de los libros", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ ...FROM_REMITO, hasAccountCharge: true, isPaymentLocked: true })])}
      />,
    )
    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    expect(screen.getByText(/se revertirá el cargo registrado en la cuenta corriente del proveedor/i)).toBeInTheDocument()
    expect(screen.getByText(/el stock no vuelve/i)).toBeInTheDocument()
  })
})

describe("PurchaseOperationsList — 'Eliminar' bloqueado en la compra de un remito (D9)", () => {
  function deleteTriggers(): HTMLElement[] {
    return screen.queryAllByTestId("delete-operation-trigger")
  }

  it("sin el rol para anular el remito: deshabilitado, con el motivo (administrador o dueño)", () => {
    render(
      <PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)], { canVoidDeliveryNote: false })} />,
    )
    expect(deleteTriggers()).toHaveLength(0)
    const blocked = screen.getAllByTitle(/borrar esta compra reabre el remito RC-00000007: requiere administrador o dueño/i)
    expect(blocked.length).toBeGreaterThan(0)
    for (const b of blocked) expect(b).toBeDisabled()
  })

  it("con el rol, el borrado está disponible", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)], { canVoidDeliveryNote: true })} />)
    expect(deleteTriggers().length).toBeGreaterThan(0)
  })

  it("por defecto (sin la prop) el listado no bloquea por rol: el servidor sigue siendo la autoridad", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase(FROM_REMITO)])} />)
    expect(deleteTriggers().length).toBeGreaterThan(0)
  })

  it("con la sucursal del remito desactivada o cerrada: deshabilitado, con su motivo", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ ...FROM_REMITO, sourceDeliveryNoteBranchActive: false })])}
      />,
    )
    expect(deleteTriggers()).toHaveLength(0)
    const blocked = screen.getAllByTitle(/la sucursal del remito está desactivada o cerrada — reactivala antes de eliminar la compra/i)
    expect(blocked.length).toBeGreaterThan(0)
    for (const b of blocked) expect(b).toBeDisabled()
  })

  it("el rol se evalúa ANTES que la sucursal (mismo orden que el servidor)", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ ...FROM_REMITO, sourceDeliveryNoteBranchActive: false })], { canVoidDeliveryNote: false })}
      />,
    )
    expect(screen.getAllByTitle(/requiere administrador o dueño/i).length).toBeGreaterThan(0)
    expect(screen.queryAllByTitle(/sucursal del remito está desactivada/i)).toHaveLength(0)
  })

  it("una compra directa nunca se bloquea por esto, ni sin el rol ni con sucursal NULL", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ sourceDeliveryNoteBranchActive: null })], { canVoidDeliveryNote: false })}
      />,
    )
    expect(deleteTriggers().length).toBeGreaterThan(0)
  })
})
