"use client"

import { useState } from "react"
import { Trash2, ChevronDown, AlertTriangle, Check, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { ConfidenceBadge } from "@/components/invoice/ConfidenceBadge"
import { cn } from "@/lib/utils"
import type { MatchedInvoiceLine } from "@/lib/invoice-types"
import type { Product } from "@/lib/types"
import type { UnitOfMeasure } from "@/lib/types"

interface Props {
  line:       MatchedInvoiceLine
  index:      number
  products:   Product[]
  units:      UnitOfMeasure[]
  onChange:   (index: number, updates: Partial<MatchedInvoiceLine>) => void
  onRemove:   (index: number) => void
}

export function InvoiceProductRow({ line, index, products, units, onChange, onRemove }: Props) {
  const [expanded, setExpanded] = useState(line.is_new_product || line.match.type === "partial")

  const productOptions = products
    .filter((p) => !p.parentId || !products.some((pp) => pp.id === p.parentId))
    .map((p) => ({ value: p.id, label: p.name }))

  const unitOptions = [
    { value: "__none__", label: "Sin unidad (base)" },
    ...units.map((u) => ({ value: u.id, label: `${u.name} (${u.symbol})` })),
  ]

  const matchColor =
    line.match.type === "exact_barcode" || line.match.type === "exact_name" || line.match.type === "alias"
      ? "border-emerald-500/20 bg-emerald-500/5"
      : line.match.type === "high"
      ? "border-yellow-500/20 bg-yellow-500/5"
      : line.match.type === "partial"
      ? "border-orange-500/20 bg-orange-500/5"
      : "border-red-500/20 bg-red-500/5"

  return (
    <div className={cn(
      "rounded-lg border transition-all",
      !line.included && "opacity-40",
      matchColor,
    )}>
      {/* ── Summary row ──────────────────────────────────────────────────────── */}
      <div className="flex items-center gap-2 p-3">
        {/* Include toggle */}
        <button
          type="button"
          onClick={() => onChange(index, { included: !line.included })}
          className={cn(
            "flex h-5 w-5 shrink-0 items-center justify-center rounded border-2 transition-colors",
            line.included
              ? "border-primary bg-primary text-primary-foreground"
              : "border-border bg-background",
          )}
        >
          {line.included && <Check className="h-3 w-3" />}
        </button>

        {/* Product name */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm font-medium text-foreground truncate">
              {line.confirmed_product_name || line.description}
            </span>
            {line.is_new_product && (
              <span className="inline-flex items-center gap-1 rounded-full border border-blue-500/40 bg-blue-500/10 px-2 py-0.5 text-[10px] font-medium text-blue-400">
                <Plus className="h-2.5 w-2.5" />
                Nuevo
              </span>
            )}
            {!line.is_new_product && (
              <ConfidenceBadge confidence={line.match.confidence} matchType={line.match.type} />
            )}
          </div>
          <div className="flex items-center gap-2 mt-0.5 text-[11px] text-muted-foreground">
            <span>{line.confirmed_quantity} {line.confirmed_unit_symbol ?? "u"}</span>
            <span>·</span>
            <span>${line.confirmed_unit_price.toLocaleString()}</span>
            {line.subtotal && (
              <>
                <span>=</span>
                <span className="font-medium text-foreground">
                  ${(line.confirmed_quantity * line.confirmed_unit_price).toLocaleString()}
                </span>
              </>
            )}
          </div>
        </div>

        {/* Actions */}
        <div className="flex items-center gap-1 shrink-0">
          {(line.match.type === "partial" || line.match.type === "none") && (
            <AlertTriangle className="h-4 w-4 text-orange-400" />
          )}
          <button
            type="button"
            onClick={() => setExpanded((e) => !e)}
            className="rounded p-1 hover:bg-accent transition-colors"
          >
            <ChevronDown className={cn("h-4 w-4 text-muted-foreground transition-transform", expanded && "rotate-180")} />
          </button>
          <button
            type="button"
            onClick={() => onRemove(index)}
            className="rounded p-1 hover:bg-red-500/10 text-muted-foreground hover:text-red-400 transition-colors"
          >
            <Trash2 className="h-4 w-4" />
          </button>
        </div>
      </div>

      {/* ── Expanded edit panel ───────────────────────────────────────────────── */}
      {expanded && (
        <div className="border-t border-border/50 p-3 flex flex-col gap-3 bg-background/30">
          {/* OCR original text */}
          <p className="text-[10px] text-muted-foreground italic">
            OCR: "{line.raw_description}"
          </p>

          {/* Product selector */}
          <div className="flex flex-col gap-1">
            <label className="text-[11px] text-muted-foreground font-medium uppercase tracking-wider">
              Producto ERP
            </label>
            {line.is_new_product ? (
              <Input
                value={line.confirmed_product_name}
                onChange={(e) => onChange(index, { confirmed_product_name: e.target.value })}
                placeholder="Nombre del nuevo producto..."
                className="bg-background border-border text-foreground text-sm h-9"
              />
            ) : (
              <SearchableSelect
                options={productOptions}
                value={line.confirmed_product_id ?? ""}
                onValueChange={(id) => {
                  const p = products.find((pp) => pp.id === id)
                  onChange(index, {
                    confirmed_product_id:   id,
                    confirmed_product_name: p?.name ?? "",
                    confirmed_unit_id:      p?.baseUnitId ?? null,
                    is_new_product:         false,
                  })
                }}
                placeholder="Seleccionar producto"
                searchPlaceholder="Buscar..."
                emptyMessage="No encontrado."
              />
            )}
            {line.is_new_product && (
              <Button
                type="button"
                size="sm"
                variant="ghost"
                className="text-xs text-primary self-start h-7"
                onClick={() => {
                  const p = products.find((pp) =>
                    pp.name.toLowerCase().includes(line.description.toLowerCase().slice(0, 5))
                  )
                  if (p) onChange(index, {
                    confirmed_product_id:   p.id,
                    confirmed_product_name: p.name,
                    is_new_product:         false,
                  })
                }}
              >
                Buscar en catálogo
              </Button>
            )}
          </div>

          {/* Qty + Unit + Price */}
          <div className="grid grid-cols-3 gap-2">
            <div className="flex flex-col gap-1">
              <label className="text-[11px] text-muted-foreground font-medium">Cantidad</label>
              <NumericInput
                min={0.001}
                step={0.001}
                value={line.confirmed_quantity}
                onValueChange={(v) => onChange(index, { confirmed_quantity: v })}
                className="bg-background border-border text-foreground h-9"
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[11px] text-muted-foreground font-medium">Unidad</label>
              <SearchableSelect
                options={unitOptions}
                value={line.confirmed_unit_id ?? "__none__"}
                onValueChange={(v) => {
                  const u = units.find((uu) => uu.id === v)
                  onChange(index, {
                    confirmed_unit_id:     v === "__none__" ? null : v,
                    confirmed_unit_symbol: u?.symbol ?? null,
                  })
                }}
                placeholder="Base"
                searchPlaceholder="Buscar..."
                emptyMessage="No encontrado."
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[11px] text-muted-foreground font-medium">Costo/u ($)</label>
              <NumericInput
                min={0}
                step={0.01}
                value={line.confirmed_unit_price}
                onValueChange={(v) => onChange(index, { confirmed_unit_price: v })}
                className="bg-background border-border text-foreground h-9"
              />
            </div>
          </div>
        </div>
      )}
    </div>
  )
}