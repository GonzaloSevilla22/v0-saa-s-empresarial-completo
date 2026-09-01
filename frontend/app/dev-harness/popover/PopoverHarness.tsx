"use client"

/**
 * qa-integral-modulos G1 (H1, el bug del PO): arnés que reproduce las tres
 * situaciones del informe con los componentes REALES del design system:
 *
 *  1. Selector fuera de todo modal (control positivo — el POS del informe).
 *  2. Selector dentro de un <Dialog> (el modal de venta/compra en escritorio).
 *  3. Selector dentro de un <Sheet side="bottom"> (el panel de venta en móvil,
 *     mismas clases que ResponsiveModal).
 *
 * Los specs de e2e/harness/g1-popover-modal.spec.ts fijan el contrato acá.
 */

import { useMemo, useState } from "react"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"
import {
  SearchableSelect,
  type SearchableSelectOption,
} from "@/components/ui/searchable-select"
import { ProductPicker } from "@/components/shared/product-picker"
import type { Product, UnitOfMeasure } from "@/lib/types"

// 32 opciones = el catálogo del informe (9 visibles, ~23 inalcanzables sin scroll)
const OPTIONS: SearchableSelectOption[] = Array.from({ length: 32 }, (_, i) => ({
  value: `opt-${i + 1}`,
  label: `Producto ${String(i + 1).padStart(2, "0")}`,
  sublabel: `$${(i + 1) * 100}`,
}))

const PRODUCTS: Product[] = Array.from({ length: 32 }, (_, i) => ({
  id: `prod-${i + 1}`,
  name: `Artículo ${String(i + 1).padStart(2, "0")}`,
  category: "General",
  cost: 100,
  price: (i + 1) * 100,
  margin: 50,
  stock: 10,
  minStock: 0,
  isVariant: false,
}))

export function PopoverHarness() {
  const [outsideValue, setOutsideValue] = useState("")
  const [dialogOpen, setDialogOpen] = useState(false)
  const [dialogValue, setDialogValue] = useState("")
  const [dialogProduct, setDialogProduct] = useState("")
  const [sheetOpen, setSheetOpen] = useState(false)
  const [sheetValue, setSheetValue] = useState("")

  const productById = useMemo(
    () => new Map(PRODUCTS.map((p) => [p.id, p])),
    [],
  )
  const unitsById = useMemo(() => new Map<string, UnitOfMeasure>(), [])

  return (
    <div className="min-h-svh bg-background p-6 flex flex-col gap-6 max-w-md">
      <h1 className="text-lg font-semibold text-foreground">
        Arnés G1 — popover dentro de modales
      </h1>

      {/* Ancla para el test de clic-afuera — ARRIBA del selector, para que el
          desplegable (que abre hacia abajo) nunca la tape. */}
      <div data-testid="zona-neutra" className="h-16 rounded-md border border-dashed border-border" />

      {/* 1 — control positivo: fuera de todo modal */}
      <section data-testid="seccion-fuera" className="flex flex-col gap-2">
        <p className="text-sm text-muted-foreground">Selector fuera de modal</p>
        <SearchableSelect
          options={OPTIONS}
          value={outsideValue}
          onValueChange={setOutsideValue}
          placeholder="Seleccionar producto"
          aria-label="Producto (fuera de modal)"
        />
      </section>

      <Button data-testid="abrir-dialog" onClick={() => setDialogOpen(true)}>
        Abrir Dialog
      </Button>
      <Button
        data-testid="abrir-sheet"
        variant="outline"
        onClick={() => setSheetOpen(true)}
      >
        Abrir Sheet
      </Button>

      {/* 2 — Dialog (el formulario de venta/compra en escritorio) */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="bg-card border-border sm:max-w-md" data-testid="dialog-content">
          <DialogHeader>
            <DialogTitle>Formulario en Dialog</DialogTitle>
            <DialogDescription>
              Réplica del modal de venta: selector genérico + selector de producto.
            </DialogDescription>
          </DialogHeader>
          <div data-testid="select-en-dialog">
            <SearchableSelect
              options={OPTIONS}
              value={dialogValue}
              onValueChange={setDialogValue}
              placeholder="Seleccionar producto"
              aria-label="Producto (en dialog)"
            />
          </div>
          <div data-testid="picker-en-dialog">
            <ProductPicker
              products={PRODUCTS}
              productById={productById}
              unitsById={unitsById}
              value={dialogProduct}
              onValueChange={setDialogProduct}
            />
          </div>
        </DialogContent>
      </Dialog>

      {/* 3 — Sheet bottom (el panel de venta en móvil; clases de ResponsiveModal) */}
      <Sheet open={sheetOpen} onOpenChange={setSheetOpen}>
        <SheetContent
          side="bottom"
          className="bg-card border-border rounded-t-2xl px-4 pt-4 pb-6 overflow-hidden flex flex-col max-h-[95dvh]"
          data-testid="sheet-content"
        >
          <SheetHeader className="pb-3 shrink-0">
            <SheetTitle className="text-left">Formulario en Sheet</SheetTitle>
          </SheetHeader>
          <div data-testid="select-en-sheet">
            <SearchableSelect
              options={OPTIONS}
              value={sheetValue}
              onValueChange={setSheetValue}
              placeholder="Seleccionar producto"
              aria-label="Producto (en sheet)"
            />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  )
}
