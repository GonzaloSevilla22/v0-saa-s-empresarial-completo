"use client"

import { useState, useMemo, useCallback, useRef } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { SupplierSelect } from "@/components/suppliers/SupplierSelect"
import { CartItemList } from "@/components/shared/cart-item-list"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { useProducts } from "@/hooks/data/use-products"
import { usePurchases } from "@/hooks/data/use-purchases"
import { useSuppliers } from "@/hooks/data/use-suppliers"
import { useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney } from "@/lib/format"
import type { PurchaseOperation } from "@/lib/group-operations"
import { bankAccountForKind, type PaymentMethodKind } from "@/lib/types"
import {
  unitInputStep,
  unitInputMin,
  toBaseQuantity,
  convertUnitPrice,
  resolveUnit,
  compatibleUnits,
} from "@/lib/unit-utils"
import { ProductCategorySelect } from "@/components/product-categories/ProductCategorySelect"
import {
  calcPurchaseSubtotal,
  calcCartTotal,
  unitPriceFromSubtotal,
  type PurchaseCartItem,
} from "@/lib/cart-utils"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { argentinaToday } from "@/lib/date-range"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { getCanonicalLabel } from "@/lib/product-labels"
import { humanizeOperationError } from "@/lib/operation-errors"
import { ProductPicker } from "@/components/shared/product-picker"
import { Plus, PackagePlus, ShoppingCart, Ruler } from "lucide-react"
import { toast } from "sonner"
import { BranchSelect } from "@/components/branches/BranchSelect"
// remitos-compra (tanda B, 7.3): los campos de cierre y lo que se deriva de ellos salieron de este
// archivo a `PurchaseCheckoutFields` y `usePurchaseCheckout`, que comparte con el diálogo que
// convierte un remito de compra.
import { PurchaseCheckoutFields } from "@/components/compras/PurchaseCheckoutFields"
import { usePurchaseCheckout } from "@/hooks/use-purchase-checkout"

interface PurchaseFormProps {
  onSuccess: () => void
  /** When provided, the form opens in edit mode pre-filled with this operation. */
  editingOperation?: PurchaseOperation
}

