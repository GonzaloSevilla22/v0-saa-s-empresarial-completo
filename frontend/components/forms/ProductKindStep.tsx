"use client"

import { useId, useState } from "react"
import { Boxes, Package } from "lucide-react"
import { Button } from "@/components/ui/button"
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group"
import { cn } from "@/lib/utils"

/**
 * `simple` → un producto con su propio precio, costo y stock.
 * `parent` → un producto con variantes (padre `variant_only`: sólo agrupa).
 */
export type ProductKind = "simple" | "parent"

interface ProductKindStepProps {
  onSelect: (kind: ProductKind) => void
}

const OPTIONS: { kind: ProductKind; title: string; description: string; icon: typeof Package }[] = [
  {
    kind: "simple",
    title: "Producto simple",
    description: "Un solo artículo, con su propio precio, costo y stock. Ej: un aceite de 900 ml.",
    icon: Package,
  },
  {
    kind: "parent",
    title: "Producto con variantes",
    description:
      "Una familia de artículos que se distinguen por talle, color o sabor. Cada variante tiene su precio, costo y stock.",
    icon: Boxes,
  },
]

/**
 * productos-padre-variantes (D12) — primer paso del alta: «¿Qué querés crear?».
 * Dos opciones en un grupo de radio (se opera con teclado: Tab entra, flechas
 * eligen, Enter continúa). Continuar espera a que haya una elección: el tipo no
 * tiene valor por defecto porque no se puede cambiar después (D2).
 */
export function ProductKindStep({ onSelect }: ProductKindStepProps) {
  const baseId = useId()
  const [kind, setKind] = useState<ProductKind | "">("")
  const headingId = `${baseId}-heading`

  return (
    <div className="flex flex-col gap-4">
      <h3 id={headingId} className="text-sm font-semibold text-foreground">¿Qué querés crear?</h3>
      <RadioGroup
        aria-labelledby={headingId}
        value={kind}
        onValueChange={(v) => setKind(v as ProductKind)}
        className="grid grid-cols-1 gap-3 sm:grid-cols-2"
      >
        {OPTIONS.map(({ kind: optionKind, title, description, icon: Icon }) => {
          const itemId = `${baseId}-${optionKind}`
          return (
            <label
              key={optionKind}
              htmlFor={itemId}
              className={cn(
                "flex cursor-pointer items-start gap-3 rounded-lg border border-border bg-background p-3 transition-colors",
                "hover:bg-accent/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5",
                "has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring",
              )}
            >
              <RadioGroupItem
                id={itemId}
                value={optionKind}
                aria-labelledby={`${itemId}-title`}
                aria-describedby={`${itemId}-description`}
                className="mt-0.5 shrink-0"
              />
              <span className="flex min-w-0 flex-col gap-1">
                <span id={`${itemId}-title`} className="flex items-center gap-1.5 text-sm font-medium text-foreground">
                  <Icon className="h-4 w-4 text-primary" aria-hidden="true" />
                  {title}
                </span>
                <span id={`${itemId}-description`} className="text-xs text-muted-foreground">{description}</span>
              </span>
            </label>
          )
        })}
      </RadioGroup>
      <Button type="button" className="w-full" disabled={!kind} onClick={() => kind && onSelect(kind)}>
        Continuar
      </Button>
    </div>
  )
}
