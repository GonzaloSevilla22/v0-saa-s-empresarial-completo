"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { ProductCategorySelect } from "@/components/product-categories/ProductCategorySelect"
import { PythonApiError } from "@/lib/api/python-api-error"
import { toast } from "sonner"
import { useOrgRole } from "@/hooks/useOrgRole"
import { CAN_STOCK, hasCapability } from "@/lib/rbac-capabilities"
import { isBaseUnitLockedError, productSaveErrorMessage } from "@/lib/product-form-errors"
import { StockAdjustmentModal } from "@/components/stock/stock-adjustment-modal"
import { RelabelUnitDialog } from "@/components/products/RelabelUnitDialog"
import {
  BarcodeField,
  CostPriceFields,
  NO_BASE_UNIT,
  ProductNameField,
  ProductUnitField,
  ScalePluField,
  SkuField,
  StockFields,
  useCostPriceFields,
} from "@/components/forms/ProductFormFields"
import type { Product, StockControlType } from "@/lib/types"
import { Package, Wrench } from "lucide-react"

interface SimpleProductFormProps {
  onSuccess: () => void
  initialData?: Product
}

/**
 * productos-padre-variantes (D12) — formulario del PRODUCTO SIMPLE: el completo
 * de siempre (precio, costo, stock, SKU, código de barras, código de balanza,
 * categoría, unidad) SIN selector de padre. También abre un `tracked`/`untracked`
 * que ya tiene variantes (padre armado a mano antes de este change, OQ-3): con
 * el aviso de que lo que se vende es cada variante, sin convertirlo.
 */