export function PurchaseForm({ onSuccess, editingOperation }: PurchaseFormProps) {
  const isEdit = !!editingOperation

  const { products, addProduct }                           = useProducts()
  const { addPurchaseOperation, updatePurchaseOperation } = usePurchases()
  // compras-proveedor-cuenta-corriente (D10): mismo patrón que useClients en
  // SaleForm — combobox buscable + alta inline.
  // review C (F1): isLoading/isError entran al cálculo del hint de "proveedor
  // dado de baja" — sin ellos, "todavía no llegó" se leía como "no existe".
  const { suppliers, isLoading: suppliersLoading, isError: suppliersError } = useSuppliers()
  const queryClient = useQueryClient()
  const { user }    = useAuth()
  const refreshData = () => queryClient.invalidateQueries()
  const { units, unitsById } = useUnitsOfMeasure()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("purchase-create")

  // Synchronous re-entrancy guard: closes the double-click window before the
  // async `submitting` state re-renders the disabled button.
  const submittingRef = useRef(false)

  // ── Cart state ──────────────────────────────────────────────────────────────
  // In edit mode: pre-populate from the existing operation's items.
  const [cartItems, setCartItems] = useState<PurchaseCartItem[]>(() => {
    if (!editingOperation) return []
    return editingOperation.items.map(item => ({
      id:          crypto.randomUUID(),
      productId:   item.productId,
      productName: item.productName,
      unitCost:    item.unitCost,
      quantity:    item.quantity,
      subtotal:    Math.round(item.unitCost * item.quantity * 10_000) / 10_000,
      // edicion-preserva-contexto (F1 §D7): unit_id se prefillea y se
      // reenvía tal cual — espejo de SaleForm.
      unitId:      item.unitId,
    }))
  })

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [unitCost, setUnitCost] = useState(0)
  const [quantity, setQuantity] = useState(1)
  const [unitId, setUnitId] = useState("")

  // Subtotal editable: the user can type the line total and we back-compute the
  // effective unit cost. Focused-draft avoids rounding flicker when qty > 1.
  const [subtotalFocused, setSubtotalFocused] = useState(false)
  const [subtotalDraft, setSubtotalDraft] = useState(0)

  // ── Global description (one note per operation) ─────────────────────────────
  const [description, setDescription] = useState(() => editingOperation?.description ?? "")

  // ── Inline new product ──────────────────────────────────────────────────────
  const [showNewProduct, setShowNewProduct] = useState(false)
  const [newProductName, setNewProductName] = useState("")
  // productos-categorias-sku: id de categoría del catálogo (ya no un texto de PRODUCT_CATEGORIES).
  const [newProductCategoryId, setNewProductCategoryId] = useState<string | null>(null)
  const [newProductCost, setNewProductCost] = useState(0)
  const [newProductPrice, setNewProductPrice] = useState(0)
  const [newProductMinStock, setNewProductMinStock] = useState(10)

  // ── Operation date ──────────────────────────────────────────────────────────
  const [date, setDate] = useState(() => editingOperation?.date ?? argentinaToday())
  // edicion-preserva-contexto (F1 §D11): prefillear desde editingOperation —
  // espejo de SaleForm (antes arrancaba en null ignorándolo).
  const [branchId, setBranchId] = useState<string | null>(() => editingOperation?.branchId ?? null)
  // cost-center-dimension: optional analytic dimension for the whole operation.
  // review B (FE-1/OQ-5 A): prefillear desde editingOperation — antes
  // arrancaba siempre en null, ignorando el centro de costo vigente de la
  // operación (mismo defecto que branchId tenía antes de edicion-preserva-contexto).
  const [costCenterId, setCostCenterId] = useState<string | null>(
    () => editingOperation?.costCenterId ?? null,
  )
  // review B (FE-1): a diferencia de branchId/paymentMethodId (que SIEMPRE
  // se reenvían en la edición), costCenterId sigue el patrón "tocado" — solo
  // viaja en el payload si el usuario interactuó con el selector. Ausente =
  // preservar el vigente (contrato tri-estado por AUSENCIA, D7/OQ-5).
  const [costCenterTouched, setCostCenterTouched] = useState(false)
  const handleCostCenterChange = useCallback((v: string | null) => {
    setCostCenterId(v)
    setCostCenterTouched(true)
  }, [])
  // metodos-pago-operaciones: forma de pago de la operación, opcional.
  // Precargada al editar (D5) — el resto de las líneas la siguen (D3).
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(
    () => editingOperation?.paymentMethodId ?? null,
  )
  // review C (F3): "tocó la forma de pago" — no cambia lo que viaja en el
  // payload (paymentMethodId se reenvía siempre en la edición, D5), sino el
  // bloqueo del botón de guardar: el servidor solo aplica
  // credit_requires_supplier cuando la edición TOCA el contrato de crédito.
  const [paymentMethodTouched, setPaymentMethodTouched] = useState(false)
  const handlePaymentMethodChange = useCallback((v: string | null) => {
    setPaymentMethodId(v)
    setPaymentMethodTouched(true)
  }, [])
  // pos-banco-movimientos (D2/D9): override de la cuenta bancaria destino
  // del egreso — sólo en alta (espejo de SaleForm; la edición no tiene
  // parámetro de banco en la RPC, D8).
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  // compras-proveedor-cuenta-corriente (D4/D7): proveedor imputado a la
  // operación. Precargado al editar desde editingOperation.supplierId.
  const [supplierId, setSupplierId] = useState<string | null>(
    () => editingOperation?.supplierId ?? null,
  )
  // review B (FE-2): a diferencia de branchId/paymentMethodId, supplierId
  // sigue el patrón "tocado" en la edición — antes se reenviaba SIEMPRE el
  // valor vigente del form, lo que rompía en silencio cuando el selector no
  // podía resolver el supplierId prefillado en `suppliers` (proveedor dado
  // de baja: no aparece en la lista, value quedaba "" y el submit mandaba
  // supplierId=null, desimputando un proveedor que el usuario nunca tocó —
  // o, peor, un 404 si el backend llegara a validar pertenencia contra un id
  // que sí resuelve pero a otra cuenta). `supplierTouched` se marca desde el
  // onValueChange del selector Y desde el alta inline (handleCreateSupplier).
  const [supplierTouched, setSupplierTouched] = useState(false)

  // ── Submission state ────────────────────────────────────────────────────────
  const [submitting, setSubmitting] = useState(false)

  // ── Derived ─────────────────────────────────────────────────────────────────
  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
  )

  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])

  // remitos-compra (tanda B, 7.3): lo que se deriva de los campos de cierre —
  // kind de la forma de pago (sólo condiciona el render del selector de cuenta
  // bancaria), las tres condiciones del opt-in de caja (caja-compras-cobranzas D2,
  // PRE-MARCADO, D4), el saldo del proveedor a crédito— vive en `usePurchaseCheckout`,
  // compartido con el diálogo que convierte un remito de compra. En EDICIÓN se pide
  // el catálogo COMPLETO de formas de pago (incluidas las dadas de baja: la operación
  // puede estar imputada a una desactivada y esa lista resuelve su `kind`) y no se
  // ofrece la caja (D8).
  const checkout = usePurchaseCheckout({
    paymentMethodId,
    branchId,
    date,
    supplierId,
    total: cartTotal,
    isEdit,
  })
  const resolvedKind = checkout.kind
  const paymentMethods = checkout.paymentMethods

  // operacion-party-guard (fix ad-hoc 2026-09-10, hallazgo de revisión
  // adversarial ronda 1): rpc_create_purchase_operation y rpc_atomic_update_
  // purchase_operation rechazan un supplier_id ajeno con
  // `supplier_not_found: <uuid>` (P0404, D6 de compras-proveedor-cuenta-
  // corriente) — sin pasar por `humanizeOperationError` el usuario veía el
  // UUID crudo pese a que el comentario de operation-errors.ts ya citaba a
  // este formulario como consumidor. Mismo patrón que sale-form.tsx (lookup
  // por carrito primero, catálogo como respaldo); sin branchName porque este
  // form no resuelve el nombre de sucursal por id (STOCK_ERROR no aplica del
  // lado compra: una compra suma stock, nunca lo descuenta).
  const lookupProductName = useCallback(
    (id: string) =>
      cartItems.find((i) => i.productId === id)?.productName ??
      products.find((p) => p.id === id)?.name,
    [cartItems, products],
  )
  const showOperationError = useCallback(
    (prefix: string, rawMessage: string) => {
      const { message } = humanizeOperationError(rawMessage, lookupProductName)
      toast.error(`${prefix}${message}`)
    },
    [lookupProductName],
  )

  // compras-proveedor-cuenta-corriente (D6/OQ-D): kind=credit exige proveedor
  // y postea el cargo en su cuenta corriente — mismo patrón que SaleForm.
  const isCreditSelected = checkout.isCredit
  // review B (F3): el guard "elegí un proveedor" aplica en AMBOS modos — el
  // servidor rechaza kind=credit sin proveedor tanto en el alta como en la
  // edición (mismo P0400 credit_requires_supplier, batch A). Antes el botón
  // solo se deshabilitaba en alta (`!isEdit && creditBlockedNoSupplier`).
  const creditBlockedNoSupplier = checkout.creditBlockedNoSupplier
  // review C (F3): en EDICIÓN el servidor aplica credit_requires_supplier sólo
  // cuando la edición informa la forma de pago o el proveedor (migración
  // 20261009000001, review C/S1) — una compra legacy que YA estaba a crédito y
  // nunca tuvo proveedor (el estado de las 38 operaciones vivas en prod) sigue
  // siendo editable mientras no se toque ninguno de los dos. Bloquear el botón
  // ahí dejaba esas operaciones sin forma de corregirles ni una cantidad.
  // En ALTA no hay nada "vigente" que preservar: el bloqueo aplica siempre.
  const creditContractTouched = supplierTouched || paymentMethodTouched
  const submitBlockedNoSupplier = isEdit
    ? creditBlockedNoSupplier && creditContractTouched
    : creditBlockedNoSupplier

  // review B (F2): el selector no puede resolver el supplierId prefillado —
  // típicamente un proveedor dado de baja (soft delete, RN-B1: sale de
  // `suppliers`, la lista del selector). Solo importa mostrarlo cuando el
  // usuario todavía no tocó el campo — en cuanto elige algo, supplierId pasa
  // a apuntar a una opción real de la lista.
  // review C (F1): `suppliers` está vacío tanto cuando el proveedor fue dado de
  // baja como cuando la query todavía no respondió (primer open del diálogo de
  // edición: no hay caché) o falló. Sin mirar isLoading/isError, el form
  // afirmaba "dado de baja" sobre un proveedor perfectamente vivo.
  const supplierUnresolved =
    isEdit &&
    !supplierTouched &&
    !suppliersLoading &&
    !suppliersError &&
    !!supplierId &&
    !suppliers.some((s) => s.id === supplierId)

  // review B (F3): kind ORIGINAL de la operación (antes de cualquier cambio
  // en este form) — distingue "ya era crédito" (D7: editable sin postear
  // nada) de "está TRANSICIONANDO a crédito" (server: credit_transition_not_
  // allowed, batch A). Comparación por KIND, no por payment_method_id: dos
  // formas de pago distintas con el mismo kind='credit' no son una transición.
  //
  // review C (F2): el resultado es TRI-ESTADO, no "kind o null":
  //   "none" → la operación no tenía forma de pago. Pasarla a crédito SÍ es una
  //            transición (el servidor: v_old_kind NULL IS DISTINCT FROM
  //            'credit' ⇒ credit_transition_not_allowed).
  //   kind   → resuelto contra el catálogo COMPLETO (incluye las dadas de baja,
  //            ver usePaymentMethods(isEdit) arriba).
  //   null   → todavía no se pudo resolver (la query no respondió). DESCONOCIDO
  //            no es "no era crédito": antes se colapsaban los tres casos en
  //            null y una operación que YA era a crédito mostraba el aviso
  //            "borrala y volvé a cargarla" — un camino de corrección
  //            innecesario para una edición que el servidor acepta.
  const originalKind = useMemo<PaymentMethodKind | "none" | null>(() => {
    if (!editingOperation) return null
    if (!editingOperation.paymentMethodId) return "none"
    return paymentMethods.find((pm) => pm.id === editingOperation.paymentMethodId)?.kind ?? null
  }, [paymentMethods, editingOperation])
  const isTransitioningToCredit =
    isEdit && isCreditSelected && originalKind !== null && originalKind !== "credit"

  // Resolve selected unit from the map (O(1) vs O(n) Array.find)
  const selectedUnit = useMemo(
    () => resolveUnit(unitId, unitsById),
    [unitId, unitsById],
  )

  // ventas-unidades-conversion (D1/D5): misma derivación que POS y venta.
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

  const stagedSubtotal = useMemo(
    () => calcPurchaseSubtotal(unitCost, quantity),
    [unitCost, quantity],
  )

  // ── Option list ─────────────────────────────────────────────────────────────

  // IDs of parent catalogue entries (have at least one variant child).
  // Must NOT appear in the purchase dropdown — users must pick a specific variant.
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

  // Corrección del PR #584 (edición): una línea rehidratada no trae
  // step/minQty — se derivan de su unidad (o de la unidad base del producto)
  // con las mismas funciones que el alta. Sin esto, bajar 0,45 kg a 0,40 kg
  // en el carrito de edición lo subía en silencio a 1 (`?? 1`).
  const lineUnitOf = useCallback(
    (item: { unitId?: string; productId: string }) =>
      resolveUnit(item.unitId, unitsById) ??
      resolveUnit(productById.get(item.productId)?.baseUnitId, unitsById),
    [unitsById, productById],
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
    const qty      = unitInputMin(baseUnit)
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
                unitCost:     item.unitCost,
                subtotal:     calcPurchaseSubtotal(item.unitCost, newQty),
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
            // productos-costo-nullable (D12): este campo CAPTURA el costo que
            // se está pagando ahora, no informa el del catálogo — `?? 0` es
            // el valor inicial de un input editable, no un dato publicado.
            // Sin costo de catálogo, arranca en 0 y el usuario lo completa.
            unitCost:     product.cost ?? 0,
            quantity:     qty,
            subtotal:     calcPurchaseSubtotal(product.cost ?? 0, qty),
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
    const p = products.find((x) => x.id === id)
    // productos-costo-nullable (D12): idem arriba — captura, no informa.
    if (p) setUnitCost(p.cost ?? 0)
    // Pre-select the product's base unit so step/min are immediately correct
    const nextUnitId = p?.baseUnitId ?? ""
    setUnitId(nextUnitId)
    const nextUnit = resolveUnit(nextUnitId, unitsById)
    setQuantity(unitInputMin(nextUnit))
  }

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }
    if (unitCost <= 0) {
      toast.error("El costo unitario debe ser mayor a 0")
      return
    }

    // Existing cart item with same product AND same unit → accumulate quantities
    const existing = cartItems.find(
      (item) => item.productId === productId && (item.unitId ?? "") === unitId,
    )
    if (existing) {
      const newQty = existing.quantity + quantity
      setCartItems((prev) =>
        prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:     newQty,
                quantityBase: toBaseQuantity(newQty, selectedUnit, productBaseUnit),
                unitCost,
                subtotal:     calcPurchaseSubtotal(unitCost, newQty),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      setCartItems((prev) => [
        ...prev,
        {
          id:           crypto.randomUUID(),
          productId:    selectedProduct.id,
          productName:  getCanonicalLabel(selectedProduct, selectedProduct.parentId ? productById.get(selectedProduct.parentId) : undefined),
          unitCost,
          quantity,
          subtotal:     stagedSubtotal,
          unitId:       unitId || undefined,
          unitSymbol:   selectedUnit?.symbol,
          quantityBase: toBaseQuantity(quantity, selectedUnit, productBaseUnit),
          step:         stagedStep,
          minQty:       stagedMin,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }
    // Reset staged item
    setProductId("")
    setUnitCost(0)
    setQuantity(1)
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
        const newQty = Math.max(item.minQty ?? unitInputMin(lineUnitOf(item)), qty)
        return {
          ...item,
          quantity:     newQty,
          quantityBase: toBaseQuantity(
            newQty,
            resolveUnit(item.unitId, unitsById),
            resolveUnit(productById.get(item.productId)?.baseUnitId, unitsById),
          ),
          subtotal:     calcPurchaseSubtotal(item.unitCost, newQty),
        }
      }),
    )
  }

  // Edit the subtotal of an item already in the cart: back-compute unit cost.
  function handleUpdateSubtotal(id: string, newSubtotal: number) {
    setCartItems((prev) =>
      prev.map((item) =>
        item.id === id
          ? {
              ...item,
              unitCost: unitPriceFromSubtotal(newSubtotal, item.quantity),
              subtotal: newSubtotal,
            }
          : item,
      ),
    )
  }

  function handleCreateProduct() {
    if (!newProductName.trim() || !newProductCategoryId) {
      toast.error("Nombre y categoría son obligatorios")
      return
    }
    const margin =
      newProductPrice > 0
        ? Math.round(((newProductPrice - newProductCost) / newProductPrice) * 100)
        : 0
    addProduct({
      name:             newProductName,
      // El TEXT lo mantiene el trigger de espejo desde category_id.
      category:         "",
      categoryId:       newProductCategoryId,
      cost:             newProductCost,
      price:            newProductPrice,
      margin,
      stock:            0,
      minStock:         newProductMinStock,
      isVariant:        false,
      stockControlType: "tracked",  // explicit default — never undefined
    })
    toast.success(`Producto "${newProductName}" creado`)
    setUnitCost(newProductCost)
    setShowNewProduct(false)
    setNewProductName("")
    setNewProductCategoryId(null)
    setNewProductCost(0)
    setNewProductPrice(0)
    setNewProductMinStock(10)
  }

  // remitos-compra (tarea 4.3): el selector con alta inline vive en
  // `components/suppliers/SupplierSelect.tsx`. Elegir, limpiar y el alta inline
  // CUENTAN como "tocar" el selector (review B F2): de ahora en más supplierId
  // viaja en el payload de edición, reimputado o desimputado según lo que el
  // usuario eligió — sin esto, crear un proveedor nuevo durante la edición no lo
  // enviaría (mismo bug que dejar el selector intacto).
  function handleSupplierChange(nextSupplierId: string | null) {
    setSupplierId(nextSupplierId)
    setSupplierTouched(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }
    if (submittingRef.current) return
    submittingRef.current = true

    // ── Edit mode ─────────────────────────────────────────────────────────────
    if (isEdit && editingOperation) {
      setSubmitting(true)
      try {
        const purchaseIds = editingOperation.items.map(i => i.id)
        await updatePurchaseOperation({
          purchaseIds,
          newItems: cartItems,
          meta: {
            date,
            description,
            orgId: user?.accountId ?? "",
            // metodos-pago-operaciones (D5): ver el comentario espejo en sale-form.tsx.
            paymentMethodId,
            // edicion-preserva-contexto (F1 §D11): mismo criterio — el
            // selector siempre está montado, así que branchId viaja siempre
            // con el valor vigente del form.
            branchId,
            // review B (F2): supplierId SOLO viaja si el usuario tocó el
            // selector (o creó un proveedor inline) — a diferencia de
            // branchId/paymentMethodId de arriba. Antes se reenviaba SIEMPRE
            // el valor vigente del form, lo que rompía en silencio cuando el
            // selector no podía resolver un proveedor dado de baja
            // (supplierId prefillado pero fuera de la lista → el usuario
            // nunca lo tocó y el submit igual lo desimputaba).
            ...(supplierTouched ? { supplierId } : {}),
            // review B (FE-1/OQ-5 A): mismo patrón "tocado" para
            // costCenterId — el CostCenterSelect estaba montado sin ningún
            // efecto real en la edición.
            ...(costCenterTouched ? { costCenterId } : {}),
          },
        })
        toast.success("✅ Compra actualizada correctamente")
        await refreshData()
        onSuccess()
      } catch (err: any) {
        showOperationError("Error al actualizar: ", err.message || "Error desconocido")
      } finally {
        setSubmitting(false)
        submittingRef.current = false
      }
      return
    }

    // ── Create mode ───────────────────────────────────────────────────────────
    if (creditBlockedNoSupplier) {
      // Defensa en profundidad (task 12.5): el botón ya está deshabilitado —
      // esto cubre un submit programático. El servidor sigue siendo quien
      // decide (P0400 credit_requires_supplier).
      toast.error("Elegí un proveedor: una compra a cuenta corriente se le carga a alguien.")
      submittingRef.current = false
      return
    }
    setSubmitting(true)
    try {
      // One atomic, idempotent call for the whole cart (see SaleForm rationale).
      await addPurchaseOperation({
        items: cartItems,
        meta: {
          idempotencyKey: idempotencyKey,
          date,
          description,
          branchId,
          orgId: user?.accountId ?? "",
          costCenterId,
          paymentMethodId,
          // pos-banco-movimientos (D2): override opcional del destino del
          // egreso — null cuando el selector no está montado o el usuario
          // dejó "usar el destino configurado".
          bankAccountId: bankAccountForKind(resolvedKind, bankAccountId),
          // compras-proveedor-cuenta-corriente (D4): atributo de la
          // operación, siempre enviado (null cuando no se eligió proveedor).
          supplierId,
          // caja-compras-cobranzas (D2): sólo cuando las tres condiciones se
          // cumplen Y el usuario lo dejó tildado. En cualquier otro caso
          // viaja null y la RPC no toca caja.
          cashSessionId: checkout.cashSessionId,
        },
      })
      resetIdempotencyKey()
      toast.success(
        cartItems.length > 1
          ? `✅ Compra registrada (${cartItems.length} ítems)`
          : "✅ Compra registrada correctamente",
      )
      await refreshData()
      onSuccess()
    } catch (err: any) {
      showOperationError("Error al registrar la compra: ", err.message || "Error desconocido")
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
      <ScrollableCartShell
        hasItems={cartItems.length > 0}

        // ── Scrollable cart list ─────────────────────────────────────────
        listContent={
          <CartItemList
            items={cartItems.map((item) => ({
              id:          item.id,
              productName: item.productName,
              quantity:    item.quantity,
              unitValue:   item.unitCost,
              subtotal:    item.subtotal,
              step:        item.step ?? unitInputStep(lineUnitOf(item)),
              minQty:      item.minQty ?? unitInputMin(lineUnitOf(item)),
              badge:       item.unitSymbol ?? lineUnitOf(item)?.symbol,
            }))}
            onRemove={handleRemoveItem}
            onUpdateQty={handleUpdateQty}
            onUpdateSubtotal={handleUpdateSubtotal}
            unitLabel="Costo unit."
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
                    {formatMoney(cartTotal)}
                  </span>
                </div>
              </div>
            )}

            <Button
              type="submit"
              className="w-full"
              disabled={submitting || cartItems.length === 0 || submitBlockedNoSupplier}
            >
              {submitting
                ? isEdit ? "Guardando..." : "Registrando..."
                : isEdit
                ? `Guardar cambios (${cartItems.length} ítem${cartItems.length !== 1 ? "s" : ""})`
                : cartItems.length > 1
                ? `Confirmar compra (${cartItems.length} ítems)`
                : "Confirmar compra"}
            </Button>
          </>
        }
      >
        {/* ── HEADER: Fecha + Notas + campos de cierre ───────────────────── */}
        {/* Moved to top so meta-info is set before adding items (UX parity with SaleForm).
            remitos-compra (tanda B, 7.3): fecha, centro de costo, forma de pago, cuenta
            bancaria, opt-in de caja y bloque de cuenta corriente son `PurchaseCheckoutFields`
            (compartido con la conversión de un remito); las notas y la sucursal no forman
            parte de los campos de cierre y entran como celdas de la misma grilla
            (`afterDate`), y el selector de proveedor va entre la caja y la cuenta corriente
            (`beforeCredit`). */}
        <PurchaseCheckoutFields
          checkout={checkout}
          mode={isEdit ? "edit" : "create"}
          date={date}
          onDateChange={setDate}
          costCenterId={costCenterId}
          onCostCenterChange={handleCostCenterChange}
          paymentMethodId={paymentMethodId}
          onPaymentMethodChange={handlePaymentMethodChange}
          bankAccountId={bankAccountId}
          onBankAccountChange={setBankAccountId}
          isTransitioningToCredit={isTransitioningToCredit}
          afterDate={
            <>
              <div className="flex flex-col gap-2">
                <Label className="text-foreground">Notas (opcional)</Label>
                <Input
                  selectOnFocus
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="Ej: Lote Dic 2026"
                  className="bg-background border-border text-foreground"
                />
              </div>

              {/* ── Sucursal (solo plan PRO) ───────────────────────────────── */}
              {/* compras-gastos-sucursal-por-defecto (D9): sin «Sin sucursal (general)»: se ve la
                  sucursal PRINCIPAL ya elegida, rotulada «Nombre (principal)», con el rótulo
                  «Sucursal» dentro del selector (desaparece junto con él en las cuentas sin el
                  módulo de sucursales). El estado sigue en `null` hasta que se elige otra: viaja
                  `null` y el SERVIDOR resuelve la principal con datos vivos (la RPC guarda la
                  sucursal que mueve el stock, la caja y el banco). Para el opt-in de caja
                  `useCashOptin` ya ofrece la sesión de esa misma principal. El selector de
                  sucursal no forma parte de `PurchaseCheckoutFields`: se mantiene acá con
                  `allowUnassigned={false}` y el `label`. */}
              {/* En móvil (375 px) la mitad de la fila trunca «Casa Central (principal)» y la marca
                  «(principal)» —lo que el usuario necesita ver— se pierde: el selector ocupa la fila
                  entera (`col-span-2`) y vuelve a media columna desde `sm`. `empty:hidden` evita una
                  celda vacía en las cuentas sin el módulo (el selector no renderiza nada). */}
              <div className="col-span-2 sm:col-span-1 empty:hidden">
                <BranchSelect
                  value={branchId}
                  onChange={setBranchId}
                  allowUnassigned={false}
                  label="Sucursal"
                  className="bg-background border-border text-foreground text-sm"
                />
              </div>
            </>
          }
          beforeCredit={
            <>
              {/* ── Proveedor (compras-proveedor-cuenta-corriente D10) ────────────
                  Combobox buscable + alta inline: `SupplierSelect` (compartido con el
                  remito de compra). El aviso explica por qué el selector cae al
                  placeholder cuando supplierId no resuelve en la lista (proveedor
                  dado de baja). */}
              <SupplierSelect
                value={supplierId}
                onChange={handleSupplierChange}
                labelId="purchase-supplier-label"
                unresolvedHint={supplierUnresolved ? "Proveedor actual no disponible (dado de baja)" : null}
              />
            </>
          }
        />

        <div className="border-t border-border" />

        {/* ── HEADER: Product Adder ────────────────────────────────────── */}
        <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
          <div className="flex items-center justify-between">
            <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
              <PackagePlus className="h-3.5 w-3.5" />
              Agregar producto
            </Label>
            <div className="flex items-center gap-2">
              <BarcodeScannerInput onScan={handleBarcodeScan} />
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-6 text-xs text-primary"
                onClick={() => setShowNewProduct(!showNewProduct)}
              >
                <Plus className="h-3 w-3 mr-1" />
                {showNewProduct ? "Cancelar" : "Nuevo producto"}
              </Button>
            </div>
          </div>

          {showNewProduct ? (
            <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
              <Input
                selectOnFocus
                value={newProductName}
                onChange={(e) => setNewProductName(e.target.value)}
                placeholder="Nombre del producto"
                className="bg-background border-border text-foreground text-sm"
              />
              {/* productos-categorias-sku: el MISMO selector que el formulario de
                  producto — catálogo de la cuenta + alta inline en el lugar (D9),
                  sin diálogo anidado sobre el diálogo de compra. */}
              <ProductCategorySelect
                value={newProductCategoryId}
                onChange={setNewProductCategoryId}
                showLabel={false}
                placeholder="Categoría"
                className="bg-background border-border text-foreground text-sm"
              />
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Costo</Label>
                  <NumericInput
                    min={0}
                    value={newProductCost}
                    onValueChange={setNewProductCost}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Precio venta</Label>
                  <NumericInput
                    min={0}
                    value={newProductPrice}
                    onValueChange={setNewProductPrice}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Stock mín.</Label>
                  <NumericInput
                    min={0}
                    value={newProductMinStock}
                    onValueChange={setNewProductMinStock}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
              </div>
              <Button
                type="button"
                size="sm"
                variant="secondary"
                onClick={handleCreateProduct}
                className="w-full"
              >
                <Plus className="h-3 w-3 mr-1" />
                Crear y seleccionar
              </Button>
            </div>
          ) : (
            <ProductPicker
              products={products}
              productById={productById}
              unitsById={unitsById}
              value={productId}
              onValueChange={handleProductChange}
            />
          )}

          {selectedProduct && !showNewProduct && (
            <div className="flex flex-col gap-2">
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
                      // Contrato D-F (precio por unidad de la LÍNEA): el precio
                      // se re-expresa con el mismo factor que la cantidad —
                      // 100 g a $1.800/kg cobran $180, no $180.000.
                      setUnitCost((prev) => convertUnitPrice(prev, selectedUnit, nextUnit, productBaseUnit))
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
              {/* Row 2: Costo unitario + Subtotal */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Costo unitario</Label>
                  <NumericInput
                    min={0}
                    step={0.01}
                    value={unitCost}
                    onValueChange={setUnitCost}
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
                      // Fijar el costo efectivo a partir del subtotal tipeado.
                      setUnitCost(unitPriceFromSubtotal(val, quantity))
                    }}
                    className="bg-background border-border text-right font-bold text-cyan-400"
                  />
                </div>
              </div>
            </div>
          )}

          <Button
            type="button"
            variant="secondary"
            onClick={handleAddToCart}
            disabled={!selectedProduct || showNewProduct}
            className="w-full gap-2"
          >
            <Plus className="h-4 w-4" />
            Agregar al carrito
          </Button>
        </div>
      </ScrollableCartShell>
    </form>
  )
}
