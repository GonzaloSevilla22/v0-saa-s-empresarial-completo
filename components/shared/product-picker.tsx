"use client"

import { useMemo, useState } from "react"
import { Check, ChevronsUpDown } from "lucide-react"
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
 *  - Owns the search string state. Filter is synchronous (pure in-memory JS).
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

  // No useDeferredValue — the filter is pure in-memory JS over an already-loaded
  // catalog. Deferring caused a stale-results flash (all products visible while
  // deferredSearch lagged behind), which was the source of irrelevant results.

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
  // Multi-token AND search with relevance ranking and phonetic normalization.
  //
  // Improvements over the previous single-phrase includes() approach:
  //   1. Token splitting — "buzo darlon" → ["buzo","darlon"], both must match
  //      anywhere in the searchKey (order-independent).
  //   2. z↔s normalization — covers regional spelling variants common in
  //      Argentine/Colombian Spanish ("buso" matches "buzo", and vice-versa).
  //   3. Relevance ranking — exact-phrase match ranks above token-only match;
  //      word-boundary hits boost score further.
  const filtered = useMemo(() => {
    const raw = search.trim().toLowerCase()
    if (!raw) return allOptions

    // Normalize: remove diacritics (same as getSearchableLabel) + z↔s
    const norm = (s: string) =>
      s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/z/g, "s")

    const q      = norm(raw)
    const tokens = q.split(/\s+/).filter(Boolean)
    if (tokens.length === 0) return allOptions

    type Scored = { option: PickerOption; score: number }
    const scored: Scored[] = []

    // ─── DEBUG INSTRUMENTATION (temporary — remove after diagnosis) ──────────
    // eslint-disable-next-line no-console
    console.group(`[ProductPicker] search="${search}" raw="${raw}" norm="${q}" tokens=[${tokens.join(", ")}] allOptions=${allOptions.length}`)
    // ─────────────────────────────────────────────────────────────────────────

    for (const o of allOptions) {
      const key     = norm(o.searchKey)        // searchKey already lowercase + no diacritics; add z↔s
      const display = norm(o.displayName)

      // ─── DEBUG: per-token match analysis (BEFORE early continue) ───────────
      const matchedTokens = tokens.filter((t) => key.includes(t) || display.includes(t))
      const missingTokens = tokens.filter((t) => !key.includes(t) && !display.includes(t))
      const wouldPass = missingTokens.length === 0

      // Log items that DO pass the filter (so we see what's in filtered)
      if (wouldPass) {
        const tokenContexts = tokens.map((t) => {
          const idxKey = key.indexOf(t)
          const idxDisp = display.indexOf(t)
          const contextKey = idxKey >= 0
            ? `...${key.substring(Math.max(0, idxKey - 12), Math.min(key.length, idxKey + t.length + 12))}...`
            : null
          const contextDisp = idxDisp >= 0
            ? `...${display.substring(Math.max(0, idxDisp - 12), Math.min(display.length, idxDisp + t.length + 12))}...`
            : null
          return {
            token:           t,
            foundInKey:      idxKey >= 0,
            foundInDisplay:  idxDisp >= 0,
            indexInKey:      idxKey,
            indexInDisplay:  idxDisp,
            keyContext:      contextKey,
            displayContext:  contextDisp,
          }
        })
        // eslint-disable-next-line no-console
        console.log({
          productId:     o.product.id,
          productName:   o.product.name,
          parentName:    o.parentName,
          rawSearchKey:  o.searchKey,
          normSearchKey: key,
          rawDisplay:    o.displayName,
          normDisplay:   display,
          tokens,
          matchedTokens,
          tokenContexts,
        })
      }
      // ─────────────────────────────────────────────────────────────────────────

      // AND semantics: every token must appear somewhere
      if (!tokens.every((t) => key.includes(t) || display.includes(t))) continue

      // Rank by relevance (higher = better match)
      let score = 0
      if (key.includes(q) || display.includes(q))                        score += 100 // exact phrase
      if (key.startsWith(tokens[0]) || display.startsWith(tokens[0]))    score += 50  // starts with first token
      for (const t of tokens) {
        if (key.startsWith(t) || key.includes(` ${t}`))                  score += 10  // word-boundary hit
      }

      scored.push({ option: o, score })
    }

    scored.sort((a, b) => b.score - a.score)

    // ─── DEBUG: final summary ────────────────────────────────────────────────
    // eslint-disable-next-line no-console
    console.log(`[ProductPicker] filtered.length=${scored.length} of ${allOptions.length} total`)
    // eslint-disable-next-line no-console
    console.log(`[ProductPicker] TOP 20 sorted by score:`, scored.slice(0, 20).map((x, i) => ({
      rank:        i + 1,
      score:       x.score,
      productName: x.option.product.name,
      parentName:  x.option.parentName,
    })))

    // ─── DEBUG: SUSPICIOUS items — pasaron AND check pero NO tienen "buzo/buso/darlon" en el name crudo ──
    const suspicious = scored.filter(({ option }) => {
      const rawName   = option.product.name.toLowerCase()
      const rawParent = (option.parentName ?? "").toLowerCase()
      const combined  = `${rawName} ${rawParent}`
      // Buscar "buzo", "buso", o "darlon" en el nombre CRUDO (sin normalizar)
      // Si NO contiene ninguna de esas palabras, es sospechoso.
      const hasBuzo   = combined.includes("buzo") || combined.includes("buso")
      const hasDarlon = combined.includes("darlon")
      return !(hasBuzo && hasDarlon)
    })

    if (suspicious.length > 0) {
      // eslint-disable-next-line no-console
      console.warn(`🚨 [ProductPicker] ${suspicious.length} SOSPECHOSOS — pasaron filtro pero NO tienen "buzo/buso" Y "darlon" en name+parent crudo:`)
      // eslint-disable-next-line no-console
      console.warn(suspicious.slice(0, 30).map(({ option, score }) => ({
        score,
        productName:   option.product.name,
        parentName:    option.parentName ?? "(sin parent)",
        sku:           option.product.sku ?? "(sin sku)",
        barcode:       option.product.barcode ?? "(sin barcode)",
        rawSearchKey:  option.searchKey,
        normSearchKey: norm(option.searchKey),
        tokenLocations: tokens.map((t) => {
          const nKey  = norm(option.searchKey)
          const nDisp = norm(option.displayName)
          const iKey  = nKey.indexOf(t)
          const iDisp = nDisp.indexOf(t)
          return {
            token: t,
            inKeyAt:     iKey  >= 0 ? `pos ${iKey}: "${nKey.substring(Math.max(0, iKey - 15), Math.min(nKey.length, iKey + t.length + 15))}"`  : "NOT FOUND",
            inDisplayAt: iDisp >= 0 ? `pos ${iDisp}: "${nDisp.substring(Math.max(0, iDisp - 15), Math.min(nDisp.length, iDisp + t.length + 15))}"` : "NOT FOUND",
          }
        }),
      })))
    } else {
      // eslint-disable-next-line no-console
      console.log(`✅ [ProductPicker] Zero sospechosos — todos los ${scored.length} items contienen "buzo/buso" Y "darlon" en name+parent.`)
    }

    // eslint-disable-next-line no-console
    console.groupEnd()
    // ─────────────────────────────────────────────────────────────────────────

    return scored.map((x) => x.option)
  }, [allOptions, search])

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
          <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
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
          {/* ─── DEBUG BANNER (temporary) ─────────────────────────────────── */}
          <div
            style={{
              background:   "#fde047",
              color:        "#000",
              fontSize:     "11px",
              fontWeight:   "bold",
              fontFamily:   "monospace",
              padding:      "6px 8px",
              borderBottom: "2px solid #ca8a04",
              lineHeight:   "1.3",
            }}
            data-debug-version="v3-banner-prefix"
          >
            DEBUG v3 · search=&quot;{search}&quot; · filtered.length={filtered.length} · allOptions={allOptions.length}
            <br />
            <span style={{ fontSize: "10px", fontWeight: "normal" }}>
              Si NO ves este banner amarillo, tu browser está corriendo bundle viejo. Hard refresh: Ctrl+Shift+R.
            </span>
          </div>
          {/* ──────────────────────────────────────────────────────────────── */}
          <CommandList>
            <CommandEmpty>No se encontraron productos.</CommandEmpty>
            <CommandGroup>
              {filtered.map((o, idx) => (
                <CommandItem
                  key={o.product.id}
                  value={o.product.id}
                  onSelect={() => handleSelect(o.product.id)}
                  data-debug-idx={idx}
                >
                  <Check
                    className={cn(
                      "mr-2 h-4 w-4 shrink-0",
                      value === o.product.id ? "opacity-100" : "opacity-0",
                    )}
                  />
                  {/* DEBUG: prefijo visible con índice */}
                  <span style={{ fontFamily: "monospace", fontSize: "10px", color: "#facc15", marginRight: 6, minWidth: 38 }}>
                    [#{idx}]
                  </span>
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