export function SimpleProductForm({ onSuccess, initialData }: SimpleProductFormProps) {
  const { addProduct, updateProduct, products } = useProducts()
  const { units } = useUnitsOfMeasure()

  // stock-ledger-solo-rpc (D9/D12, OQ-2): el formulario NO edita el stock. En el
  // ALTA, «Stock inicial» sólo se ofrece a quien puede ajustar stock (CAN_STOCK:
  // owner/admin/stock — decidido sobre el CONJUNTO de roles activos, optimista
  // mientras no resolvió: la barrera real es la base y el backend responde 403
  // antes de crear nada). En la EDICIÓN, «Stock actual» es de sólo lectura y
  // «Ajustar stock» abre el modal de ajuste (motivo obligatorio, historial).
  const { roles, rolesResolved } = useOrgRole()
  const canAdjust = hasCapability(roles, CAN_STOCK, rolesResolved)
  const [adjustOpen, setAdjustOpen] = useState(false)
  const [relabelOpen, setRelabelOpen] = useState(false)

  const [name, setName] = useState(initialData?.name || "")
  // productos-categorias-sku (D1): la categoría se elige del catálogo de la
  // cuenta por id — PRODUCT_CATEGORIES (lista fija) se retiró.
  const [categoryId, setCategoryId] = useState<string | null>(initialData?.categoryId ?? null)
  const money = useCostPriceFields({ cost: initialData?.cost ?? null, price: initialData?.price || 0 })
  const [stock, setStock] = useState(initialData?.stock || 0)
  // Corrección del PR #584: `??`, no `||` — un mínimo 0 ("sin alerta", RN-23)
  // es un valor, no un vacío; el 10 queda sólo como default de un alta nueva.
  const [minStock, setMinStock] = useState(initialData?.minStock ?? 10)
  const [barcode, setBarcode] = useState(initialData?.barcode || "")
  // productos-categorias-sku: SKU opcional. Se recorta al enviar; vacío → undefined (NULL en la base).
  const [sku, setSku] = useState(initialData?.sku || "")
  const [stockControlType, setStockControlType] = useState<StockControlType>(
    initialData?.stockControlType === "untracked" ? "untracked" : "tracked",
  )
  const [baseUnitId, setBaseUnitId] = useState(initialData?.baseUnitId ?? "")

  // balanza-etiquetas-pos (D2, D13): tri-estado igual que cost/baseUnitId —
  // `scalePluTouched` distingue "no lo toqué" (conserva en la edición) de
  // "lo dejé en null" (desasigna). En un alta la clave siempre viaja.
  const [scalePlu, setScalePlu] = useState<number | null>(initialData?.scalePlu ?? null)
  const [scalePluTouched, setScalePluTouched] = useState(false)
  const [scalePluError, setScalePluError] = useState<string | null>(null)

  const holdsStock = stockControlType === "tracked"
  // El saldo VIVO: tras un ajuste el listado se refresca y el formulario abierto
  // lo refleja (initialData es la foto del momento en que se abrió).
  const liveStock = (initialData && products.find((p) => p.id === initialData.id)?.stock) ?? initialData?.stock ?? 0
  const currentUnitSymbol = units.find((u) => u.id === initialData?.baseUnitId)?.symbol
  const children = initialData ? products.filter((p) => p.parentId === initialData.id) : []
  const hasVariants = children.length > 0
  // productos-padre-variantes (D12): con stock en la familia la unidad ya no se elige libremente —
  // se corrige con «Corregir unidad» (dueño/administrador). Sin stock conocido, el selector de siempre
  // (si el servidor igual lo traba, 409 base_unit_locked, el selector vuelve a la unidad guardada).
  const familyStock = liveStock + children.reduce((sum, p) => sum + p.stock, 0)
  const hasUnitHistory = !!initialData && stockControlType === "tracked" && familyStock !== 0
  // El listado se refresca tras «Corregir unidad»: la unidad guardada es la VIVA, no la foto con la que se abrió.
  const savedUnitId = (initialData && products.find((p) => p.id === initialData.id)?.baseUnitId) ?? initialData?.baseUnitId

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    // Regla vigente (intacta): categoría obligatoria.
    if (!name || !categoryId) {
      toast.error("Completá nombre y categoría")
      return
    }

    const productData = {
      name,
      // productos-categoria-text-retiro: category_id es la única fuente de
      // verdad y el nombre legible lo deriva el servidor. El campo sigue en el
      // tipo `Product` pero este valor nunca se transmite.
      category: "",
      categoryId: categoryId ?? undefined,
      // productos-costo-nullable (D12, tri-estado): en una EDICIÓN, la clave
      // `cost` sólo viaja si el usuario tocó el campo — así se conserva el
      // costo existente sin reescribirlo en cada guardado. En un ALTA
      // siempre viaja (ausencia y `null` explícito producen el mismo
      // resultado en la creación, así que no hace falta distinguir).
      ...(!initialData || money.costTouched ? { cost: money.cost } : {}),
      price: money.price,
      margin: money.margin,
      minStock: stockControlType === "untracked" ? 0 : minStock,
      barcode,
      sku: sku.trim() || undefined,
      // balanza-etiquetas-pos (D2/D13): mismo tri-estado que cost — en un
      // alta la clave siempre viaja; en una edición sólo si se tocó.
      ...(!initialData || scalePluTouched ? { scalePlu } : {}),
      parentId: undefined,
      isVariant: false,
      stockControlType,
      // ventas-unidades-conversion (auditoría post-apply): para un producto no
      // rastreado el selector no se muestra, así que se manda `undefined` =
      // "sin cambios" (el hook omite el campo en la edición y el backend conserva
      // el valor; en el alta viaja null). Decisión 7: "Sin unidad" manda `null`
      // explícito = desasignar; el selector sin tocar sigue en `undefined`.
      // Quitarla con stock o historia la rechaza el backend (D11/D-C, 409).
      baseUnitId:
        stockControlType !== "tracked" || !baseUnitId
          ? undefined
          : baseUnitId === NO_BASE_UNIT
            ? null
            : baseUnitId,
    }

    setScalePluError(null)
    try {
      if (initialData) {
        // La edición NO manda `stock` (D9): el ajuste vive en «Ajustar stock».
        await updateProduct({ ...productData, id: initialData.id })
        toast.success("Producto actualizado")
      } else {
        // Stock inicial sólo con CAN_STOCK y producto con stock propio; sin el rol
        // el campo ni se muestra y el alta viaja con 0 (el servidor igual lo exige).
        await addProduct({ ...productData, stock: holdsStock && canAdjust ? stock : 0 })
        toast.success("Producto creado")
      }
      onSuccess()
    } catch (error: unknown) {
      // productos-categorias-sku (D5): el 409 de SKU (y cualquier detail del
      // backend) se muestra tal cual; el formulario conserva lo cargado.
      toast.error(productSaveErrorMessage(error))
      // Decisión 7: la unidad base NO cambió (el producto tiene stock o
      // historia) — el selector vuelve a la que conserva, así lo que se ve es
      // lo que quedó guardado y el resto de lo cargado se puede reintentar.
      if (isBaseUnitLockedError(error)) setBaseUnitId(initialData?.baseUnitId ?? "")
      // balanza-etiquetas-pos (D2): 409 scale_plu_taken / 422 scale_plu_parent
      // — el `field` del problem+json lo distingue de cualquier otro error.
      if (error instanceof PythonApiError && error.field === "scale_plu") {
        setScalePluError(error.message)
      }
    }
  }

  return (
    <>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        {hasVariants && (
          <div role="note" className="rounded-lg border border-warning/30 bg-warning/10 p-3 text-xs text-warning">
            Este producto tiene variantes: lo que se vende es cada variante. Sus datos propios se conservan tal como están.
          </div>
        )}

        <ProductNameField value={name} onChange={setName} />

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <ProductCategorySelect value={categoryId} onChange={setCategoryId} />
          <SkuField value={sku} onChange={setSku} />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <BarcodeField value={barcode} onChange={setBarcode} />
          <ScalePluField
            value={scalePlu}
            onChange={(v) => { setScalePlu(v); setScalePluTouched(true); setScalePluError(null) }}
            error={scalePluError}
            baseUnitId={baseUnitId || undefined}
          />
        </div>

        <CostPriceFields fields={money} />

        {/* ── Tipo de inventario + unidad ─────────────────────────────────── */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Tipo de inventario</Label>
            <Select value={stockControlType} onValueChange={(v) => setStockControlType(v as StockControlType)}>
              <SelectTrigger className="bg-background border-border text-foreground">
                <SelectValue />
              </SelectTrigger>
              <SelectContent className="bg-popover border-border">
                <SelectItem value="tracked">
                  <span className="flex items-center gap-1.5">
                    <Package className="h-3.5 w-3.5 text-primary" />
                    Inventario físico
                  </span>
                </SelectItem>
                <SelectItem value="untracked">
                  <span className="flex items-center gap-1.5">
                    <Wrench className="h-3.5 w-3.5 text-muted-foreground" />
                    Servicio / Digital
                  </span>
                </SelectItem>
              </SelectContent>
            </Select>
          </div>

          {stockControlType === "tracked" && (
            <ProductUnitField
              value={baseUnitId}
              onChange={setBaseUnitId}
              savedUnitId={savedUnitId}
              hasHistory={hasUnitHistory}
              onCorrectUnit={() => setRelabelOpen(true)}
            />
          )}
        </div>

        {stockControlType !== "untracked" && (
          <StockFields
            isEdit={!!initialData}
            holdsStock={holdsStock}
            canAdjust={canAdjust}
            stock={stock}
            onStockChange={setStock}
            minStock={minStock}
            onMinStockChange={setMinStock}
            liveStock={liveStock}
            unitSymbol={currentUnitSymbol}
            onAdjustStock={() => setAdjustOpen(true)}
          />
        )}

        <Button type="submit" className="w-full">
          {initialData ? "Actualizar producto" : "Crear producto"}
        </Button>
      </form>

      {/* Modal de ajuste anidado: se monta sólo mientras está abierto, con el producto
          preseleccionado, FUERA del <form> (un portal de React propaga los eventos
          sintéticos al form padre). Al cerrarlo el foco vuelve al botón «Ajustar stock». */}
      {initialData && adjustOpen && (
        <StockAdjustmentModal open onOpenChange={setAdjustOpen} product={{ ...initialData, stock: liveStock }} />
      )}

      {initialData && relabelOpen && (
        <RelabelUnitDialog
          open
          onOpenChange={setRelabelOpen}
          product={initialData}
          exampleQuantity={familyStock}
          onDone={setBaseUnitId}
        />
      )}
    </>
  )
}
