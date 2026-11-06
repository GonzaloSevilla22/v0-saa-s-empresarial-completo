"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { useProducts } from "@/hooks/data/use-products"
import { ProductCategorySelect } from "@/components/product-categories/ProductCategorySelect"
import { toast } from "sonner"
import { isBaseUnitLockedError, productSaveErrorMessage } from "@/lib/product-form-errors"
import { NO_BASE_UNIT, ProductNameField, ProductUnitField } from "@/components/forms/ProductFormFields"
import { RelabelUnitDialog } from "@/components/products/RelabelUnitDialog"
import type { ParentSummary } from "@/components/forms/VariantProductForm"
import type { Product } from "@/lib/types"

interface ParentProductFormProps {
  onSuccess: () => void
  initialData?: Product
  /** Alta: el padre quedó creado; el diálogo sigue con «Agregar la primera variante». Sin este callback, cierra. */
  onCreated?: (parent: ParentSummary) => void
}

/**
 * productos-padre-variantes (D1/D12) — formulario del PRODUCTO CON VARIANTES
 * (padre `variant_only`): pide SÓLO nombre, categoría y unidad de la familia.
 * Un padre no tiene precio, costo, stock, stock mínimo, SKU, código de barras
 * ni PLU: ese es el contrato del servidor y, para precio y costo, del CHECK de
 * la base.
 *
 * En la EDICIÓN, lo que el formulario no muestra viaja con el valor vigente del
 * padre (el código de barras y el SKU legados se conservan, OQ-2; el servidor
 * rechaza un valor distinto del vigente y acepta el vigente).
 */
export function ParentProductForm({ onSuccess, initialData, onCreated }: ParentProductFormProps) {
  const { addProduct, updateProduct, products } = useProducts()

  const [name, setName] = useState(initialData?.name || "")
  const [categoryId, setCategoryId] = useState<string | null>(initialData?.categoryId ?? null)
  const [baseUnitId, setBaseUnitId] = useState(initialData?.baseUnitId ?? "")
  const [relabelOpen, setRelabelOpen] = useState(false)

  // La unidad es de la FAMILIA: si alguna variante tiene stock el selector libre
  // se reemplaza por «Corregir unidad» (D12). Sin historial conocido en el
  // cliente, el selector de siempre; si el servidor igual lo traba (409
  // base_unit_locked), el selector vuelve a la unidad guardada.
  const familyStock = initialData
    ? products.filter((p) => p.parentId === initialData.id).reduce((sum, p) => sum + p.stock, 0)
    : 0
  const hasHistory = !!initialData && familyStock !== 0
  // El listado se refresca tras «Corregir unidad»: la unidad guardada es la VIVA, no la foto con la que se abrió.
  const savedUnitId = (initialData && products.find((p) => p.id === initialData.id)?.baseUnitId) ?? initialData?.baseUnitId

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name || !categoryId) {
      toast.error("Completá nombre y categoría")
      return
    }

    // Unidad: `undefined` = no la toqué (la conserva el servidor); "Sin unidad" = null.
    const unitPayload = !baseUnitId ? undefined : baseUnitId === NO_BASE_UNIT ? null : baseUnitId
    const parentData = {
      name,
      category: "",
      categoryId,
      // Un padre no tiene precio ni stock propios (RN-25): siempre el valor neutro.
      price: 0,
      margin: null,
      stock: 0,
      isVariant: false,
      parentId: undefined,
      stockControlType: "variant_only" as const,
    }

    try {
      if (initialData) {
        await updateProduct({
          ...parentData,
          id: initialData.id,
          // Valores vigentes de lo que el formulario no muestra: el servidor acepta el vigente y
          // rechaza uno distinto; mandar el neutro borraría el código de barras/SKU legado (OQ-2).
          minStock: initialData.minStock,
          barcode: initialData.barcode ?? "",
          sku: initialData.sku,
          // Un padre no usa código de balanza (CHECK products_scale_plu_not_parent): un PLU heredado
          // (dato viejo) se limpia solo al guardar — el campo está oculto y no habría otra salida (F8, PR #599).
          scalePlu: null,
          baseUnitId: unitPayload,
        })
        toast.success("Producto actualizado")
        onSuccess()
        return
      }

      const created = await addProduct({
        ...parentData,
        minStock: 0,
        barcode: "",
        sku: undefined,
        baseUnitId: unitPayload,
      })
      toast.success("Producto creado")
      if (onCreated) onCreated({ id: created.id, name, baseUnitId: baseUnitId && baseUnitId !== NO_BASE_UNIT ? baseUnitId : undefined })
      else onSuccess()
    } catch (error: unknown) {
      toast.error(productSaveErrorMessage(error))
      if (isBaseUnitLockedError(error)) setBaseUnitId(initialData?.baseUnitId ?? "")
    }
  }

  return (
    <>
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <ProductNameField value={name} onChange={setName} />

      <ProductCategorySelect value={categoryId} onChange={setCategoryId} />

      <ProductUnitField
        label="Unidad de la familia"
        value={baseUnitId}
        onChange={setBaseUnitId}
        savedUnitId={savedUnitId}
        hasHistory={hasHistory}
        onCorrectUnit={() => setRelabelOpen(true)}
      />
      <p className="text-[11px] text-muted-foreground">
        Un producto con variantes no tiene precio, costo ni stock propios: cada variante carga los suyos.
      </p>

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar producto" : "Crear y agregar variantes"}
      </Button>
    </form>

    {/* «Corregir unidad» se monta FUERA del <form>: un portal de React propaga los eventos sintéticos al form padre. */}
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
