"use client"

import { useState, useMemo, useCallback, useEffect, useRef } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { useProducts } from "@/hooks/data/use-products"
import { useClients } from "@/hooks/data/use-clients"
import { useCollectionSettings } from "@/hooks/data/use-collection-settings"
import { useSales } from "@/hooks/data/use-sales"
import { useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney, CURRENCIES, type Currency } from "@/lib/format"
import { addDaysToIsoDate } from "@/lib/receivables-aging"
import { SALE_CHANNELS } from "@/lib/kpi-format"
import type { SaleOperation } from "@/lib/group-operations"
import { formatStock } from "@/lib/format-unit"
import {
  unitInputStep,
  unitInputMin,
  toBaseQuantity,
  resolveUnit,
  compatibleUnits,
} from "@/lib/unit-utils"
import {
  calcSaleSubtotal,
  calcCartTotal,
  unitPriceFromSubtotal,
  type SaleCartItem,
} from "@/lib/cart-utils"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { argentinaToday } from "@/lib/date-range"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { getCanonicalLabel } from "@/lib/product-labels"
import { ProductPicker } from "@/components/shared/product-picker"
import { Plus, UserPlus, ShoppingCart, PackagePlus, CalendarIcon, Ruler, AlertCircle } from "lucide-react"
import { toast } from "sonner"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { PaymentMethodSelect, BankAccountDestinationSelect } from "@/components/payment-methods/PaymentMethodSelect"
import { Checkbox } from "@/components/ui/checkbox"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { bankAccountForKind } from "@/lib/types"
import { humanizeOperationError } from "@/lib/operation-errors"
import { useRouter } from "next/navigation"
import { useCustomerAccount } from "@/hooks/data/use-customer-account"
import { useBranches } from "@/hooks/data/use-branches"
import { useCashOptin } from "@/hooks/use-cash-optin"

interface SaleFormProps {
  onSuccess: () => void
  /** When provided, the form opens in edit mode pre-filled with this operation. */
  editingOperation?: SaleOperation
}

