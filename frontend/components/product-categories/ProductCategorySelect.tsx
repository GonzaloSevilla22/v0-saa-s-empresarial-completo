"use client"

import { useId, useState } from "react"
import Link from "next/link"
import { Check, X } from "lucide-react"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Input } from "@/components/ui/input"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import { useOrgRole } from "@/hooks/useOrgRole"
import { toast } from "sonner"
import type { ProductCategory } from "@/lib/types"

const NEW_VALUE = "__new__"

/** Mismo criterio que el backend (trim + colapso de espacios internos). */
export function normalizeCategoryName(raw: string): string {
  return raw.trim().replace(/\s+/g, " ")
}

/**
 * Opciones que ofrece el selector: las ACTIVAS por sort_order y, si el valor
 * seleccionado apunta a una desactivada (producto imputado antes de la baja),
 * también esa — al final y marcada — para que la edición no la pierda.
 */
export function productCategoryOptions(
  categories: ProductCategory[],
  value: string | null,
): ProductCategory[] {
  const sorted = [...categories].sort(
    (a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name),
  )
  const active = sorted.filter((c) => c.isActive)
  const selected = value ? sorted.find((c) => c.id === value) : undefined
  if (selected && !selected.isActive) return [...active, selected]
  return active
}

interface ProductCategorySelectProps {
  value: string | null
  onChange: (value: string | null) => void
  /** Label shown above the select. Pass false to hide (default: shown). */
  showLabel?: boolean
  label?: string
  placeholder?: string
  /** Ofrecer "+ Nueva categoría" al pie (sólo escritores). Default true. */
  allowCreate?: boolean
  className?: string
  disabled?: boolean
}

/**
 * Selector de categoría de producto — el MISMO componente en toda superficie
 * que pida elegir una (formulario de producto, alta inline desde compras,
 * barra de recategorización en lote). Espejo de PaymentMethodSelect.
 *
 * D9 — el alta rápida NO abre un diálogo anidado: "+ Nueva categoría" al pie
 * de la lista intercambia el <Select> por un <Input> con confirmar/cancelar
 * EN LA MISMA FILA; al confirmar crea, invalida el catálogo y deja la nueva
 * seleccionada, sin perder nada de lo ya cargado en el formulario.
 *
 * D11 — cuenta sin categorías activas: advierte y ofrece crear en el lugar
 * (y enlaza al gestor), nunca bloquea.
 */
export function ProductCategorySelect({
  value,
  onChange,
  showLabel = true,
  label = "Categoría",
  placeholder = "Seleccionar categoría",
  allowCreate = true,
  className,
  disabled = false,
}: ProductCategorySelectProps) {
  const { productCategories, isLoading, createProductCategory, createProductCategoryMutation } =
    useProductCategories(true)
  const { isWriter } = useOrgRole()

  const reactId = useId()
  const selectId = `product-category-${reactId}`
  const inputId = `product-category-new-${reactId}`

  const [creating, setCreating] = useState(false)
  const [draft, setDraft] = useState("")

  const options = productCategoryOptions(productCategories, value)
  const hasActive = productCategories.some((c) => c.isActive)
  const emptyCatalog = !isLoading && !hasActive
  const canCreate = allowCreate && isWriter
  const showInlineInput = canCreate && (creating || emptyCatalog)

  async function confirmCreate() {
    const name = normalizeCategoryName(draft)
    if (!name) {
      toast.error("El nombre de la categoría no puede estar vacío")
      return
    }
    try {
      const created = await createProductCategory({ name })
      onChange(created.id)
      setDraft("")
      setCreating(false)
      toast.success(`Categoría "${created.name}" creada`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "No se pudo crear la categoría"
      toast.error(msg)
    }
  }

  function cancelCreate() {
    setDraft("")
    setCreating(false)
  }

  const labelNode = showLabel ? (
    <Label htmlFor={showInlineInput ? inputId : selectId} className="text-foreground">
      {label}
    </Label>
  ) : null

  if (showInlineInput) {
    return (
      <div className="flex flex-col gap-2">
        {labelNode}
        {emptyCatalog && (
          <p className="text-xs text-warning" role="status">
            No tenés categorías activas. Creá una acá mismo o desde{" "}
            <Link href="/configuracion?tab=categorias" className="underline underline-offset-2 hover:opacity-80">
              Configuración
            </Link>
            .
          </p>
        )}
        <div className="flex gap-2">
          <Input
            id={inputId}
            aria-label="Nueva categoría"
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              // Enter no debe enviar el formulario que envuelve al selector.
              if (e.key === "Enter") { e.preventDefault(); void confirmCreate() }
              if (e.key === "Escape") { e.preventDefault(); cancelCreate() }
            }}
            placeholder="Nombre de la nueva categoría"
            className={className ?? "bg-background border-border text-foreground flex-1"}
            disabled={createProductCategoryMutation.isPending}
          />
          <Button
            type="button"
            size="icon"
            variant="default"
            aria-label="Crear categoría"
            title="Crear categoría"
            onClick={() => void confirmCreate()}
            disabled={createProductCategoryMutation.isPending}
          >
            <Check className="h-4 w-4" />
          </Button>
          {!emptyCatalog && (
            <Button
              type="button"
              size="icon"
              variant="outline"
              aria-label="Cancelar"
              title="Cancelar"
              onClick={cancelCreate}
              disabled={createProductCategoryMutation.isPending}
            >
              <X className="h-4 w-4" />
            </Button>
          )}
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-2">
      {labelNode}
      {emptyCatalog && !canCreate && (
        <p className="text-xs text-warning" role="status">
          No tenés categorías activas. Pedile al dueño de la cuenta que cree una desde{" "}
          <Link href="/configuracion?tab=categorias" className="underline underline-offset-2 hover:opacity-80">
            Configuración
          </Link>
          .
        </p>
      )}
      <Select
        value={value ?? ""}
        onValueChange={(v) => {
          if (v === NEW_VALUE) {
            setDraft("")
            setCreating(true)
            return
          }
          onChange(v || null)
        }}
        disabled={disabled || isLoading}
      >
        <SelectTrigger
          id={selectId}
          aria-label={label}
          className={className ?? "bg-background border-border text-foreground"}
        >
          <SelectValue placeholder={placeholder} />
        </SelectTrigger>
        <SelectContent className="bg-popover border-border">
          {options.map((c) => (
            <SelectItem key={c.id} value={c.id}>
              {c.name}
              {!c.isActive && " (inactiva)"}
            </SelectItem>
          ))}
          {canCreate && (
            <SelectItem value={NEW_VALUE} className="text-primary font-medium">
              + Nueva categoría
            </SelectItem>
          )}
        </SelectContent>
      </Select>
    </div>
  )
}
