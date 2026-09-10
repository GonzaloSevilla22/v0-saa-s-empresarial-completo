"use client"

import * as React from "react"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"

type NumericInputBaseProps = Omit<
    React.InputHTMLAttributes<HTMLInputElement>,
    "value" | "onChange"
>

/**
 * productos-costo-nullable (D11): `nullable` es un discriminante de tipos,
 * no sólo un booleano en runtime — así el widening a `number | null` queda
 * SCOPEADO a los callers que optan explícitamente, y las 22 instancias
 * existentes en 7 archivos (que no pasan `nullable`) conservan el tipo
 * `(value: number) => void` de siempre, byte a byte, sin tocar su código.
 * Governance MEDIA de `ui/*` compartido — precedente `qa-integral-modulos`.
 */
export type NumericInputProps =
    | (NumericInputBaseProps & {
          nullable?: false
          value?: number
          onChange?: React.ChangeEventHandler<HTMLInputElement>
          onValueChange?: (value: number) => void
      })
    | (NumericInputBaseProps & {
          /**
           * Con `nullable`: cadena vacía → `onValueChange(null)`; `value ==
           * null` → input vacío; `value === 0` se renderiza `"0"` (un costo
           * cero declarado tiene que verse, no confundirse con ausencia).
           */
          nullable: true
          value?: number | null
          onChange?: React.ChangeEventHandler<HTMLInputElement>
          onValueChange?: (value: number | null) => void
      })

const NumericInput = React.forwardRef<HTMLInputElement, NumericInputProps>(
    ({ className, value, onValueChange, onChange, nullable, ...props }, ref) => {
        const inputRef = React.useRef<HTMLInputElement>(null)

        // Sync external ref with internal ref
        React.useImperativeHandle(ref, () => inputRef.current!)

        const handleFocus = (e: React.FocusEvent<HTMLInputElement>) => {
            e.target.select()
        }

        const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
            const raw = e.target.value
            if (raw === "") {
                // nullable=true: vacío es un estado propio (sin costo). El
                // default conserva el comportamiento de hoy — vacío es 0.
                if (nullable) {
                    onValueChange?.(null)
                } else {
                    onValueChange?.(0)
                }
                if (onChange) onChange(e)
                return
            }
            // guard against NaN (e.g. input of 'e', '--')
            const val = parseFloat(raw)
            if (!isNaN(val)) {
                onValueChange?.(val)
            }
            if (onChange) onChange(e)
        }

        const displayValue = nullable
            ? (value == null ? "" : value)
            : (value === 0 ? "" : (value as number | undefined))

        return (
            <Input
                type="number"
                ref={inputRef}
                className={cn("tabular-nums", className)}
                value={displayValue}
                onFocus={handleFocus}
                onChange={handleChange}
                // productos-costo-nullable (ronda 2): en modo nullable el
                // placeholder por defecto NO puede ser "0" — se leería como
                // un costo cero declarado en vez de "sin costo cargado",
                // justo la ambigüedad que el modo nullable existe para
                // eliminar. Sin nullable, "0" se conserva byte a byte (22
                // callers existentes). `{...props}` sigue pudiendo
                // sobreescribirlo si el caller pasa su propio placeholder.
                placeholder={nullable ? undefined : "0"}
                {...props}
            />
        )
    }
)
NumericInput.displayName = "NumericInput"

export { NumericInput }
