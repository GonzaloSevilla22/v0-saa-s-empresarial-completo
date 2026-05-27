"use client"

import * as React from "react"
import { Check, ChevronsUpDown } from "lucide-react"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

export interface SearchableSelectOption {
  value: string
  /** Used by cmdk for filtering and shown in the trigger button. */
  label: string
  /** Fallback secondary text shown to the right when renderOption is not provided. */
  sublabel?: string
  /** Arbitrary structured data passed as-is to renderOption. */
  data?: unknown
}

interface SearchableSelectProps {
  options: SearchableSelectOption[]
  value: string
  onValueChange: (value: string) => void
  placeholder?: string
  searchPlaceholder?: string
  emptyMessage?: string
  className?: string
  disabled?: boolean
  /**
   * Custom renderer for each dropdown option row.
   * When provided, replaces the default label + sublabel rendering.
   * The trigger button always uses opt.label regardless.
   */
  renderOption?: (opt: SearchableSelectOption, isSelected: boolean) => React.ReactNode
}

export function SearchableSelect({
  options,
  value,
  onValueChange,
  placeholder = "Seleccionar...",
  searchPlaceholder = "Buscar...",
  emptyMessage = "Sin resultados.",
  className,
  disabled = false,
  renderOption,
}: SearchableSelectProps) {
  const [open, setOpen] = React.useState(false)

  const selectedLabel = options.find((opt) => opt.value === value)?.label

  function handleSelect(optionValue: string) {
    // Toggle off if same value selected again (optional, keeps parity with Select)
    onValueChange(optionValue === value ? "" : optionValue)
    setOpen(false)
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
            !selectedLabel && "text-muted-foreground",
            className
          )}
        >
          <span className="truncate">{selectedLabel ?? placeholder}</span>
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
        <Command>
          <CommandInput placeholder={searchPlaceholder} />
          <CommandList>
            <CommandEmpty>{emptyMessage}</CommandEmpty>
            <CommandGroup>
              {options.map((opt) => (
                <CommandItem
                  key={opt.value}
                  value={opt.label}  // cmdk filters by this string
                  onSelect={() => handleSelect(opt.value)}
                >
                  <Check
                    className={cn(
                      "mr-2 h-4 w-4 shrink-0",
                      value === opt.value ? "opacity-100" : "opacity-0"
                    )}
                  />
                  {renderOption
                    ? renderOption(opt, value === opt.value)
                    : (
                      <>
                        <span className="flex-1 truncate">{opt.label}</span>
                        {opt.sublabel && (
                          <span className="ml-3 shrink-0 text-xs text-muted-foreground tabular-nums">
                            {opt.sublabel}
                          </span>
                        )}
                      </>
                    )
                  }
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  )
}
