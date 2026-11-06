"use client"

import { useState } from "react"
import { useProducts } from "@/hooks/data/use-products"
import { ProductKindStep, type ProductKind } from "@/components/forms/ProductKindStep"
import { ParentProductForm } from "@/components/forms/ParentProductForm"
import { SimpleProductForm } from "@/components/forms/SimpleProductForm"
import { VariantProductForm, type ParentSummary } from "@/components/forms/VariantProductForm"
import type { Product } from "@/lib/types"

interface ProductFormProps {
  onSuccess: () => void
  initialData?: Product
  /** Abre «Nueva variante» con este padre fijo (no activa el modo edición). */
  defaultParentId?: string
  /**
   * Salta el paso «¿Qué querés crear?» en un alta (p. ej. cuando el tipo ya se
   * decidió en otra pantalla). Sin esto, el alta arranca por el paso.
   */
  initialKind?: ProductKind
}

type CreateStep =
  | { step: "kind" }
  | { step: "simple" }
  | { step: "parent" }
  | { step: "first-variant"; parent: ParentSummary }

/**
 * productos-padre-variantes (D12) — el formulario de producto se parte por
 * COMPOSICIÓN: este componente sólo ELIGE qué formulario corresponde y los tres
 * (`SimpleProductForm`, `ParentProductForm`, `VariantProductForm`) comparten los
 * bloques de `ProductFormFields`.
 *
 *  - Alta: paso «¿Qué querés crear?» → simple | con variantes (el padre sigue con
 *    «Agregar la primera variante» con el padre fijo).
 *  - «Nueva variante» (defaultParentId): formulario de variante con el padre fijo.
 *  - Edición: por modo — `variant_only` → padre; con `parentId` → variante; el
 *    resto (incluido un `tracked` con variantes armado a mano, OQ-3) → simple.
 */
export function ProductForm({ onSuccess, initialData, defaultParentId, initialKind }: ProductFormProps) {
  const { products } = useProducts()
  const [create, setCreate] = useState<CreateStep>(
    initialKind === "simple" ? { step: "simple" } : initialKind === "parent" ? { step: "parent" } : { step: "kind" },
  )

  // ── Edición: el formulario sigue el modo del producto ─────────────────────
  if (initialData) {
    if (initialData.stockControlType === "variant_only") {
      return <ParentProductForm onSuccess={onSuccess} initialData={initialData} />
    }
    if (initialData.parentId) {
      const parent = products.find((p) => p.id === initialData.parentId)
      return (
        <VariantProductForm
          parent={{ id: initialData.parentId, name: parent?.name ?? "Producto padre", baseUnitId: parent?.baseUnitId }}
          initialData={initialData}
          onSuccess={onSuccess}
        />
      )
    }
    return <SimpleProductForm onSuccess={onSuccess} initialData={initialData} />
  }

  // ── Alta de una variante con el padre fijo (desde la fila del padre) ──────
  if (defaultParentId) {
    const parent = products.find((p) => p.id === defaultParentId)
    return (
      <VariantProductForm
        parent={{ id: defaultParentId, name: parent?.name ?? "Producto padre", baseUnitId: parent?.baseUnitId }}
        onSuccess={onSuccess}
      />
    )
  }

  // ── Alta: paso «¿Qué querés crear?» ───────────────────────────────────────
  switch (create.step) {
    case "kind":
      return <ProductKindStep onSelect={(kind) => setCreate({ step: kind })} />
    case "simple":
      return <SimpleProductForm onSuccess={onSuccess} />
    case "parent":
      return (
        <ParentProductForm
          onSuccess={onSuccess}
          onCreated={(parent) => setCreate({ step: "first-variant", parent })}
        />
      )
    case "first-variant":
      return (
        <VariantProductForm
          key={create.parent.id}
          parent={create.parent}
          heading="Agregar la primera variante"
          onSuccess={onSuccess}
        />
      )
  }
}
