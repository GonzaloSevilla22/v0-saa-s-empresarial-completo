"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { PythonApiError } from "@/lib/api/python-api-error"
import { toast } from "sonner"
import { useOrgRole } from "@/hooks/useOrgRole"
import { CAN_STOCK, hasCapability } from "@/lib/rbac-capabilities"
import { productSaveErrorMessage } from "@/lib/product-form-errors"
import { StockAdjustmentModal } from "@/components/stock/stock-adjustment-modal"
import {
  BarcodeField,
  CostPriceFields,
  InheritedCategoryField,
  InheritedUnitField,
  ProductNameField,
  ScalePluField,
  SkuField,
  StockFields,
  useCostPriceFields,
} from "@/components/forms/ProductFormFields"
import type { Product } from "@/lib/types"

/** Lo que la variante necesita saber de su padre (el padre recién creado todavía no está en el listado). */
export interface ParentSummary {
  id: string
  name: string
  /** Unidad de la familia que se acaba de elegir (el padre recién creado no está en el listado todavía). */
  baseUnitId?: string
}

interface VariantProductFormProps {
  parent: ParentSummary
  onSuccess: () => void
  initialData?: Product
  /** Texto de encabezado (p. ej. «Agregar la primera variante» tras crear el padre). */
  heading?: string
}

/**
 * productos-padre-variantes (D4/D12) — formulario de la VARIANTE: el padre va
 * fijo (sin selector), la categoría y la unidad de la familia se muestran de
 * sólo lectura (el servidor las hereda e ignora lo que mande el cliente) y los
 * campos propios son nombre, código de barras, código de balanza, SKU, precio,
 * costo y stock.
 */
export function VariantProductForm({ parent, onSuccess, initialData, heading }: VariantProductFormProps) {
  const { addProduct, updateProduct, products } = useProducts()
  const { units } = useUnitsOfMeasure()
  const { roles, rolesResolved } = useOrgRole()
  const canAdjust = hasCapability(roles, CAN_STOCK, rolesResolved)
  const [adjustOpen, setAdjustOpen] = useState(false)

  const parentProduct = products.find((p) => p.id === parent.id)
  // La unidad efectiva de la familia: la del padre (la variante hereda). Una
  // variante legada con unidad propia se muestra con la suya hasta que se
  // corrija la unidad desde el padre.
  const familyUnitId = initialData?.baseUnitId ?? parentProduct?.baseUnitId ?? parent.baseUnitId

  const [name, setName] = useState(initialData?.name || "")
  const money = useCostPriceFields({ cost: initialData?.cost ?? null, price: initialData?.price || 0 })
  const [stock, setStock] = useState(initialData?.stock || 0)
  const [minStock, setMinStock] = useState(initialData?.minStock ?? 10)
  const [barcode, setBarcode] = useState(initialData?.barcode || "")
  const [sku, setSku] = useState(initialData?.sku || "")
  const [scalePlu, setScalePlu] = useState<number | null>(initialData?.scalePlu ?? null)
  const [scalePluTouched, setScalePluTouched] = useState(false)
  const [scalePluError, setScalePluError] = useState<string | null>(null)

  // El saldo VIVO: tras un ajuste el listado se refresca y el formulario abierto lo refleja.
  const liveStock = (initialData && products.find((p) => p.id === initialData.id)?.stock) ?? initialData?.stock ?? 0
  const unitSymbol = units.find((u) => u.id === familyUnitId)?.symbol

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name) {
      toast.error("Completá el nombre")
      return
    }

    const productData = {
      name,
      category: "",
      // Variante: NO se manda categoryId ni unidad — el servidor las hereda del
      // padre e ignora lo que mande el cliente (D4/D11).
      categoryId: undefined,
      baseUnitId: undefined,
      ...(!initialData || money.costTouched ? { cost: money.cost } : {}),
      price: money.price,
      margin: money.margin,
      minStock,
      barcode,
      sku: sku.trim() || undefined,
      ...(!initialData || scalePluTouched ? { scalePlu } : {}),
      parentId: parent.id,
      isVariant: true,
      // Una variante lleva su stock propio (RN-20).
      stockControlType: "tracked" as const,
    }

    setScalePluError(null)
    try {
      if (initialData) {
        await updateProduct({ ...productData, id: initialData.id })
        toast.success("Producto actualizado")
      } else {
        await addProduct({ ...productData, stock: canAdjust ? stock : 0 })
        toast.success("Variante creada")
      }
      onSuccess()
    } catch (error: unknown) {
      toast.error(productSaveErrorMessage(error))
      if (error instanceof PythonApiError && error.field === "scale_plu") {
        setScalePluError(error.message)
      }
    }
  }

  return (
    <>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        {heading && <h3 className="text-sm font-semibold text-foreground">{heading}</h3>}

        <div className="rounded-lg border border-border bg-accent/50 p-3 text-sm">
          <span className="text-muted-foreground">Variante de: </span>
          <strong className="font-semibold text-foreground">{parent.name}</strong>
        </div>

        <ProductNameField value={name} onChange={setName} />

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <InheritedCategoryField name={parentProduct?.category} />
          <InheritedUnitField unitId={familyUnitId} />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <BarcodeField value={barcode} onChange={setBarcode} />
          <SkuField value={sku} onChange={setSku} />
        </div>

        <ScalePluField
          value={scalePlu}
          onChange={(v) => { setScalePlu(v); setScalePluTouched(true); setScalePluError(null) }}
          error={scalePluError}
          baseUnitId={familyUnitId}
        />

        <CostPriceFields fields={money} />

        <StockFields
          isEdit={!!initialData}
          holdsStock
          canAdjust={canAdjust}
          stock={stock}
          onStockChange={setStock}
          minStock={minStock}
          onMinStockChange={setMinStock}
          liveStock={liveStock}
          unitSymbol={unitSymbol}
          onAdjustStock={() => setAdjustOpen(true)}
        />

        <Button type="submit" className="w-full">
          {initialData ? "Actualizar producto" : "Crear variante"}
        </Button>
      </form>

      {initialData && adjustOpen && (
        <StockAdjustmentModal open onOpenChange={setAdjustOpen} product={{ ...initialData, stock: liveStock }} />
      )}
    </>
  )
}
