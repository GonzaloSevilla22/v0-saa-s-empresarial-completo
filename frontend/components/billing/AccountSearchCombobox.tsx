"use client"

/**
 * mp-real-subscriptions follow-up (task 8.8) — selector de cuenta destino
 * para la cola admin de suscripciones ambiguas.
 *
 * Combobox con búsqueda server-side (GET /payments/accounts/search) — a
 * diferencia de components/ui/searchable-select.tsx (filtro client-side
 * sobre una lista estática), acá el propio input maneja el `q` que dispara
 * la query. Se arma directo sobre Popover+Command (shouldFilter=false) en
 * vez de extender el componente genérico, para no tocar un primitive
 * compartido por otros flujos.
 */

import { useState } from "react"
import { Check, ChevronsUpDown, Loader2 } from "lucide-react"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import {
  Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList,
} from "@/components/ui/command"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import { useAccountSearch, type AccountSearchResult } from "@/hooks/data/use-ambiguous-subscriptions"

const PLAN_LABELS: Record<string, string> = {
  gratis: "Gratis", inicial: "Inicial", avanzado: "Avanzado", pro: "Pro",
}

interface AccountSearchComboboxProps {
  value: AccountSearchResult | null
  onSelect: (account: AccountSearchResult | null) => void
  disabled?: boolean
  id?: string
  "aria-label"?: string
}

export function AccountSearchCombobox({
  value,
  onSelect,
  disabled = false,
  id,
  "aria-label": ariaLabel = "Buscar cuenta destino",
}: AccountSearchComboboxProps) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState("")
  const { data: results, isFetching } = useAccountSearch(query)

  const trimmedQuery = query.trim()
  const showEmpty = !isFetching && trimmedQuery.length >= 2 && (results?.length ?? 0) === 0
  const showHint = !isFetching && trimmedQuery.length < 2

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          id={id}
          type="button"
          variant="outline"
          role="combobox"
          aria-expanded={open}
          aria-label={ariaLabel}
          disabled={disabled}
          className={cn(
            "w-full justify-between font-normal bg-background border-border text-foreground",
            !value && "text-muted-foreground",
          )}
        >
          <span className="truncate">
            {value ? `${value.ownerName ?? value.ownerEmail} — ${value.ownerEmail}` : "Buscar cuenta por email o nombre..."}
          </span>
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
            placeholder="Email o nombre del titular..."
            value={query}
            onValueChange={setQuery}
          />
          <CommandList>
            {isFetching && (
              <div className="flex items-center justify-center gap-2 py-4 text-sm text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin" />
                Buscando...
              </div>
            )}
            {showEmpty && (
              <CommandEmpty>Sin cuentas para &quot;{trimmedQuery}&quot;.</CommandEmpty>
            )}
            {showHint && (
              <div className="py-6 text-center text-sm text-muted-foreground">
                Escribí al menos 2 caracteres para buscar.
              </div>
            )}
            <CommandGroup>
              {(results ?? []).map((account) => (
                <CommandItem
                  key={account.accountId}
                  value={account.accountId}
                  onSelect={() => {
                    onSelect(account)
                    setOpen(false)
                  }}
                >
                  <Check
                    className={cn(
                      "mr-2 h-4 w-4 shrink-0",
                      value?.accountId === account.accountId ? "opacity-100" : "opacity-0",
                    )}
                  />
                  <div className="flex flex-1 flex-col truncate">
                    <span className="truncate">{account.ownerName ?? account.ownerEmail}</span>
                    <span className="truncate text-xs text-muted-foreground">{account.ownerEmail}</span>
                  </div>
                  <span className="ml-3 shrink-0 text-xs text-muted-foreground">
                    {PLAN_LABELS[account.billingPlan] ?? account.billingPlan}
                  </span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  )
}
