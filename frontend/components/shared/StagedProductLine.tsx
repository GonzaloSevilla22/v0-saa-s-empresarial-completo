"use client"

/**
 * presupuestos-modulo (D12) — el "agregar producto" de un carrito: selector,
 * precio, cantidad, unidad, descuento y subtotal editable, con la unidad y el
 * precio por unidad de la LÍNEA (ventas-unidades-conversion D5/D-F).
 *
 * Nace en la capa canónica a partir del bloque de
 * `components/forms/sale-form.tsx` y lo consumen los DOS formularios (venta y
 * presupuesto): una sola definición de la lógica de unidad y precio por unidad
 * de la línea (revisión adversarial F3 del PR #608: la copia inline de la venta
 * se migró acá para que no diverjan).
 *
 * remitos-compra (D11): `priceSource` elige de dónde sale el precio que se
 * precarga. `"price"` (default) es el de venta — venta y presupuesto no cambian;
 * `"cost"` es el costo del catálogo, para el remito de COMPRA (la mercadería se
 * recibe a lo que cuesta). En compra el "Cat." compara contra el costo, el
 * descuento no existe (la compra no lo tiene) y una línea en 0 avisa que lo vas a
 * poder cargar antes de convertir el remito en compra.
 *
 * El componente es dueño del estado del renglón en preparación y no sabe nada
 * del carrito: al agregar llama a `onAdd(staged)` y sólo limpia el renglón si el
 * llamador lo aceptó (devuelve `true`). `selectProduct(id)` lo expone para el
 * lector de códigos: un producto medible escaneado por código común queda
 * elegido con el foco en la cantidad.
 */
