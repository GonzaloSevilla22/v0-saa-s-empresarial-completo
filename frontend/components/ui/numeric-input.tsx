"use client"

import * as React from "react"
import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"

export interface NumericInputProps
    extends React.InputHTMLAttributes<HTMLInputElement> {
    onValueChange?: (value: number) => void
}

const NumericInput = React.forwardRef<HTMLInputElement, NumericInputProps>(
    ({ className, value, onValueChange, onChange, ...props }, ref) => {
        const inputRef = React.useRef<HTMLInputElement>(null)

        // Sync external ref with internal ref
        React.useImperativeHandle(ref, () => inputRef.current!)

        const handleFocus = (e: React.FocusEvent<HTMLInputElement>) => {
            e.target.select()
        }

        const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
            const raw = e.target.value
            // Treat empty string as 0; guard against NaN (e.g. input of 'e', '--')
            const val = raw === "" ? 0 : parseFloat(raw)
            if (!isNaN(val)) {
                if (onValueChange) onValueChange(val)
            }
            if (onChange) onChange(e)
        }

        return (
            <Input
                type="number"
                ref={inputRef}
                className={cn("tabular-nums", className)}
                value={value === 0 ? "" : value}
                onFocus={handleFocus}
                onChange={handleChange}
                placeholder="0"
                {...props}
            />
        )
    }
)
NumericInput.displayName = "NumericInput"

export { NumericInput }