export function SaleForm({ onSuccess, editingOperation }: SaleFormProps) {
  const { products }                                     = useProducts()
  const { clients, addClient }                           = useClients()
  const { addSaleOperation, updateSaleOperation }        = useSales()
  const queryClient = useQueryClient()
  const { user }    = useAuth()
  const refreshData = () => queryClient.invalidateQueries()
  const { units, unitsById } = useUnitsOfMeasure()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("sale-create")
  const isEdit = !!editingOperation
  const router = useRouter()

  // ── pagos-cableados-restantes (OQ-C/OQ-D): catálogo + kind resuelto ────────
  // Mismo patrón que /ventas/pos (pos-catalogo-pagos D7/D8) — reutilización
  // antes que repetición: usePaymentMethods, useCustomerAccount, useBranches/
  // useCashboxes/useCurrentSession son los mismos hooks, no una copia.
  const { paymentMethods } = usePaymentMethods()
  // edicion-preserva-contexto (F2 §D11) + venta-editable-sin-cae (D11): el
  // comprobante fiscal de la operación YA SALIÓ hacia ARCA (authorized, o
  // pending_cae marcado/congelado) — el form se abre en solo lectura. El P0423
  // del backend sigue siendo la defensa real (guard de la RPC); esto sólo evita
  // que el usuario llegue hasta ese error.
  const isFiscallyLocked = isEdit && !!editingOperation?.isFiscallyLocked
  const invoicedBannerId = "sale-form-invoiced-banner"
  // venta-editable-sin-cae: el comprobante está PENDIENTE y todavía no se
  // envió — guardar los cambios lo va a ANULAR. No bloquea nada: el pedido del
  // PO es justamente que se pueda, con aviso y confirmación explícita.
  const fiscal = isEdit ? editingOperation?.fiscal ?? null : null
  const willVoidFiscalDocument = !!fiscal?.voidable
  const voidableComprobante = fiscal?.label ?? null
  const voidBannerId = "sale-form-void-pending-banner"
  // Confirmación explícita antes de disparar la mutación (patrón de la casa:
  // el servidor compensa, el diálogo enumera antes de confirmar).
  const [confirmVoidOpen, setConfirmVoidOpen] = useState(false)
  // El AlertDialog se abre por ESTADO (no hay AlertDialogTrigger: lo dispara el
  // submit del formulario), y Radix sólo sabe devolver el foco al trigger que
  // no existe — al cerrar con Escape o Cancelar el foco caía al <body> y quien
  // navega con teclado quedaba al principio del formulario, con todo el carrito
  // por recorrer de nuevo. Se devuelve a mano al botón que lo abrió.
  const submitButtonRef = useRef<HTMLButtonElement>(null)

  // Synchronous re-entrancy guard: closes the double-click window before the
  // async `submitting` state has a chance to re-render the disabled button.
  const submittingRef = useRef(false)

  // ── Cart state ──────────────────────────────────────────────────────────────
  // In edit mode: pre-populate cart from the existing operation's items.
  // unitPrice = stored amount (already the effective / post-discount price).
  // discount = 0 (not stored separately in DB).
  const [cartItems, setCartItems] = useState<SaleCartItem[]>(() => {
    if (!editingOperation) return []
    return editingOperation.items.map(item => ({
      id:          crypto.randomUUID(),
      productId:   item.productId,
      productName: item.productName,
      unitPrice:   item.unitPrice,
      quantity:    item.quantity,
      discount:    0,
      subtotal:    Math.round(item.unitPrice * item.quantity * 10_000) / 10_000,
      // edicion-preserva-contexto (F1 §D7): unit_id se prefillea y se
      // reenvía tal cual — el form no ofrece cambiar la unidad al editar,
      // pero el valor tiene que sobrevivir el round-trip para no perderse.
      unitId:      item.unitId,
    }))
  })

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [unitPrice, setUnitPrice] = useState(0)
  const [quantity, setQuantity] = useState(1)
  const [discount, setDiscount] = useState(0)
  const [unitId, setUnitId] = useState("")

  // Subtotal is editable: the user can type the exact price the sale closed at
  // and we back-compute the effective unit price. While the field is focused we
  // show their raw draft (avoids rounding flicker when qty > 1); when blurred we
  // show the derived stagedSubtotal. unitPrice + discount remain the source of
  // truth, so the rest of the form (and persistence) is unchanged.
  const [subtotalFocused, setSubtotalFocused] = useState(false)
  const [subtotalDraft, setSubtotalDraft] = useState(0)

  // ── Header fields (apply to all items) ─────────────────────────────────────
  const [clientId, setClientId] = useState(() => editingOperation?.clientId ?? "")
  const [currency, setCurrency] = useState<Currency>(() => (editingOperation?.currency as Currency) ?? "ARS")
  const [date, setDate] = useState(() => editingOperation?.date ?? argentinaToday())
  // edicion-preserva-contexto (F1 §D11): al editar, prefillear desde
  // editingOperation — antes arrancaba en null ignorándolo, así que el
  // payload de edición ni siquiera los incluía y la sucursal/canal quedaban
  // en NULL tras cada edición (mismo patrón que clientId/currency/date más abajo).
  const [branchId, setBranchId] = useState<string | null>(() => editingOperation?.branchId ?? null)
  // Canal de venta (Fase B Bloque KPI): alimenta "Margen por Canal". Opcional.
  const [canal, setCanal] = useState<string | null>(() => editingOperation?.canal ?? null)
  // metodos-pago-operaciones: forma de pago de la operación, opcional.
  // Precargada al editar (D5) — el resto de las líneas la siguen (D3).
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(
    () => editingOperation?.paymentMethodId ?? null,
  )
  // pos-banco-movimientos (D2/D9): override de la cuenta bancaria destino —
  // sólo aplica en alta (la edición no tiene parámetro de banco en la RPC,
  // ver D8: el guard bloquea la edición cuando YA hay un bank_movement).
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  // pagos-cableados-restantes (OQ-C): opt-in explícito de caja — el usuario
  // tilda la casilla, nunca se marca solo (D4: silenciosamente convertiría
  // toda venta retroactiva en una diferencia de arqueo — alternativa
  // descartada en el design). Sólo se envía cuando las tres condiciones de
  // servidor también se cumplen (ver cashOptinEligible más abajo).
  const [registerInCash, setRegisterInCash] = useState(false)

  // ── Inline new client ───────────────────────────────────────────────────────
  const [showNewClient, setShowNewClient] = useState(false)
  const [newClientName, setNewClientName] = useState("")
  const [newClientEmail, setNewClientEmail] = useState("")
  const [newClientPhone, setNewClientPhone] = useState("")

  // ── Submission state ────────────────────────────────────────────────────────
  const [submitting, setSubmitting] = useState(false)

  // ── Derived ─────────────────────────────────────────────────────────────────
  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
  )
  const selectedClient = useMemo(
    () => clients.find((c) => c.id === clientId),
    [clients, clientId],
  )

  // ── pagos-cableados-restantes (OQ-D): kind resuelto + cuenta corriente ─────
  const selectedPaymentMethod = useMemo(
    () => paymentMethods.find((pm) => pm.id === paymentMethodId) ?? null,
    [paymentMethods, paymentMethodId],
  )
  const resolvedKind = selectedPaymentMethod?.kind ?? null
  const isCreditSelected = resolvedKind === "credit"
  const { data: customerAccount } = useCustomerAccount(isCreditSelected ? (clientId || null) : null)
  const creditBlockedNoClient = isCreditSelected && !clientId

  // ── cobranzas-vencimientos (D3/D11): vencimiento de la venta a crédito ──
  // El campo se PRE-CARGA con el resuelto por la cascada (plazo del cliente →
  // default de la cuenta) y es editable. Sólo viaja al servidor cuando el
  // usuario lo TOCÓ — sin tocar, va null y la cascada AUTORITATIVA se
  // resuelve en _pay_register_party_charge (nunca acá). El POS no tiene este
  // campo: usa la cascada sin UI extra (D11).
  const { data: collectionSettings } = useCollectionSettings()
  const [dueDate, setDueDate] = useState("")
  const [dueDateTouched, setDueDateTouched] = useState(false)
  const effectiveTermsDays =
    selectedClient?.paymentTermsDays ??
    collectionSettings?.defaultPaymentTermsDays ??
    null
  const resolvedDueDate =
    effectiveTermsDays !== null && date ? addDaysToIsoDate(date, effectiveTermsDays) : ""
  useEffect(() => {
    if (!dueDateTouched) setDueDate(resolvedDueDate)
  }, [resolvedDueDate, dueDateTouched])

  // ── pagos-cableados-restantes (OQ-C): opt-in de caja ────────────────────────
  // La sucursal EFECTIVA es la elegida en el form, o la primera activa de la
  // cuenta cuando no se eligió ninguna (mismo fallback que la RPC —
  // c26_default_branch — y que /ventas/pos).
  // gastos-forma-pago (D16, task 8.5): las tres condiciones salieron de acá a
  // `useCashOptin` — el formulario de gasto es el segundo consumidor del bloque
  // exacto. Extracción pura: mismos hooks, mismos predicados, mismos textos.
  const { branches } = useBranches()
  const cashOptin = useCashOptin({ kind: resolvedKind, branchId, date, document: "venta" })
  const isCashSelected = cashOptin.isCashSelected
  const effectiveBranchId = cashOptin.effectiveBranchId
  // Contexto para traducir errores de la RPC (bug prod 2026-08-24: el error de
  // stock llegaba con el UUID crudo y culpaba al inventario cuando el problema
  // real era la sucursal). El nombre sale del carrito primero (lo que el
  // usuario ve) y del catálogo como respaldo.
  const lookupProductName = useCallback(
    (id: string) =>
      cartItems.find((i) => i.productId === id)?.productName ??
      products.find((p) => p.id === id)?.name,
    [cartItems, products],
  )
  const effectiveBranchName =
    branches.find((b) => b.id === effectiveBranchId)?.name ?? null

  // sucursal-guard-vaciado-auditoria (G3, task 7.5): muestra el error de
  // operación humanizado y, si trae acción (transferir stock del producto
  // involucrado), la cablea como botón del toast — sonner soporta `action`
  // nativamente, sin diálogo nuevo.
  const showOperationError = useCallback(
    (prefix: string, rawMessage: string) => {
      const { message, action } = humanizeOperationError(rawMessage, lookupProductName, effectiveBranchName)
      toast.error(`${prefix}${message}`, action ? {
        action: { label: action.label, onClick: () => router.push(action.href) },
      } : undefined)
    },
    [router, lookupProductName, effectiveBranchName],
  )

  // Las TRES condiciones de servidor (D4) — el checkbox sólo aparece cuando
  // las tres se cumplen; si no, se explica el motivo (nunca se oculta en
  // silencio).
  const currentSession = cashOptin.session
  const cashOptinEligible = cashOptin.eligible
  const cashOptinReason = cashOptin.reason

  // Resolve selected unit from the map (O(1) vs O(n) Array.find)
  const selectedUnit = useMemo(
    () => resolveUnit(unitId, unitsById),
    [unitId, unitsById],
  )

  // ventas-unidades-conversion (D1/D5): unidad en que se lleva el stock del
  // producto; normalización local y opciones del selector salen de la misma
  // función que en el POS y en el formulario de compra.
  const productBaseUnit = useMemo(
    () => resolveUnit(selectedProduct?.baseUnitId, unitsById),
    [selectedProduct, unitsById],
  )
  const unitOptions = useMemo(
    () => compatibleUnits(units, productBaseUnit),
    [units, productBaseUnit],
  )

  // Input constraints for the staged quantity — driven by selected unit type
  const stagedStep = useMemo(() => unitInputStep(selectedUnit), [selectedUnit])
  const stagedMin  = useMemo(() => unitInputMin(selectedUnit),  [selectedUnit])

  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])

  // pagos-cableados-restantes (D8): saldo proyectado tras esta venta — mismo
  // patrón visual que /ventas/pos (0 si aún no resolvió la CustomerAccount).
  const projectedBalance = (customerAccount?.balance ?? 0) + cartTotal

  const stagedSubtotal = useMemo(
    () => (selectedProduct ? calcSaleSubtotal(unitPrice, quantity, discount) : 0),
    [selectedProduct, unitPrice, quantity, discount],
  )

  // Quantity converted to base unit — used for local stock validation
  const stagedQuantityNormalized = useMemo(
    () => toBaseQuantity(quantity, selectedUnit, productBaseUnit),
    [quantity, selectedUnit, productBaseUnit],
  )

  // ── Option lists ────────────────────────────────────────────────────────────

  // IDs of parent catalogue entries (have at least one variant child).
  // Must NOT appear in the sale dropdown — users must pick a specific variant.
  const parentProductIds = useMemo(() => {
    const ids = new Set<string>()
    for (const p of products) {
      if (p.parentId) ids.add(p.parentId)
    }
    return ids
  }, [products])

  const productById = useMemo(
    () => new Map(products.map((p) => [p.id, p])),
    [products],
  )

  const clientOptions = useMemo(
    () => clients.map((c) => ({ value: c.id, label: c.name })),
    [clients],
  )

  // ── Handlers ────────────────────────────────────────────────────────────────

  /**
   * Called by the barcode scanner on each successful scan.
   * Looks up the product by its barcode and directly adds qty 1 to the cart,
   * bypassing the staged-item flow so the user can scan multiple items
   * without clicking "Agregar".
   */
  const handleBarcodeScan = useCallback((barcode: string) => {
    const product = products.find(
      (p) =>
        p.barcode &&
        p.barcode.toUpperCase() === barcode.toUpperCase() &&
        !parentProductIds.has(p.id),
    )

    if (!product) {
      toast.error(`Código "${barcode}" no encontrado`)
      return
    }

    const baseUnit = resolveUnit(product.baseUnitId, unitsById)
    const qty      = unitInputMin(baseUnit)   // honour fractional-unit minimums
    const step     = unitInputStep(baseUnit)

    setCartItems((prev) => {
      const existing = prev.find(
        (item) =>
          item.productId === product.id &&
          (item.unitId ?? "") === (product.baseUnitId ?? ""),
      )

      if (existing) {
        const newQty = existing.quantity + qty
        toast.success(`+${qty} ${product.name}`)
        return prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:     newQty,
                quantityBase: toBaseQuantity(newQty, baseUnit, baseUnit),
                subtotal:     calcSaleSubtotal(product.price, newQty, item.discount),
              }
            : item,
        )
      } else {
        toast.success(`✓ ${product.name}`)
        return [
          ...prev,
          {
            id:           crypto.randomUUID(),
            productId:    product.id,
            productName:  getCanonicalLabel(product, product.parentId ? productById.get(product.parentId) : undefined),
            unitPrice:    product.price,
            quantity:     qty,
            discount:     0,
            subtotal:     calcSaleSubtotal(product.price, qty, 0),
            unitId:       product.baseUnitId || undefined,
            unitSymbol:   baseUnit?.symbol,
            quantityBase: toBaseQuantity(qty, baseUnit, baseUnit),
            step,
            minQty:       qty,
          },
        ]
      }
    })
  }, [products, parentProductIds, unitsById, productById])

  function handleProductChange(id: string) {
    setProductId(id)
    setQuantity(1)
    setDiscount(0)
    // Pre-select the product's base unit so step/min are immediately correct
    const p = products.find((x) => x.id === id)
    const nextUnitId = p?.baseUnitId ?? ""
    setUnitId(nextUnitId)
    // ventas-unidades-conversion (D5): la cantidad arranca en el mínimo de la
    // unidad base (0,001 para medibles), no en un 1 fijo.
    setQuantity(unitInputMin(resolveUnit(nextUnitId, unitsById)))
    setUnitPrice(p?.price ?? 0)
  }

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }

    // Existing cart item with same product AND same unit → accumulate quantities
    const existing = cartItems.find(
      (item) => item.productId === productId && (item.unitId ?? "") === unitId,
    )

    // El stock del producto se lleva en su unidad BASE: el disponible se
    // informa con el símbolo de la base, nunca con el de la línea (con la
    // línea en gramos decía "0.550 g" sobre 0,55 kg — corrección del PR #584).
    if (existing) {
      const newQty           = existing.quantity + quantity
      const newNormalized    = toBaseQuantity(newQty, selectedUnit, productBaseUnit)
      if (newNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${formatStock(selectedProduct.stock, productBaseUnit?.symbol)})`)
        return
      }
      setCartItems((prev) =>
        prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:      newQty,
                quantityBase:  newNormalized,
                subtotal:      calcSaleSubtotal(item.unitPrice, newQty, item.discount),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      // New cart entry (different product or different unit)
      if (stagedQuantityNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${formatStock(selectedProduct.stock, productBaseUnit?.symbol)})`)
        return
      }
      setCartItems((prev) => [
        ...prev,
        {
          id:            crypto.randomUUID(),
          productId:     selectedProduct.id,
          productName:   getCanonicalLabel(selectedProduct, selectedProduct.parentId ? productById.get(selectedProduct.parentId) : undefined),
          unitPrice:     unitPrice,
          quantity,
          discount,
          subtotal:      stagedSubtotal,
          unitId:        unitId || undefined,
          unitSymbol:    selectedUnit?.symbol,
          quantityBase:  stagedQuantityNormalized,
          step:          stagedStep,
          minQty:        stagedMin,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }

    // Reset staged item
    setProductId("")
    setUnitPrice(0)
    setQuantity(1)
    setDiscount(0)
    setUnitId("")
  }

  function handleRemoveItem(id: string) {
    setCartItems((prev) => prev.filter((item) => item.id !== id))
  }

  function handleUpdateQty(id: string, qty: number) {
    setCartItems((prev) =>
      prev.map((item) => {
        if (item.id !== id) return item
        // Use the item's own minQty — not a global 1 — so medibles can go below 1
        const newQty = Math.max(item.minQty ?? 1, qty)
        return {
          ...item,
          quantity:     newQty,
          quantityBase: toBaseQuantity(
            newQty,
            resolveUnit(item.unitId, unitsById),
            resolveUnit(productById.get(item.productId)?.baseUnitId, unitsById),
          ),
          subtotal:     calcSaleSubtotal(item.unitPrice, newQty, item.discount),
        }
      }),
    )
  }

  // Edit the subtotal of an item already in the cart: back-compute the effective
  // unit price and clear the discount (mirrors the staged-item behaviour).
  function handleUpdateSubtotal(id: string, newSubtotal: number) {
    setCartItems((prev) =>
      prev.map((item) =>
        item.id === id
          ? {
              ...item,
              unitPrice: unitPriceFromSubtotal(newSubtotal, item.quantity),
              discount:  0,
              subtotal:  newSubtotal,
            }
          : item,
      ),
    )
  }

  function handleCreateClient() {
    if (!newClientName.trim()) {
      toast.error("El nombre del cliente es obligatorio")
      return
    }
    addClient({
      name:         newClientName,
      email:        newClientEmail,
      phone:        newClientPhone,
      status:       "activo",
      lastPurchase: "-",
      totalSpent:   0,
    })
    toast.success(`Cliente "${newClientName}" creado`)
    setShowNewClient(false)
    setNewClientName("")
    setNewClientEmail("")
    setNewClientPhone("")
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (isFiscallyLocked) {
      // Defensa en profundidad: el botón ya está deshabilitado y el
      // fieldset ya bloquea los inputs — esto cubre un submit programático.
      toast.error("El comprobante fiscal de esta venta ya se envió a ARCA y no puede editarse.")
      return
    }
    // venta-editable-sin-cae: confirmación explícita ANTES de anular el
    // comprobante pendiente. Se abre el diálogo y se corta acá; "Guardar y
    // anular" vuelve a entrar por `submitOperation`.
    if (willVoidFiscalDocument) {
      setConfirmVoidOpen(true)
      return
    }
    await submitOperation()
  }

  /** El submit real, sin el paso de confirmación (lo comparten el submit
   * directo y el botón "Guardar y anular" del AlertDialog). */
  async function submitOperation() {
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }
    if (submittingRef.current) return
    submittingRef.current = true

    // ── Edit mode ─────────────────────────────────────────────────────────────
    if (isEdit && editingOperation) {
      if (!clientId && !editingOperation.clientId) {
        // Allow null client (Consumidor Final) — do not block edit
      }
      setSubmitting(true)
      try {
        const saleIds = editingOperation.items.map(i => i.id)
        const result = await updateSaleOperation({
          saleIds,
          newItems: cartItems,
          meta: {
            clientId: clientId || null,
            date,
            currency,
            orgId: user?.accountId ?? "",
            // metodos-pago-operaciones (D5): el form SIEMPRE manda el valor
            // vigente en el selector (precargado o cambiado por el usuario)
            // — nunca se omite, así que "reimputar con el mismo valor" y
            // "preservar" son observacionalmente idénticos para quien edita.
            paymentMethodId,
            // edicion-preserva-contexto (F1 §D11): mismo criterio — el
            // selector siempre está montado, así que branchId/canal viajan
            // siempre con el valor vigente del form.
            branchId,
            canal,
          },
        })
        // venta-editable-sin-cae: el toast se arma con lo que dice el
        // SERVIDOR (`voided_fiscal_document`), no con lo que el cliente creía
        // antes de guardar: si la carrera contra el relay hizo que el servidor
        // bloqueara, llega un 409 y nunca se muestra un "anulado" falso.
        const voided = result?.voided_fiscal_document ?? null
        toast.success(
          voided
            ? `✅ Cambios guardados — se anuló el comprobante ${voided.label}`
            : "✅ Venta actualizada correctamente",
        )
        await refreshData()
        onSuccess()
      } catch (err: any) {
        showOperationError("Error al actualizar: ", err.message)
      } finally {
        setSubmitting(false)
        submittingRef.current = false
      }
      return
    }

    // ── Create mode ───────────────────────────────────────────────────────────
    if (!selectedClient) {
      toast.error("Seleccioná un cliente")
      submittingRef.current = false
      return
    }

    setSubmitting(true)
    try {
      // One atomic, idempotent call for the whole cart. The idempotency_key is
      // stable across retries/F5 (sessionStorage), so a double-submit or a
      // resend-after-lost-response resolves to the SAME operation server-side
      // (replay) instead of creating duplicates. Either every line commits or
      // none does — no partial sale.
      await addSaleOperation({
        items: cartItems,
        meta: {
          idempotencyKey: idempotencyKey,
          clientId:       selectedClient.id,
          date,
          currency,
          branchId,
          canal,
          paymentMethodId,
          orgId:          user?.accountId ?? "",
          // pagos-cableados-restantes (OQ-C): sólo viaja cuando el usuario
          // tildó la casilla Y las tres condiciones de servidor se cumplen —
          // la RPC vuelve a validar todo (D4), esto es sólo la intención.
          cashSessionId:  cashOptinEligible && registerInCash ? (currentSession?.id ?? null) : null,
          // cobranzas-vencimientos (D3): SOLO viaja el override que el
          // usuario tocó — sin tocar, null y la cascada se resuelve en el
          // servidor (una sola definición del vencimiento).
          dueDate: isCreditSelected && dueDateTouched && dueDate ? dueDate : null,
          // pos-banco-movimientos (D2): override opcional del destino —
          // null cuando el selector no está montado (kind no bancario) o
          // el usuario dejó "usar el destino configurado".
          bankAccountId:  bankAccountForKind(resolvedKind, bankAccountId),
        },
      })
      // Success → retire this key so the NEXT sale starts a fresh operation.
      resetIdempotencyKey()
      toast.success(
        cartItems.length > 1
          ? `✅ Venta registrada (${cartItems.length} ítems)`
          : "✅ Venta registrada correctamente",
      )
      await refreshData()
      onSuccess()
    } catch (err: any) {
      showOperationError("Error al registrar la venta: ", err.message)
    } finally {
      setSubmitting(false)
      submittingRef.current = false
    }
  }

  // ── Dynamic label for the quantity field ─────────────────────────────────────
  const quantityLabel = selectedUnit
    ? `Cantidad (${selectedUnit.symbol})`
    : "Cantidad"

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <form onSubmit={handleSubmit}>
      {/* edicion-preserva-contexto (F2 §D11): banner de bloqueo fiscal —
          explica el motivo ANTES de que el usuario intente guardar. El
          fieldset de más abajo deja todos los controles inertes; este
          párrafo (con role="status" para que un lector de pantalla lo
          anuncie al entrar en modo edición) es el "motivo accesible" del
          botón deshabilitado. */}
      {isFiscallyLocked && (
        <div
          id={invoicedBannerId}
          role="status"
          className="mb-3 rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive"
        >
          {/* venta-editable-sin-cae: el motivo NOMBRA LA CAUSA REAL — tres
              causas distintas comparten P0423 y la salida del usuario es
              distinta en cada una. */}
          <p className="font-semibold">
            {fiscal?.status === "authorized"
              ? "Esta venta tiene un comprobante autorizado por ARCA"
              : fiscal?.frozen
                ? "El envío del comprobante a ARCA no se confirmó"
                : "El comprobante de esta venta ya se envió a ARCA"}
          </p>
          <p className="mt-1 text-destructive/90">
            {fiscal?.status === "authorized"
              ? `No se puede editar una venta con comprobante autorizado${fiscal?.label ? ` (${fiscal.label})` : ""}. Para corregirla, emití una nota de crédito y registrá una venta nueva con los datos correctos.`
              : fiscal?.frozen
                ? `El comprobante${fiscal?.label ? ` ${fiscal.label}` : ""} salió hacia ARCA y su resultado nunca se confirmó. Necesita revisión manual en ARCA antes de reintentar.`
                : `El comprobante${fiscal?.label ? ` ${fiscal.label}` : ""} ya se envió a ARCA y todavía no hay respuesta. Vas a poder editar la venta cuando se resuelva.`}
          </p>
        </div>
      )}
      {/* venta-editable-sin-cae: banner DISTINTO del de bloqueo — acá no hay un
          error, hay un aviso. Tokens de advertencia, no `destructive`. */}
      {willVoidFiscalDocument && (
        <div
          id={voidBannerId}
          role="status"
          className="mb-3 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          <p className="font-semibold">Esta venta tiene un comprobante pendiente</p>
          <p className="mt-1 text-muted-foreground">
            Si guardás los cambios se va a anular el comprobante
            {voidableComprobante ? ` ${voidableComprobante}` : ""}, que todavía no se envió
            a ARCA. Después podés volver a emitirlo desde la venta.
          </p>
        </div>
      )}
      <fieldset disabled={isFiscallyLocked} className="contents">
      <ScrollableCartShell
        hasItems={cartItems.length > 0}

        // ── Scrollable cart list ─────────────────────────────────────────
        listContent={
          <CartItemList
            items={cartItems.map((item) => ({
              id:          item.id,
              productName: item.productName,
              quantity:    item.quantity,
              unitValue:   item.unitPrice,
              subtotal:    item.subtotal,
              step:        item.step,
              minQty:      item.minQty,
              badge: [
                item.unitSymbol ?? null,
                item.discount > 0 ? `${item.discount}% desc.` : null,
              ]
                .filter(Boolean)
                .join(" · ") || undefined,
            }))}
            onRemove={handleRemoveItem}
            onUpdateQty={handleUpdateQty}
            onUpdateSubtotal={handleUpdateSubtotal}
            unitLabel="Precio unit."
            currency={currency}
          />
        }

        // ── Sticky footer: total + submit ────────────────────────────────
        footerContent={
          <>
            {cartItems.length > 0 && (
              <div className="rounded-lg border border-border bg-accent/50 p-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-muted-foreground flex items-center gap-2">
                    <ShoppingCart className="h-4 w-4" />
                    Total — {cartItems.length} ítem{cartItems.length !== 1 ? "s" : ""}
                  </span>
                  <span className="text-xl font-bold text-primary tabular-nums">
                    {formatMoney(cartTotal, currency)}
                  </span>
                </div>
              </div>
            )}

            <Button
              type="submit"
              ref={submitButtonRef}
              className="w-full"
              disabled={submitting || cartItems.length === 0 || isFiscallyLocked}
              aria-disabled={isFiscallyLocked}
              aria-describedby={
                isFiscallyLocked
                  ? invoicedBannerId
                  : willVoidFiscalDocument
                    ? voidBannerId
                    : undefined
              }
            >
              {isFiscallyLocked
                ? "No editable — comprobante enviado a ARCA"
                : submitting
                ? isEdit ? "Guardando..." : "Registrando..."
                : isEdit
                ? `Guardar cambios (${cartItems.length} ítem${cartItems.length !== 1 ? "s" : ""})`
                : cartItems.length > 1
                ? `Confirmar venta (${cartItems.length} ítems)`
                : "Confirmar venta"}
            </Button>
          </>
        }
      >
        {/* ── HEADER: Cliente + Moneda + Fecha ─────────────────────────── */}
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between">
              <Label className="text-foreground">Cliente</Label>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-6 text-xs text-primary"
                onClick={() => setShowNewClient(!showNewClient)}
              >
                <UserPlus className="h-3 w-3 mr-1" />
                {showNewClient ? "Cancelar" : "Nuevo cliente"}
              </Button>
            </div>

            {showNewClient ? (
              <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
                <Input
                  selectOnFocus
                  value={newClientName}
                  onChange={(e) => setNewClientName(e.target.value)}
                  placeholder="Nombre del cliente"
                  className="bg-background border-border text-foreground text-sm"
                />
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <Input
                    selectOnFocus
                    value={newClientEmail}
                    onChange={(e) => setNewClientEmail(e.target.value)}
                    placeholder="Email (opcional)"
                    className="bg-background border-border text-foreground text-sm"
                  />
                  <Input
                    selectOnFocus
                    value={newClientPhone}
                    onChange={(e) => setNewClientPhone(e.target.value)}
                    placeholder="Teléfono (opcional)"
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  onClick={handleCreateClient}
                  className="w-full"
                >
                  <Plus className="h-3 w-3 mr-1" />
                  Crear y seleccionar
                </Button>
              </div>
            ) : (
              <SearchableSelect
                options={clientOptions}
                value={clientId}
                onValueChange={setClientId}
                placeholder="Seleccionar cliente"
                searchPlaceholder="Buscar cliente..."
                emptyMessage="No se encontraron clientes."
              />
            )}
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-2">
              <Label className="text-foreground">Moneda</Label>
              <Select value={currency} onValueChange={(v) => setCurrency(v as Currency)}>
                <SelectTrigger className="bg-background border-border text-foreground">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-popover border-border">
                  {CURRENCIES.map((c) => (
                    <SelectItem key={c.value} value={c.value}>
                      {c.symbol} ({c.value})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="flex flex-col gap-2">
              <Label className="text-foreground flex items-center gap-1.5">
                <CalendarIcon className="h-3.5 w-3.5 text-muted-foreground" />
                Fecha
              </Label>
              <input
                type="date"
                value={date}
                max={argentinaToday()}
                onChange={(e) => setDate(e.target.value)}
                className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              />
            </div>
          </div>

          {/* ── Sucursal (solo plan PRO) ──────────────────────────────── */}
          <BranchSelect
            value={branchId}
            onChange={setBranchId}
            placeholder="Sin sucursal (general)"
            className="bg-background border-border text-foreground text-sm"
          />

          {/* ── Canal de venta (alimenta el KPI Margen por Canal) ─────── */}
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Canal de venta</Label>
            <Select
              value={canal ?? "__none__"}
              onValueChange={(v) => setCanal(v === "__none__" ? null : v)}
            >
              <SelectTrigger className="bg-background border-border text-foreground">
                <SelectValue placeholder="Sin canal" />
              </SelectTrigger>
              <SelectContent className="bg-popover border-border">
                <SelectItem value="__none__">Sin canal</SelectItem>
                {SALE_CHANNELS.map((c) => (
                  <SelectItem key={c.value} value={c.value}>
                    {c.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {/* ── Forma de pago (metodos-pago-operaciones) ───────────────── */}
          <PaymentMethodSelect
            value={paymentMethodId}
            onChange={setPaymentMethodId}
            context="sale"
            className="bg-background border-border text-foreground text-sm"
          />

          {/* ── Cuenta bancaria destino (pos-banco-movimientos D9) ──────────
              Contiguo al selector de forma de pago; cero render si el kind
              elegido no es bancario o la cuenta no tiene bancos cargados.
              Sin equivalente en edición (D8: no hay parámetro de banco en
              la RPC de edición). */}
          {!isEdit && (
            <BankAccountDestinationSelect
              paymentMethodKind={resolvedKind}
              value={bankAccountId}
              onChange={setBankAccountId}
              className="bg-background border-border text-foreground text-sm"
            />
          )}

          {/* ── Bloque de cuenta corriente (pagos-cableados-restantes OQ-D) ──
              Mismo patrón visual que /ventas/pos (pos-catalogo-pagos D8):
              cliente obligatorio + saldo actual/proyectado, sólo con 'credit'. */}
          {!isEdit && isCreditSelected && (
            <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
              {creditBlockedNoClient ? (
                <div className="flex items-center gap-2 text-amber-700 dark:text-amber-400">
                  <AlertCircle className="h-3.5 w-3.5 shrink-0" />
                  <span>
                    Elegí un cliente: una venta a cuenta corriente se le carga a alguien.
                  </span>
                </div>
              ) : (
                <>
                  <div className="flex items-center justify-between gap-2 text-muted-foreground">
                    <span>Saldo actual: {formatMoney(customerAccount?.balance ?? 0, "ARS")}</span>
                    <span className="font-medium text-foreground">
                      Después de esta venta: {formatMoney(projectedBalance, "ARS")}
                    </span>
                  </div>
                  {/* cobranzas-vencimientos (D11): vencimiento resuelto y
                      EDITABLE — el POS no tiene este campo (usa la cascada). */}
                  <div className="flex items-center justify-between gap-2 pt-1 border-t border-border/60">
                    <Label
                      htmlFor="sale-due-date"
                      className="text-xs text-muted-foreground shrink-0"
                    >
                      Vencimiento
                    </Label>
                    <Input
                      id="sale-due-date"
                      type="date"
                      value={dueDate}
                      min={date}
                      onChange={(e) => {
                        setDueDate(e.target.value)
                        setDueDateTouched(true)
                      }}
                      className="h-7 w-auto bg-background border-border text-foreground text-xs"
                    />
                  </div>
                  <p className="text-[11px] text-muted-foreground">
                    {dueDateTouched && dueDate
                      ? "Vencimiento elegido para esta venta."
                      : effectiveTermsDays !== null
                      ? selectedClient?.paymentTermsDays != null
                        ? `Resuelto por el plazo del cliente (${effectiveTermsDays} días).`
                        : `Resuelto por el plazo de la cuenta (${effectiveTermsDays} días).`
                      : "Sin plazo configurado: el cargo nace sin vencimiento (podés elegir una fecha)."}
                  </p>
                </>
              )}
            </div>
          )}

          {/* ── Opt-in de caja (pagos-cableados-restantes OQ-C) ─────────────
              El checkbox SÓLO aparece cuando las tres condiciones de
              servidor se cumplen (kind=cash + sesión abierta en la sucursal
              efectiva + fecha=hoy) — si no, se explica el motivo (D4: nunca
              se oculta en silencio, y nunca se marca solo). */}
          {!isEdit && isCashSelected && (
            <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
              {cashOptinEligible ? (
                <label className="flex items-center gap-2 cursor-pointer text-foreground">
                  <Checkbox
                    checked={registerInCash}
                    onCheckedChange={(v) => setRegisterInCash(v === true)}
                  />
                  <span>
                    Registrar en caja — sesión {currentSession?.id.slice(0, 8)}…
                  </span>
                </label>
              ) : (
                <div className="flex items-center gap-2 text-muted-foreground">
                  <AlertCircle className="h-3.5 w-3.5 shrink-0" />
                  <span>{cashOptinReason}</span>
                </div>
              )}
            </div>
          )}
        </div>

        <div className="border-t border-border" />

        {/* ── HEADER: Product Adder ────────────────────────────────────── */}
        <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
          <div className="flex items-center justify-between">
            <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
              <PackagePlus className="h-3.5 w-3.5" />
              Agregar producto
            </Label>
            <BarcodeScannerInput onScan={handleBarcodeScan} />
          </div>

          <ProductPicker
            products={products}
            productById={productById}
            unitsById={unitsById}
            value={productId}
            onValueChange={handleProductChange}
            currency={currency}
          />

          {selectedProduct && (
            <div className="flex flex-col gap-2">
              {/* Row 0: Precio unitario */}
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground flex items-center justify-between">
                  Precio unit.
                  {unitPrice !== selectedProduct!.price && (
                    <span className="text-[9px] text-amber-400 tabular-nums">
                      Cat. {formatMoney(selectedProduct!.price, currency)}
                    </span>
                  )}
                </Label>
                <NumericInput
                  min={0}
                  step={1}
                  value={unitPrice}
                  onValueChange={setUnitPrice}
                  className="bg-background border-border text-foreground"
                />
              </div>
              {/* Row 1: Cantidad + Unidad */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">
                    {quantityLabel}
                  </Label>
                  <NumericInput
                    min={stagedMin}
                    step={stagedStep}
                    value={quantity}
                    onValueChange={(val) => setQuantity(Math.max(stagedMin, val))}
                    className="bg-background border-border text-foreground"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground flex items-center gap-1">
                    <Ruler className="h-3 w-3" />
                    Unidad
                  </Label>
                  <Select
                    value={unitId || "__none__"}
                    onValueChange={(v) => {
                      const next = v === "__none__" ? "" : v
                      setUnitId(next)
                      const nextUnit = next ? unitsById.get(next) : undefined
                      setQuantity(unitInputMin(nextUnit))
                    }}
                  >
                    <SelectTrigger className="bg-background border-border text-foreground h-10 text-sm">
                      <SelectValue placeholder="Base (×1)" />
                    </SelectTrigger>
                    <SelectContent className="bg-popover border-border">
                      {/* ventas-unidades-conversion (D5): sólo unidades compatibles
                          con la unidad base del producto (misma regla que el POS). */}
                      {!productBaseUnit && (
                        <SelectItem value="__none__">Sin unidad (base)</SelectItem>
                      )}
                      {unitOptions.map((u) => (
                        <SelectItem key={u.id} value={u.id}>
                          {u.symbol} — {u.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
              {/* Row 2: Descuento + Subtotal */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Descuento (%)</Label>
                  <NumericInput
                    min={0}
                    max={100}
                    value={discount}
                    onValueChange={setDiscount}
                    placeholder="0"
                    className="bg-background border-border text-foreground"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground flex items-center justify-between">
                    Subtotal
                    <span className="text-[9px] text-muted-foreground/70">editable</span>
                  </Label>
                  <NumericInput
                    min={0}
                    value={subtotalFocused ? subtotalDraft : stagedSubtotal}
                    onFocus={(e) => {
                      e.target.select()
                      setSubtotalDraft(stagedSubtotal)
                      setSubtotalFocused(true)
                    }}
                    onBlur={() => setSubtotalFocused(false)}
                    onValueChange={(val) => {
                      setSubtotalDraft(val)
                      // Fijar el precio efectivo a partir del subtotal tipeado.
                      setUnitPrice(unitPriceFromSubtotal(val, quantity))
                      setDiscount(0)
                    }}
                    className="bg-background border-border text-right font-bold text-emerald-400"
                  />
                </div>
              </div>
            </div>
          )}

          <Button
            type="button"
            variant="secondary"
            onClick={handleAddToCart}
            disabled={!selectedProduct}
            className="w-full gap-2"
          >
            <Plus className="h-4 w-4" />
            Agregar al carrito
          </Button>
        </div>
      </ScrollableCartShell>
      </fieldset>

      {/* venta-editable-sin-cae: confirmación EXPLÍCITA antes de anular el
          comprobante pendiente. Mismo patrón que operation-delete-compensation:
          el servidor compensa, el diálogo enumera antes de confirmar. */}
      <AlertDialog open={confirmVoidOpen} onOpenChange={setConfirmVoidOpen}>
        <AlertDialogContent
          className="bg-card border-border"
          onCloseAutoFocus={(event) => {
            event.preventDefault()
            submitButtonRef.current?.focus()
          }}
        >
          <AlertDialogHeader>
            <AlertDialogTitle className="text-card-foreground">
              ¿Guardar los cambios y anular el comprobante?
            </AlertDialogTitle>
            <AlertDialogDescription className="text-muted-foreground">
              El comprobante{voidableComprobante ? ` ${voidableComprobante}` : ""} todavía no
              se envió a ARCA, así que se va a anular para que no se emita con los importes
              viejos. Vas a poder emitir uno nuevo cuando quieras.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-border text-foreground">
              Cancelar
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                setConfirmVoidOpen(false)
                void submitOperation()
              }}
              disabled={submitting}
            >
              Guardar y anular
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </form>
  )
}