import {
  forwardRef,
  useCallback,
  useId,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from "react"
import { PackagePlus, Plus, Ruler } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { NumericInput } from "@/components/ui/numeric-input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { ProductPicker } from "@/components/shared/product-picker"
import {
  calcSaleSubtotal,
  catalogPriceOf,
  unitPriceFromSubtotal,
  type CartPriceSource,
  type StagedCartLine,
} from "@/lib/cart-utils"
import { PURCHASE_LINE_NO_PRICE_NOTICE } from "@/lib/delivery-note-form"
import { formatMoney, type Currency } from "@/lib/format"
import {
  compatibleUnits,
  convertUnitPrice,
  resolveUnit,
  unitInputMin,
  unitInputStep,
} from "@/lib/unit-utils"
import type { Product, UnitOfMeasure } from "@/lib/types"

export interface StagedProductLineHandle {
  /** Deja elegido el producto (con su unidad base y precio) y enfoca la cantidad. */
  selectProduct: (productId: string) => void
}

interface StagedProductLineProps {
  products: Product[]
  productById: Map<string, Product>
  units: UnitOfMeasure[]
  unitsById: Map<string, UnitOfMeasure>
  currency: Currency
  /** Devuelve `true` si la línea se agregó (el renglón se limpia) o `false` si se rechazó. */
  onAdd: (line: StagedCartLine) => boolean
  /** Rótulo del botón; por defecto "Agregar al carrito". */
  addLabel?: string
  /** Rótulo de la sección; por defecto "Agregar producto". */
  title?: string
  /** Se muestra a la derecha del título (p. ej. el indicador del lector de códigos). */
  headerSlot?: React.ReactNode
  /** De dónde sale el precio precargado: `"price"` (default, venta) o `"cost"` (remito de compra). */
  priceSource?: CartPriceSource
}

export const StagedProductLine = forwardRef<StagedProductLineHandle, StagedProductLineProps>(
  function StagedProductLine(
    {
      products,
      productById,
      units,
      unitsById,
      currency,
      onAdd,
      addLabel = "Agregar al carrito",
      title = "Agregar producto",
      headerSlot,
      priceSource = "price",
    },
    ref,
  ) {
    const uid = useId()
    const [productId, setProductId] = useState("")
    const [unitPrice, setUnitPrice] = useState(0)
    const [quantity, setQuantity] = useState(1)
    const [discount, setDiscount] = useState(0)
    const [unitId, setUnitId] = useState("")
    // Subtotal editable: mientras tiene el foco se muestra el borrador crudo del
    // usuario (evita el parpadeo de redondeo con cantidad > 1).
    const [subtotalFocused, setSubtotalFocused] = useState(false)
    const [subtotalDraft, setSubtotalDraft] = useState(0)
    const quantityInputRef = useRef<HTMLInputElement>(null)

    const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])
    const selectedUnit = useMemo(() => resolveUnit(unitId, unitsById), [unitId, unitsById])
    const productBaseUnit = useMemo(
      () => resolveUnit(selectedProduct?.baseUnitId, unitsById),
      [selectedProduct, unitsById],
    )
    const unitOptions = useMemo(() => compatibleUnits(units, productBaseUnit), [units, productBaseUnit])

    const costMode = priceSource === "cost"

    // Contrato D-F: el precio de catálogo (de venta, o el costo en compra) está
    // en la unidad BASE; el aviso "Cat." lo compara re-expresado a la unidad de
    // la línea.
    const catalogPriceForLine = useMemo(
      () =>
        convertUnitPrice(
          selectedProduct ? catalogPriceOf(selectedProduct, priceSource) : 0,
          productBaseUnit,
          selectedUnit,
          productBaseUnit,
        ),
      [selectedProduct, productBaseUnit, selectedUnit, priceSource],
    )
    const stagedStep = useMemo(() => unitInputStep(selectedUnit), [selectedUnit])
    const stagedMin = useMemo(() => unitInputMin(selectedUnit), [selectedUnit])
    const stagedSubtotal = useMemo(
      () => (selectedProduct ? calcSaleSubtotal(unitPrice, quantity, discount) : 0),
      [selectedProduct, unitPrice, quantity, discount],
    )

    const quantityLabel = selectedUnit ? `Cantidad (${selectedUnit.symbol})` : "Cantidad"

    const reset = useCallback(() => {
      setProductId("")
      setUnitPrice(0)
      setQuantity(1)
      setDiscount(0)
      setUnitId("")
    }, [])

    const handleProductChange = useCallback(
      (id: string) => {
        setProductId(id)
        setDiscount(0)
        // La unidad base queda preseleccionada para que paso y mínimo ya sean correctos.
        const p = products.find((x) => x.id === id)
        const nextUnitId = p?.baseUnitId ?? ""
        setUnitId(nextUnitId)
        // La cantidad arranca en el mínimo de la unidad base (0,001 para medibles).
        setQuantity(unitInputMin(resolveUnit(nextUnitId, unitsById)))
        setUnitPrice(p ? catalogPriceOf(p, priceSource) : 0)
      },
      [products, unitsById, priceSource],
    )

    useImperativeHandle(
      ref,
      () => ({
        selectProduct: (id: string) => {
          handleProductChange(id)
          // El input de cantidad recién existe una vez que hay producto elegido.
          setTimeout(() => quantityInputRef.current?.focus(), 0)
        },
      }),
      [handleProductChange],
    )

    function handleAdd() {
      if (!selectedProduct) return
      const accepted = onAdd({ product: selectedProduct, unitPrice, quantity, discount, unitId })
      if (accepted) reset()
    }

    const priceId = `${uid}-price`
    const quantityId = `${uid}-quantity`
    const unitFieldId = `${uid}-unit`
    const discountId = `${uid}-discount`
    const subtotalId = `${uid}-subtotal`

    return (
      <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
        <div className="flex items-center justify-between gap-2">
          <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
            <PackagePlus className="h-3.5 w-3.5" aria-hidden="true" />
            {title}
          </p>
          {headerSlot}
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
            <div className="flex flex-col gap-1">
              <Label htmlFor={priceId} className="text-[10px] text-muted-foreground flex items-center justify-between">
                {costMode ? "Precio de compra unit." : "Precio unit."}
                {unitPrice !== catalogPriceForLine && (
                  <span className="text-[9px] text-warning tabular-nums">
                    Cat. {formatMoney(catalogPriceForLine, currency)}
                  </span>
                )}
              </Label>
              <NumericInput
                id={priceId}
                min={0}
                step={1}
                value={unitPrice}
                onValueChange={setUnitPrice}
                className="bg-background border-border text-foreground"
              />
              {costMode && unitPrice === 0 && (
                <p role="status" className="text-[11px] text-warning">
                  {PURCHASE_LINE_NO_PRICE_NOTICE}
                </p>
              )}
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <div className="flex flex-col gap-1">
                <Label htmlFor={quantityId} className="text-[10px] text-muted-foreground">
                  {quantityLabel}
                </Label>
                <NumericInput
                  id={quantityId}
                  ref={quantityInputRef}
                  min={stagedMin}
                  step={stagedStep}
                  value={quantity}
                  onValueChange={(val) => setQuantity(Math.max(stagedMin, val))}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-1">
                <Label htmlFor={unitFieldId} className="text-[10px] text-muted-foreground flex items-center gap-1">
                  <Ruler className="h-3 w-3" aria-hidden="true" />
                  Unidad
                </Label>
                <Select
                  value={unitId || "__none__"}
                  onValueChange={(v) => {
                    const next = v === "__none__" ? "" : v
                    setUnitId(next)
                    const nextUnit = next ? unitsById.get(next) : undefined
                    setQuantity(unitInputMin(nextUnit))
                    // Contrato D-F (precio por unidad de la LÍNEA): el precio se
                    // re-expresa con el mismo factor que la cantidad.
                    setUnitPrice((prev) => convertUnitPrice(prev, selectedUnit, nextUnit, productBaseUnit))
                  }}
                >
                  <SelectTrigger
                    id={unitFieldId}
                    className="bg-background border-border text-foreground h-10 text-sm"
                  >
                    <SelectValue placeholder="Base (×1)" />
                  </SelectTrigger>
                  <SelectContent className="bg-popover border-border">
                    {!productBaseUnit && <SelectItem value="__none__">Sin unidad (base)</SelectItem>}
                    {unitOptions.map((u) => (
                      <SelectItem key={u.id} value={u.id}>
                        {u.symbol} — {u.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div className={costMode ? "grid grid-cols-1 gap-2" : "grid grid-cols-1 sm:grid-cols-2 gap-2"}>
              {!costMode && (
                <div className="flex flex-col gap-1">
                  <Label htmlFor={discountId} className="text-[10px] text-muted-foreground">
                    Descuento (%)
                  </Label>
                  <NumericInput
                    id={discountId}
                    min={0}
                    max={100}
                    value={discount}
                    onValueChange={setDiscount}
                    placeholder="0"
                    className="bg-background border-border text-foreground"
                  />
                </div>
              )}
              <div className="flex flex-col gap-1">
                <Label htmlFor={subtotalId} className="text-[10px] text-muted-foreground flex items-center justify-between">
                  Subtotal
                  <span className="text-[9px] text-muted-foreground/70">editable</span>
                </Label>
                <NumericInput
                  id={subtotalId}
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
                  className="bg-background border-border text-right font-bold text-success"
                />
              </div>
            </div>
          </div>
        )}

        <Button
          type="button"
          variant="secondary"
          onClick={handleAdd}
          disabled={!selectedProduct}
          className="w-full gap-2"
        >
          <Plus className="h-4 w-4" aria-hidden="true" />
          {addLabel}
        </Button>
      </div>
    )
  },
)
