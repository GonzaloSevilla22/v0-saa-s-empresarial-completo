"use client"

/**
 * remitos-venta (D5/D11, tareas 5.1/5.2) y remitos-compra (D11, tareas 5.1/5.2) —
 * formulario de alta y edición de un remito, de VENTA o de COMPRA.
 *
 * El sentido (`direction`, default `"sale"`) cambia la contraparte, el sentido del
 * stock y la fuente del precio, y nada más: es el mismo editor de líneas.
 *
 *  - **Compra**: el proveedor (`SupplierSelect` con alta inline y teléfono
 *    opcional) es obligatorio y el remito lleva el N° del remito del proveedor; no
 *    hay domicilio. La sucursal es la de DESTINO ("Ingresa a"): recibir SUMA, así
 *    que no hay faltante que controlar en el alta. La línea nace con el COSTO del
 *    catálogo (`priceSource: "cost"`), sin descuento, y precio 0 se admite (avisa
 *    "Sin precio": la conversión en compra lo exigirá). En la edición, bajar una
 *    cantidad RESTA del stock lo aportado, así que cada producto tiene un MÍNIMO
 *    (`max(0, aportado − stock vigente)`) y mover la recepción exige que la
 *    sucursal vieja siga teniendo todo lo aportado; el servidor lo vuelve a
 *    rechazar con `delivery_note_stock_consumed`.
 *  - **Venta**: lo de abajo, sin cambios.
 *
 * Se arma con las piezas compartidas del carrito (`StagedProductLine`,
 * `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput`, `BranchSelect`)
 * y NO lleva lógica de carrito propia: el alta manual y el despacho de un código
 * viven en `lib/cart-utils`; la contabilidad de stock del remito, en
 * `lib/delivery-note-stock`; la rehidratación, el payload y las reglas, en
 * `lib/delivery-note-form`. La diferencia con el presupuesto es que el remito
 * MUEVE STOCK al emitirse y al editarse:
 *
 *  - **Sucursal obligatoria y visible en todos los planes.** De ahí sale la
 *    mercadería. Con una sola sucursal operativa se muestra como texto ("Sale
 *    de: Centro"); mientras no haya sucursal elegida no se agregan líneas.
 *  - **El stock que manda es el de la sucursal elegida**, nunca el agregado
 *    `product.stock` del catálogo: `availableFor` (4.6) reemplaza al agregado en
 *    el alta manual, el escaneo y el tope de cada input de cantidad.
 *  - **Una sola contabilidad en la edición**: disponible = stock de la sucursal
 *    + lo que el remito ya retiene en ella (cero si se cambia de sucursal). Las
 *    líneas rehidratadas NO llevan `source: "persisted"`: todas cuentan.
 *  - **Aviso del efecto en el stock**: "Al emitir, se descuenta del stock de …"
 *    en el alta; en la edición, qué vuelve y qué sale ("Este cambio no mueve
 *    stock" si sólo cambian datos).
 *  - **Edición**: reemplazo completo con la `revision` que se cargó; si otro
 *    usuario lo modificó, `delivery_note_changed` ofrece recargar sin pisarlo.
 *  - **Cliente dado de baja**: se muestra el cliente congelado con el aviso y el
 *    guardado queda bloqueado hasta elegir uno vigente.
 *  - **Producto dado de baja**: la línea se conserva ("se conserva lo
 *    entregado"), no bloquea el guardado, no admite aumentar y quitarla pide
 *    confirmación con lo que vuelve al stock.
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import { useQueryClient } from "@tanstack/react-query"
import { AlertTriangle, PackageMinus, RefreshCw, ShoppingCart, UserPlus } from "lucide-react"
import { toast } from "sonner"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { Textarea } from "@/components/ui/textarea"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { ClientForm } from "@/components/forms/client-form"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { CartItemList, type CartDisplayItem } from "@/components/shared/cart-item-list"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { StagedProductLine, type StagedProductLineHandle } from "@/components/shared/StagedProductLine"
import { SupplierSelect } from "@/components/suppliers/SupplierSelect"
import { useBranchStock } from "@/hooks/data/use-branch-stock"
import { useBranches } from "@/hooks/data/use-branches"
import { useClientAddresses } from "@/hooks/data/use-client-addresses"
import { useClients } from "@/hooks/data/use-clients"
import { useCreateDeliveryNote, useUpdateDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useProducts } from "@/hooks/data/use-products"
import { useScaleSettings } from "@/hooks/data/use-scale-settings"
import type { ScanFeedback } from "@/hooks/use-barcode-scanner"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { operativeBranches, pickOldestOperativeBranchId } from "@/lib/branch-selection"
import {
  addManualLineToCart,
  applyScanToCart,
  calcCartTotal,
  linesExceedingAvailable,
  maxQuantityPerLine,
  removeLine,
  unitPriceFromSubtotal,
  updateLineQuantity,
  updateLineSubtotal,
  type SaleCartItem,
  type StagedCartLine,
} from "@/lib/cart-utils"
import { primaryDeliveryAddress } from "@/lib/client-address"
import {
  buildDeliveryNoteItemsPayload,
  DELIVERY_NOTE_ADDRESS_MAX,
  DELIVERY_NOTE_NOTES_MAX,
  DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX,
  describeMissingPrices,
  missingPriceLineCount,
  rehydrateDeliveryNoteLines,
  validateDeliveryNoteDraft,
} from "@/lib/delivery-note-form"
import { DELIVERY_NOTE_TEXTS } from "@/lib/delivery-note-status"
import {
  computeStockAdjustment,
  deliveryNoteAvailableFor,
  describeEmitNotice,
  describePurchaseBranchMove,
  describePurchaseMinimum,
  describeRemovalReturn,
  describeStockAdjustment,
  heldByProduct,
  purchaseBranchMoveBlockers,
  purchaseLinesBelowMinimum,
  purchaseMinimumByProduct,
} from "@/lib/delivery-note-stock"
import type { DeliveryNoteApiRow, DeliveryNoteDirection } from "@/lib/delivery-note-types"
import { formatMoney } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { queryKeys } from "@/lib/query-keys"
import { resolveScan } from "@/lib/scan-resolution"
import { resolveUnit, unitInputMin, unitInputStep } from "@/lib/unit-utils"
import type { Client } from "@/lib/types"

const DELETED_PRODUCT_BADGE: Record<DeliveryNoteDirection, string> = {
  sale: "Producto dado de baja — se conserva lo entregado",
  purchase: "Producto dado de baja — se conserva lo recibido",
}
const EXCEEDS_BADGE = "No alcanza el stock"
const NO_PRICE_BADGE = "Sin precio"

export interface DeliveryNoteFormProps {
  /** Edita este remito pendiente (reemplazo completo, con su `revision`); su `direction` manda. */
  deliveryNote?: DeliveryNoteApiRow
  /** Sentido del alta (en una edición sale del remito). Default `"sale"`. */
  direction?: DeliveryNoteDirection
  /** Cliente preseleccionado (`?cliente=`). */
  initialClientId?: string
  /** Proveedor preseleccionado (`?proveedor=`), sólo en compra. */
  initialSupplierId?: string
  /** Qué hacer con "Recargar" ante `delivery_note_changed`; por defecto invalida el detalle. */
  onReload?: () => void
}

