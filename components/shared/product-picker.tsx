"use client"

import { useDeferredValue, useMemo, useState } from "react"
import { Check, ChevronsUpDown, Loader2 } from "lucide-react"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Button } from "@/components/ui/button"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import { cn } from "@/lib/utils"
import type { Product, UnitOfMeasure } from "@/lib/types"
import type { Currency } from "@/lib/format"
import { getDisplayName, getSearchableLabel } from "@/lib/product-labels"
import { resolveUnit } from "@/lib/unit-utils"
import { formatPricePerUnit, formatStock } from "@/lib/format-unit"
import { ProductDisplay } from "@/components/shared/product-display"

// ── Internal option shape ─────────────────────────────────────────────────────

interface PickerOption {
  product:     Product
  displayName: string
  searchKey:   string
  parentName?: string
  price:       number
  stock:       number
  unitSymbol?: string
}

// ── Props ─────────────────────────────────────────────────────────────────────

interface ProductPickerProps {
  products:    Product[]
  productById: Map<string, Product>
  unitsById:   Map<string, UnitOfMeasure>
  value:       string
  onValueChange: (productId: string) => void
  currency?:   Currency
  placeholder?: string
  disabled?:   boolean
  className?:  string
}

// ── Component ─────────────────────────────────────────────────────────────────

/**
 * Self-contained product selector. Replaces the SearchableSelect + productOptions
 * pattern in sale and purchase forms with a component that:
 *
 *  - Computes its own parentProductIds and option metadata internally.
 *  - Owns the search string state and uses useDeferredValue so typing never
 *    blocks the UI, even with thousands of SKUs.
 *  - Uses getSearchableLabel for filtering — searches by name, parent name,
 *    SKU and barcode simultaneously.
 *  - Renders ProductDisplay in option mode (dropdown) and trigger mode
 *    (selected state in the button).
 *  - Passes shouldFilter={false} to cmdk so our own filter is authoritative.
 */
export function ProductPicker({
  products,
  productById,
  unitsById,
  value,
  onValueChange,
  currency,
  placeholder = "Seleccionar producto",
  disabled,
  className,
}: ProductPickerProps) {
  const [open, setOpen]     = useState(false)
  const [search, setSearch] = useState("")

  // Deferred search: typing updates `search` immediately (fast),
  // but `deferredSearch` lags behind — React defers the expensive filter
  // re-render until the browser is idle.
  const deferredSearch = useDeferredValue(search)
  const isStale        = search !== deferredSearch

  // ── Build option list ─────────────────────────────────────────────────────
  // Only recomputes when products / units / currency change — not on keystrokes.
  const parentProductIds = useMemo(() => {
    const ids = new Set<string>()
    for (const p of products) if (p.parentId) ids.add(p.parentId)
    return ids
  }, [products])

  const allOptions = useMemo<PickerOption[]>(
    () =>
      products
        .filter((p) => !parentProductIds.has(p.id))
        .map((p) => {
          const parent   = p.parentId ? productById.get(p.parentId) : undefined
          const baseUnit = resolveUnit(p.baseUnitId, unitsById)
          return {
            product:     p,
            displayName: getDisplayName(p, parent),
            searchKey:   getSearchableLabel(p, parent),
            parentName:  parent?.name,
            price:       p.price,
            stock:       p.stock,
            unitSymbol:  baseUnit?.symbol,
          }
        }),
    [products, parentProductIds, productById, unitsById],
  )

  // ── Filter on deferred value ──────────────────────────────────────────────
  const filtered = useMemo(() => {
    const q = deferredSearch.trim().toLowerCase()
    if (!q) return allOptions
    return allOptions.filter(
      (o) =>
        o.searchKey.includes(q) ||
        o.displayName.toLowerCase().includes(q),
    )
  }, [allOptions, deferredSearch])

  const selectedOption = allOptions.find((o) => o.product.id === value)

  function handleSelect(productId: string) {
    onValueChange(productId === value ? "" : productId)
    setOpen(false)
    setSearch("")
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          role="combobox"
          aria-expanded={open}
          disabled={disabled}
          className={cn(
            "w-full justify-between font-normal bg-background border-border text-foreground",
            selectedOption ? "h-auto min-h-11 md:min-h-10 py-2" : "text-muted-foreground",
            className,
          )}
        >
          {selectedOption ? (
            <ProductDisplay
              mode="trigger"
              name={selectedOption.parentName
                ? selectedOption.product.name
                : selectedOption.displayName}
              parentName={selectedOption.parentName}
            />
          ) : (
            <span className="truncate">{placeholder}</span>
          )}
          {isStale
            ? <Loader2 className="ml-2 h-4 w-4 shrink-0 opacity-50 animate-spin" />
            : <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
          }
        </Button>
      </PopoverTrigger>

      <PopoverContent
        className="p-0 w-[var(--radix-popover-trigger-width)]"
        align="start"
        // eslint-disable-next-line @typescript-eslint/ban-ts-comment
        // @ts-expect-error modal prop exists at runtime but is missing from Radix types
        modal={false}
      >
        <Command shouldFilter={false}>
          <CommandInput
            placeholder="Buscar producto..."
            value={search}
            onValueChange={setSearch}
          />
          <CommandList>
            <CommandEmpty>No se encontraron productos.</CommandEmpty>
            <CommandGroup>
              {filtered.map((o) => (
                <CommandItem
                  key={o.product.id}
                  value={o.product.id}
                  onSelect={() => handleSelect(o.product.id)}
                >
                  <Check
                    className={cn(
                      "mr-2 h-4 w-4 shrink-0",
                      value === o.product.id ? "opacity-100" : "opacity-0",
                    )}
                  />
                  <ProductDisplay
                    mode="option"
                    name={o.product.name}
                    parentName={o.parentName}
                    price={o.price}
                    stock={o.stock}
                    unitSymbol={o.unitSymbol}
                    currency={currency}
                  />
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  )
}
