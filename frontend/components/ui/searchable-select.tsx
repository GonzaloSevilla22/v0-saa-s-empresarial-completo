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
   */
  renderOption?: (opt: SearchableSelectOption, isSelected: boolean) => React.ReactNode
  /**
   * Custom renderer for the trigger button's selected state.
   * When provided, replaces the single-line label span.
   * The button height expands to fit multi-line content automatically.
   */
  renderTrigger?: (opt: SearchableSelectOption) => React.ReactNode
  /**
   * task 14.4 (compras-proveedor-cuenta-corriente): nombre accesible fijo del
   * trigger. Sin esto, el nombre accesible del botón es su propio contenido
   * de texto — el placeholder mientras no hay selección, pero el `label` de
   * la opción elegida en cuanto la hay — y pierde la identidad del campo
   * ("Proveedor", "Cliente") apenas el usuario elige algo.
   *
   * review B (F7): esto resuelve el problema anterior REEMPLAZANDO el valor
   * visible por un nombre fijo — un lector de pantalla nunca se entera de
   * qué quedó seleccionado. Preferí `aria-labelledby` (abajo) cuando el
   * caller tiene un `<Label>` visible: combina identidad de campo + valor
   * seleccionado. `aria-label` queda como fallback para callers sin label
   * visible (p. ej. los tests unitarios de este mismo componente).
   */
  "aria-label"?: string
  /**
   * review B (F7): id de un `<Label>` visible en la página. Cuando se pasa,
   * el nombre accesible del trigger es la CONCATENACIÓN de ese label con el
   * contenido visible del botón (placeholder o la opción elegida): se
   * referencian dos ids, el del label externo y el de un `<span>` interno
   * (autogenerado acá) que envuelve el contenido visible — NUNCA el id del
   * propio botón: un elemento que se referencia a SÍ MISMO por
   * aria-labelledby corta la recursión y aporta texto vacío a esa parte
   * (verificado empíricamente contra dom-accessibility-api/jsdom), así que
   * el id tiene que apuntar a un descendiente con id propio, no al trigger.
   * Tiene prioridad sobre `aria-label` cuando ambos se pasan.
   */
  "aria-labelledby"?: string
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
  renderTrigger,
  "aria-label": ariaLabel,
  "aria-labelledby": ariaLabelledBy,
}: SearchableSelectProps) {
  const [open, setOpen] = React.useState(false)
  // review B (F7): id del <span> de contenido visible, solo generado/usado
  // cuando el caller pasa aria-labelledby (ver el comentario del prop).
  const contentId = React.useId()

  const selectedOption = options.find((opt) => opt.value === value)
  const selectedLabel  = selectedOption?.label

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
          aria-labelledby={ariaLabelledBy ? `${ariaLabelledBy} ${contentId}` : undefined}
          aria-label={ariaLabelledBy ? undefined : ariaLabel}
          disabled={disabled}
          className={cn(
            "w-full justify-between font-normal bg-background border-border text-foreground",
            renderTrigger && selectedOption ? "h-auto min-h-11 md:min-h-10 py-2" : "",
            !selectedLabel && "text-muted-foreground",
            className
          )}
        >
          {renderTrigger && selectedOption
            ? <span id={ariaLabelledBy ? contentId : undefined}>{renderTrigger(selectedOption)}</span>
            : <span id={ariaLabelledBy ? contentId : undefined} className="truncate">{selectedLabel ?? placeholder}</span>
          }
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