/** Un rechazo de stock que se muestra de forma persistente, con la salida accionable. */
interface StockBlock {
  message: string
  /** `/stock?product=<id>`, si se sabe de qué producto se trata. */
  href: string | null
  /** Rótulo accesible del aviso (default: el rechazo de stock de la venta). */
  label?: string
  /** Rótulo del enlace (default: "Transferir stock"; en compra, "Ajustar stock"). */
  linkLabel?: string
}

export function DeliveryNoteForm({
  deliveryNote,
  direction: directionProp,
  initialClientId,
  initialSupplierId,
  onReload,
}: DeliveryNoteFormProps) {
  const direction: DeliveryNoteDirection = deliveryNote?.direction ?? directionProp ?? "sale"
  const isPurchase = direction === "purchase"
  const texts = DELIVERY_NOTE_TEXTS[direction]
  const router = useRouter()
  const queryClient = useQueryClient()
  const uid = useId()
  const { products } = useProducts()
  const { clients } = useClients()
  const { units, unitsById } = useUnitsOfMeasure()
  const { settings: scaleSettings } = useScaleSettings()
  const { branches } = useBranches()
  const createDeliveryNote = useCreateDeliveryNote(direction)
  const updateDeliveryNote = useUpdateDeliveryNote()

  const isEdit = !!deliveryNote
  const productById = useMemo(() => new Map(products.map((p) => [p.id, p])), [products])
  const cartCtx = useMemo(() => ({ unitsById, products }), [unitsById, products])

  // ── Estado inicial: una sola rehidratación, al montar ────────────────────────
  const initial = useMemo(
    () =>
      deliveryNote
        ? rehydrateDeliveryNoteLines(deliveryNote.items, { unitsById, products })
        : { cartItems: [] as SaleCartItem[], deletedLineIds: [] as string[], deletedProductIds: [] as string[] },
    // Se calcula UNA vez: el estado del formulario es del usuario desde ahí.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )
  const [cartItems, setCartItems] = useState<SaleCartItem[]>(initial.cartItems)
  const deletedLineIds = useMemo(() => new Set(initial.deletedLineIds), [initial.deletedLineIds])
  const deletedProductIds = useMemo(() => new Set(initial.deletedProductIds), [initial.deletedProductIds])

  const [clientId, setClientId] = useState<string>(deliveryNote?.client_id ?? initialClientId ?? "")
  const [supplierId, setSupplierId] = useState<string>(deliveryNote?.supplier_id ?? initialSupplierId ?? "")
  const [supplierReference, setSupplierReference] = useState<string>(deliveryNote?.supplier_reference ?? "")
  const [createdClient, setCreatedClient] = useState<Client | null>(null)
  const [showNewClient, setShowNewClient] = useState(false)
  // `undefined`: el usuario todavía no eligió; vale la sucursal por defecto.
  const [branchChoice, setBranchChoice] = useState<string | null | undefined>(
    deliveryNote ? deliveryNote.branch_id : undefined,
  )
  const [address, setAddress] = useState<string>(deliveryNote?.delivery_address ?? "")
  const addressTouched = useRef(!!deliveryNote?.delivery_address)
  const [notes, setNotes] = useState<string>(deliveryNote?.notes ?? "")
  const [stockBlock, setStockBlock] = useState<StockBlock | null>(null)
  const [conflict, setConflict] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [pendingRemoveId, setPendingRemoveId] = useState<string | null>(null)
  const submittingRef = useRef(false)

  const stagedRef = useRef<StagedProductLineHandle>(null)
  const formRef = useRef<HTMLFormElement>(null)

  // ── Sucursal ─────────────────────────────────────────────────────────────────
  const operative = useMemo(() => operativeBranches(branches), [branches])
  const defaultBranchId = useMemo(() => pickOldestOperativeBranchId(branches), [branches])
  const branchId: string | null = branchChoice !== undefined ? branchChoice : defaultBranchId
  const savedBranchId = deliveryNote?.branch_id ?? null

  const branchNameOf = useCallback(
    (id: string): string =>
      branches.find((b) => b.id === id)?.name ?? (id === savedBranchId ? deliveryNote?.branch_name : null) ?? "la sucursal",
    [branches, savedBranchId, deliveryNote?.branch_name],
  )
  const branchName = branchId ? branchNameOf(branchId) : ""
  const showBranchAsText = operative.length === 1 && branchId === operative[0].id
  const noOperativeBranch = !isEdit && operative.length === 0

  // ── Stock de la sucursal (nunca el agregado del catálogo) ────────────────────
  // Venta: el de la sucursal ELEGIDA (de ahí sale la mercadería). Compra: el de la
  // sucursal GUARDADA, que es la que recibió lo aportado (alimenta el mínimo por
  // producto y el bloqueo de mover la recepción); en un alta no hay nada que leer.
  const stockBranchId = isPurchase ? savedBranchId : branchId
  const { branchStock, isLoading: stockLoading } = useBranchStock(stockBranchId ?? "")
  const branchStockById = useMemo(() => new Map(branchStock.map((row) => [row.productId, row.quantity])), [branchStock])
  const held = useMemo(() => heldByProduct(deliveryNote?.items ?? []), [deliveryNote?.items])

  // Sólo la venta controla faltante: en compra entra mercadería.
  const availableFor = useMemo(() => {
    const base = deliveryNoteAvailableFor({
      branchStockOf: (productId) => branchStockById.get(productId) ?? 0,
      held,
      savedBranchId,
      chosenBranchId: branchId,
    })
    // Un producto dado de baja no puede aumentar: su tope es lo que ya se entregó.
    return (productId: string): number =>
      deletedProductIds.has(productId) ? Math.min(base(productId), held.get(productId) ?? 0) : base(productId)
  }, [branchStockById, held, savedBranchId, branchId, deletedProductIds])

  // ── Cliente ──────────────────────────────────────────────────────────────────
  const clientDeleted = !!deliveryNote?.client_deleted && clientId === deliveryNote.client_id

  const clientOptions = useMemo(() => {
    const options = clients.map((c) => ({ value: c.id, label: c.name }))
    const extras: { value: string; label: string }[] = []
    if (createdClient && !options.some((o) => o.value === createdClient.id)) {
      extras.push({ value: createdClient.id, label: createdClient.name })
    }
    if (deliveryNote?.client_id && deliveryNote.client_name && !options.some((o) => o.value === deliveryNote.client_id)) {
      extras.push({
        value: deliveryNote.client_id,
        label: deliveryNote.client_deleted ? `${deliveryNote.client_name} (dado de baja)` : deliveryNote.client_name,
      })
    }
    return [...extras, ...options]
  }, [clients, createdClient, deliveryNote?.client_id, deliveryNote?.client_name, deliveryNote?.client_deleted])

  // ── Proveedor (compra): el congelado de un remito ya recibido se ve hasta elegir otro ─
  const supplierDeleted = isPurchase && !!deliveryNote?.supplier_deleted && supplierId === deliveryNote.supplier_id
  const frozenSupplier = useMemo(
    () =>
      isPurchase && deliveryNote?.supplier_deleted && deliveryNote.supplier_id
        ? {
            value: deliveryNote.supplier_id,
            label: `${deliveryNote.supplier_name ?? "Proveedor"} (dado de baja)`,
          }
        : null,
    [isPurchase, deliveryNote?.supplier_deleted, deliveryNote?.supplier_id, deliveryNote?.supplier_name],
  )

  // ── Domicilio de entrega (venta): se precarga con el principal del cliente ───
  const { data: addresses } = useClientAddresses(isPurchase ? null : clientId || null)
  const prefilledAddress = useMemo(() => primaryDeliveryAddress(addresses), [addresses])
  useEffect(() => {
    if (isPurchase || addressTouched.current || !clientId) return
    setAddress(prefilledAddress)
  }, [isPurchase, clientId, prefilledAddress])

  // ── Carrito ──────────────────────────────────────────────────────────────────
  const total = useMemo(() => calcCartTotal(cartItems), [cartItems])
  // Venta: el tope de cada input es el disponible. Compra: no hay tope, salvo un
  // producto dado de baja, que no puede aumentar (su tope es lo que ya se recibió).
  const maxQtyMap = useMemo(() => {
    if (!isPurchase) return maxQuantityPerLine(cartItems, availableFor, cartCtx)
    const deletedLines = cartItems.filter((item) => deletedProductIds.has(item.productId))
    return maxQuantityPerLine(deletedLines, (productId) => held.get(productId) ?? 0, cartCtx)
  }, [isPurchase, cartItems, availableFor, cartCtx, deletedProductIds, held])
  const exceedingIds = useMemo(
    () => (branchId && !isPurchase ? new Set(linesExceedingAvailable(cartItems, availableFor)) : new Set<string>()),
    [cartItems, availableFor, branchId, isPurchase],
  )
  const exceedingNames = useMemo(
    () => [...new Set(cartItems.filter((item) => exceedingIds.has(item.id)).map((item) => item.productName))],
    [cartItems, exceedingIds],
  )

  const baseUnitOf = useCallback(
    (productId: string) => resolveUnit(productById.get(productId)?.baseUnitId, unitsById),
    [productById, unitsById],
  )

  // ── Edición de compra: mínimo por producto y mover la recepción ───────────────
  const savedStockOf = useCallback((productId: string) => branchStockById.get(productId) ?? 0, [branchStockById])
  const purchaseEdit = isPurchase && isEdit && !stockLoading
  const branchMoved = branchId !== null && branchId !== savedBranchId
  // Sin mover de sucursal, cada producto no puede bajar de `aportado − stock vigente`; al mover,
  // la vieja resta TODO lo aportado (los bloqueos de abajo) y las líneas nuevas no tienen mínimo.
  const minimums = useMemo(
    () =>
      purchaseEdit && !branchMoved && deliveryNote
        ? purchaseMinimumByProduct({ savedItems: deliveryNote.items, savedBranchStockOf: savedStockOf })
        : new Map<string, number>(),
    [purchaseEdit, branchMoved, deliveryNote, savedStockOf],
  )
  const moveBlockMessages = useMemo(
    () =>
      purchaseEdit && branchMoved && deliveryNote && savedBranchId
        ? purchaseBranchMoveBlockers({ savedItems: deliveryNote.items, savedBranchStockOf: savedStockOf }).map((blocker) =>
            describePurchaseBranchMove(blocker, branchNameOf(savedBranchId), baseUnitOf(blocker.productId)),
          )
        : [],
    [purchaseEdit, branchMoved, deliveryNote, savedBranchId, savedStockOf, branchNameOf, baseUnitOf],
  )
  const belowMinimum = useMemo(
    () =>
      minimums.size > 0 && deliveryNote
        ? purchaseLinesBelowMinimum({ savedItems: deliveryNote.items, minimums, nextLines: cartItems })
        : [],
    [minimums, deliveryNote, cartItems],
  )
  const missingPricesNotice = useMemo(
    () => (isPurchase ? describeMissingPrices(missingPriceLineCount(cartItems)) : null),
    [isPurchase, cartItems],
  )

  // Compra: entra mercadería (sin control de faltante) y la línea nace con el costo.
  const cartOptions = useMemo(
    () =>
      isPurchase
        ? ({ enforceStock: false, priceSource: "cost" } as const)
        : ({ enforceStock: true, availableFor } as const),
    [isPurchase, availableFor],
  )

  function rejectWithoutBranch(): void {
    toast.error(
      isPurchase
        ? "Elegí la sucursal a la que entra la mercadería antes de agregar productos."
        : "Elegí la sucursal de la que sale la mercadería antes de agregar productos.",
    )
  }

  function stockBlockFor(productId: string | null, productName: string, warning: string): StockBlock {
    return {
      message:
        `«${productName}»: ${warning} en ${branchName}. ` +
        "Puede haber unidades en otra sucursal: transferilas o elegí otra sucursal.",
      href: productId ? `/stock?product=${encodeURIComponent(productId)}` : null,
    }
  }

  function handleAddStaged(staged: StagedCartLine): boolean {
    if (!branchId) {
      rejectWithoutBranch()
      return false
    }
    if (stockLoading && !isPurchase) {
      toast.info("Estamos cargando el stock de la sucursal: probá de nuevo en un instante.")
      return false
    }
    const result = addManualLineToCart(cartItems, staged, cartCtx, cartOptions)
    if (!result.ok) {
      setStockBlock(stockBlockFor(staged.product.id, staged.product.name, result.message))
      return false
    }
    setCartItems(result.items)
    setStockBlock(null)
    toast.success(result.merged ? `Cantidad actualizada: ${result.productName}` : `${result.productName} agregado`)
    return true
  }

  function handleScan(code: string): ScanFeedback {
    if (!branchId) return { ok: false, label: "Elegí la sucursal antes de escanear" }
    const scan = resolveScan(code, { products, units, unitsById, settings: scaleSettings })
    const result = applyScanToCart(cartItems, scan, cartCtx, cartOptions)
    if (result.kind === "rejected") {
      if (/stock insuficiente/i.test(result.label)) {
        setStockBlock({
          message: `${result.label} en ${branchName}. Puede haber unidades en otra sucursal: transferilas o elegí otra sucursal.`,
          href: null,
        })
      }
      return { ok: false, label: result.label }
    }
    if (result.kind === "needs_quantity") {
      // Producto medible por código común/SKU: queda elegido con el foco en la cantidad.
      stagedRef.current?.selectProduct(result.product.id)
      return { ok: true, label: result.label }
    }
    setCartItems(result.items)
    setStockBlock(null)
    return { ok: true, label: result.label }
  }

  function handleRemove(id: string) {
    // Quitar la línea de un producto dado de baja devuelve al stock lo entregado: se confirma.
    if (deletedLineIds.has(id)) {
      setPendingRemoveId(id)
      return
    }
    setCartItems((prev) => removeLine(prev, id))
  }

  function confirmRemove() {
    if (pendingRemoveId) setCartItems((prev) => removeLine(prev, pendingRemoveId))
    setPendingRemoveId(null)
  }

  function handleUpdateQty(id: string, quantity: number) {
    setCartItems((prev) => updateLineQuantity(prev, id, quantity, cartCtx))
  }

  function handleUpdateSubtotal(id: string, subtotal: number) {
    setCartItems((prev) => updateLineSubtotal(prev, id, subtotal))
  }

  function handleBranchChange(next: string | null) {
    setBranchChoice(next)
    setStockBlock(null)
  }

  // ── Lista que muestra el carrito ─────────────────────────────────────────────
  const displayItems = useMemo<CartDisplayItem[]>(
    () =>
      cartItems.map((line): CartDisplayItem => {
        const lineUnit = resolveUnit(line.unitId, unitsById)
        return {
          id: line.id,
          productName: line.productName,
          quantity: line.quantity,
          unitValue: line.unitPrice,
          subtotal: line.subtotal,
          step: line.step ?? unitInputStep(lineUnit),
          minQty: line.minQty ?? unitInputMin(lineUnit),
          badge:
            [
              deletedLineIds.has(line.id) ? DELETED_PRODUCT_BADGE[direction] : null,
              exceedingIds.has(line.id) ? EXCEEDS_BADGE : null,
              line.unitSymbol ?? lineUnit?.symbol ?? null,
              line.discount > 0 ? `${line.discount}% desc.` : null,
              isPurchase && line.subtotal === 0 ? NO_PRICE_BADGE : null,
              minimums.has(line.productId)
                ? describePurchaseMinimum(
                    minimums.get(line.productId) ?? 0,
                    savedStockOf(line.productId),
                    branchNameOf(savedBranchId ?? ""),
                    baseUnitOf(line.productId),
                  )
                : null,
            ]
              .filter(Boolean)
              .join(" · ") || undefined,
        }
      }),
    [
      cartItems,
      unitsById,
      deletedLineIds,
      exceedingIds,
      direction,
      isPurchase,
      minimums,
      savedStockOf,
      savedBranchId,
      branchNameOf,
      baseUnitOf,
    ],
  )

  // ── Efecto en el stock (alta: aviso fijo; edición: lo que vuelve y lo que sale) ─
  const stockEffect = useMemo<string | null>(() => {
    if (!branchId) return null
    if (!deliveryNote) return describeEmitNotice(branchName, direction)
    const adjustments = computeStockAdjustment({
      savedItems: deliveryNote.items,
      savedBranchId: deliveryNote.branch_id,
      nextLines: cartItems,
      nextBranchId: branchId,
    })
    return describeStockAdjustment(adjustments, branchNameOf, baseUnitOf, direction)
  }, [branchId, branchName, deliveryNote, cartItems, branchNameOf, baseUnitOf, direction])

  // ── Envío ────────────────────────────────────────────────────────────────────
  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault()
    if (submittingRef.current) return

    const problem = validateDeliveryNoteDraft({
      direction,
      clientId,
      clientDeleted,
      supplierId,
      supplierDeleted,
      supplierReference,
      branchId,
      branchName,
      itemCount: cartItems.length,
      exceeding: exceedingNames,
      belowMinimum,
      address,
      notes,
    })
    if (problem || !branchId) {
      toast.error(
        problem ??
          (isPurchase
            ? "Elegí la sucursal a la que entra la mercadería."
            : "Elegí la sucursal de la que sale la mercadería."),
      )
      return
    }
    if (moveBlockMessages.length > 0) {
      toast.error(moveBlockMessages[0])
      return
    }

    submittingRef.current = true
    setSubmitting(true)
    setConflict(false)
    const items = buildDeliveryNoteItemsPayload(cartItems)
    const trimmedAddress = address.trim() || null
    const trimmedNotes = notes.trim() || null
    const trimmedReference = supplierReference.trim() || null
    try {
      if (deliveryNote) {
        await updateDeliveryNote.mutateAsync({
          deliveryNoteId: deliveryNote.id,
          payload: isPurchase
            ? {
                direction: "purchase",
                revision: deliveryNote.revision,
                supplier_id: supplierId,
                branch_id: branchId,
                supplier_reference: trimmedReference,
                notes: trimmedNotes,
                items,
              }
            : {
                revision: deliveryNote.revision,
                client_id: clientId,
                branch_id: branchId,
                delivery_address: trimmedAddress,
                notes: trimmedNotes,
                items,
              },
        })
        toast.success("Remito actualizado")
        router.push(`/remitos/${deliveryNote.id}`)
        return
      }
      const created = await createDeliveryNote.mutateAsync(
        isPurchase
          ? {
              direction: "purchase",
              supplier_id: supplierId,
              branch_id: branchId,
              supplier_reference: trimmedReference,
              notes: trimmedNotes,
              items,
            }
          : {
              direction: "sale",
              client_id: clientId,
              branch_id: branchId,
              delivery_address: trimmedAddress,
              notes: trimmedNotes,
              items,
            },
      )
      toast.success(texts.emitToast(created.number_label, branchName))
      router.push(`/remitos/${created.id}`)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : ""
      if (/delivery_note_changed/.test(message)) {
        setConflict(true)
        return
      }
      const lookupName = (productId: string) => cartItems.find((i) => i.productId === productId)?.productName
      const humanized = humanizeOperationError(message, lookupName, branchName, { documentLabel: "remito", direction })
      if (humanized.action && isPurchase) {
        // Compra: lo que el servidor rechaza es restar mercadería que ya no está. El aviso se
        // queda en pantalla con la salida ("Ajustar stock"), no es un faltante transferible.
        setStockBlock({
          message: humanized.message,
          href: humanized.action.href,
          label: "Mercadería consumida",
          linkLabel: humanized.action.label,
        })
      } else if (humanized.action) {
        setStockBlock({ message: humanized.message, href: humanized.action.href })
      } else {
        toast.error(humanized.message)
      }
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  function handleReload() {
    if (onReload) {
      onReload()
      return
    }
    if (deliveryNote) queryClient.invalidateQueries({ queryKey: queryKeys.deliveryNotes.detail(deliveryNote.id) })
  }

  const itemCount = cartItems.length
  const addressId = `${uid}-address`
  const referenceId = `${uid}-supplier-reference`
  const notesId = `${uid}-notes`
  const submitLabel = submitting
    ? isEdit
      ? "Guardando…"
      : "Emitiendo…"
    : isEdit
      ? "Guardar cambios"
      : itemCount > 1
        ? `Emitir remito (${itemCount} ítems)`
        : "Emitir remito"
  const pendingRemoveLine = pendingRemoveId ? cartItems.find((item) => item.id === pendingRemoveId) : undefined

  return (
    <>
      <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4" noValidate>
        {conflict && (
          <div
            role="alert"
            aria-label="Remito modificado"
            className="flex flex-col gap-2 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground sm:flex-row sm:items-center sm:justify-between"
          >
            <p className="flex items-start gap-2">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
              <span>
                Otro usuario modificó este remito mientras lo editabas. Recargalo para ver cómo quedó y volvé a aplicar
                tus cambios: no pisamos lo que cambió.
              </span>
            </p>
            <Button type="button" size="sm" variant="outline" onClick={handleReload} className="gap-1.5 shrink-0">
              <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />
              Recargar remito
            </Button>
          </div>
        )}

        {supplierDeleted && (
          <p
            role="status"
            aria-label="Proveedor dado de baja"
            className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
          >
            Proveedor dado de baja — elegí uno vigente para guardar. El remito sigue a nombre de{" "}
            <span className="font-medium">{deliveryNote?.supplier_name ?? "un proveedor que ya no existe"}</span>.
          </p>
        )}

        {clientDeleted && (
          <p
            role="status"
            aria-label="Cliente dado de baja"
            className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
          >
            Cliente dado de baja — elegí uno vigente para guardar. El remito sigue a nombre de{" "}
            <span className="font-medium">{deliveryNote?.client_name ?? "un cliente que ya no existe"}</span>.
          </p>
        )}

        {noOperativeBranch && (
          <p
            role="alert"
            aria-label="Sin sucursal operativa"
            className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive"
          >
            {isPurchase
              ? "No hay ninguna sucursal activa a la que pueda ingresar la mercadería. Activá o creá una sucursal en"
              : "No hay ninguna sucursal activa de la que pueda salir la mercadería. Activá o creá una sucursal en"}{" "}
            <Link href="/sucursales" className="underline underline-offset-2">
              Sucursales
            </Link>{" "}
            para {isPurchase ? "recibir" : "emitir"} remitos.
          </p>
        )}

        <ScrollableCartShell
          className="max-h-[calc(100dvh-11rem)] sm:max-h-[calc(100dvh-12rem)]"
          hasItems={displayItems.length > 0}
          listContent={
            <CartItemList
              items={displayItems}
              onRemove={handleRemove}
              onUpdateQty={handleUpdateQty}
              onUpdateSubtotal={handleUpdateSubtotal}
              unitLabel="Precio unit."
              currency="ARS"
              maxQtyMap={maxQtyMap}
            />
          }
          footerContent={
            <>
              {stockBlock && (
                <div
                  role="alert"
                  aria-label={stockBlock.label ?? "Stock insuficiente"}
                  className="flex flex-col gap-2 rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-foreground"
                >
                  <p>{stockBlock.message}</p>
                  {stockBlock.href && (
                    <Link
                      href={stockBlock.href}
                      className="inline-flex items-center gap-1 self-start font-medium text-primary underline-offset-2 hover:underline"
                    >
                      <PackageMinus className="h-3.5 w-3.5" aria-hidden="true" />
                      {stockBlock.linkLabel ?? "Transferir stock"}
                    </Link>
                  )}
                </div>
              )}
              {exceedingNames.length > 0 && (
                <p
                  role="alert"
                  aria-label="No alcanza el stock"
                  className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive"
                >
                  No alcanza el stock de {branchName} para: {exceedingNames.join(", ")}. Bajá las cantidades, transferí
                  stock o elegí otra sucursal.
                </p>
              )}
              {moveBlockMessages.length > 0 && (
                <div
                  role="alert"
                  aria-label="No se puede mover la recepción"
                  className="flex flex-col gap-1 rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive"
                >
                  {moveBlockMessages.map((message) => (
                    <p key={message}>{message}</p>
                  ))}
                </div>
              )}
              {missingPricesNotice && (
                <p
                  role="status"
                  aria-label="Líneas sin precio"
                  className="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-foreground"
                >
                  {missingPricesNotice}
                </p>
              )}
              {stockEffect && (
                <p
                  role="status"
                  aria-label="Efecto en el stock"
                  className="rounded-lg border border-border bg-accent/40 px-3 py-2 text-xs text-foreground"
                >
                  {stockEffect}
                </p>
              )}
              {itemCount > 0 && (
                <div className="rounded-lg border border-border bg-accent/50 p-3">
                  <div className="flex items-center justify-between">
                    <span className="flex items-center gap-2 text-sm text-muted-foreground">
                      <ShoppingCart className="h-4 w-4" aria-hidden="true" />
                      Total — {itemCount} ítem{itemCount !== 1 ? "s" : ""}
                    </span>
                    <span className="text-xl font-bold text-primary tabular-nums">{formatMoney(total)}</span>
                  </div>
                </div>
              )}
              <Button type="submit" className="w-full" disabled={submitting || noOperativeBranch}>
                {submitLabel}
              </Button>
            </>
          }
        >
          {/* ── Cabecera: cliente, sucursal, domicilio y notas ─────────────────── */}
          <div className="flex flex-col gap-3">
            {isPurchase ? (
              <SupplierSelect
                value={supplierId || null}
                onChange={(next) => setSupplierId(next ?? "")}
                askPhone
                frozenOption={frozenSupplier}
              />
            ) : (
            <div className="flex flex-col gap-2">
              <div className="flex items-center justify-between gap-2">
                <Label className="text-foreground" id={`${uid}-client-label`}>
                  Cliente
                </Label>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="h-6 text-xs text-primary"
                  onClick={() => setShowNewClient(true)}
                >
                  <UserPlus className="mr-1 h-3 w-3" aria-hidden="true" />
                  Nuevo cliente
                </Button>
              </div>
              <SearchableSelect
                options={clientOptions}
                value={clientId}
                onValueChange={setClientId}
                placeholder="Elegí un cliente"
                searchPlaceholder="Buscar cliente..."
                emptyMessage="No se encontraron clientes."
                aria-labelledby={`${uid}-client-label`}
              />
            </div>
            )}

            {!noOperativeBranch && (
              <div className="flex flex-col gap-2">
                <Label className="text-foreground" id={`${uid}-branch-label`}>
                  {isPurchase ? "Sucursal de destino" : "Sucursal de origen"}
                </Label>
                {showBranchAsText ? (
                  <p className="rounded-md border border-border bg-accent/20 px-3 py-2 text-sm text-foreground">
                    {texts.branchLabel} <span className="font-medium">{branchName}</span>
                  </p>
                ) : (
                  <BranchSelect
                    value={branchId}
                    onChange={handleBranchChange}
                    required
                    alwaysVisible
                    className="bg-background border-border text-foreground text-sm"
                  />
                )}
              </div>
            )}

            {isPurchase ? (
              <div className="flex flex-col gap-2">
                <Label htmlFor={referenceId} className="text-foreground">
                  N° de remito del proveedor
                  <span className="ml-2 text-xs font-normal text-muted-foreground">(opcional)</span>
                </Label>
                <Input
                  id={referenceId}
                  value={supplierReference}
                  maxLength={DELIVERY_NOTE_SUPPLIER_REFERENCE_MAX}
                  onChange={(event) => setSupplierReference(event.target.value)}
                  placeholder="Ej.: 0004-00001234"
                  className="bg-background border-border text-foreground"
                />
              </div>
            ) : (
              <div className="flex flex-col gap-2">
                <Label htmlFor={addressId} className="text-foreground">
                  Domicilio de entrega
                  <span className="ml-2 text-xs font-normal text-muted-foreground">(opcional)</span>
                </Label>
                <Textarea
                  id={addressId}
                  value={address}
                  maxLength={DELIVERY_NOTE_ADDRESS_MAX}
                  onChange={(event) => {
                    addressTouched.current = true
                    setAddress(event.target.value)
                  }}
                  placeholder="Calle, número, localidad"
                  rows={2}
                  className="min-h-[60px] bg-background border-border text-foreground"
                />
              </div>
            )}

            <div className="flex flex-col gap-2">
              <Label htmlFor={notesId} className="text-foreground">
                Notas
                <span className="ml-2 text-xs font-normal text-muted-foreground tabular-nums">
                  {notes.length}/{DELIVERY_NOTE_NOTES_MAX}
                </span>
              </Label>
              <Textarea
                id={notesId}
                value={notes}
                maxLength={DELIVERY_NOTE_NOTES_MAX}
                onChange={(event) => setNotes(event.target.value)}
                placeholder={
                  isPurchase
                    ? "Quién recibió, estado de la mercadería, aclaraciones…"
                    : "Horario de entrega, quién recibe, aclaraciones…"
                }
                rows={2}
                className="min-h-[60px] bg-background border-border text-foreground"
              />
            </div>
          </div>

          <div className="border-t border-border" />

          {/* ── Producto ──────────────────────────────────────────────────────── */}
          <StagedProductLine
            ref={stagedRef}
            products={products}
            productById={productById}
            units={units}
            unitsById={unitsById}
            currency="ARS"
            onAdd={handleAddStaged}
            priceSource={isPurchase ? "cost" : "price"}
            addLabel="Agregar al remito"
            headerSlot={<BarcodeScannerInput onScan={handleScan} scopeRef={formRef} guardFocusedInput />}
          />
        </ScrollableCartShell>
      </form>

      {/* Fuera del <form>: el modal se portaliza, pero los eventos de React suben
          por el árbol de componentes y el submit del alta de cliente dispararía
          también la emisión del remito. */}
      <ResponsiveModal open={showNewClient} onOpenChange={setShowNewClient} title="Nuevo cliente">
        <ClientForm
          onSuccess={(client) => {
            setShowNewClient(false)
            if (client) {
              setCreatedClient(client)
              setClientId(client.id)
            }
          }}
        />
      </ResponsiveModal>

      <AlertDialog open={pendingRemoveId !== null} onOpenChange={(open) => !open && setPendingRemoveId(null)}>
        <AlertDialogContent className="bg-card border-border">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-card-foreground">
              ¿Quitar {pendingRemoveLine?.productName ?? "la línea"} del remito?
            </AlertDialogTitle>
            <AlertDialogDescription className="text-muted-foreground">
              {pendingRemoveLine
                ? describeRemovalReturn(
                    pendingRemoveLine.productName,
                    pendingRemoveLine.quantityBase ?? pendingRemoveLine.quantity,
                    deliveryNote?.branch_name ?? branchName,
                    baseUnitOf(pendingRemoveLine.productId),
                    direction,
                  )
                : null}{" "}
              {isPurchase
                ? "El producto ya no está en el catálogo, pero la mercadería entró por ahí: al guardar, se resta del stock."
                : "El producto ya no está en el catálogo, pero la mercadería salió de ahí: al guardar, vuelve al stock."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-border text-foreground">Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => {
                event.preventDefault()
                confirmRemove()
              }}
            >
              Quitar la línea
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
