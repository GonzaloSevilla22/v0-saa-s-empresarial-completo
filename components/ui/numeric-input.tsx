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
        const [clickCount, setClickCount] = React.useState(0)
        const inputRef = React.useRef<HTMLInputElement>(null)

        // Sync external ref with internal ref
        React.useImperativeHandle(ref, () => inputRef.current!)

        const handleFocus = (e: React.FocusEvent<HTMLInputElement>) => {
            e.target.select()
        }

        const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
            const val = e.target.value === "" ? 0 : parseFloat(e.target.value)
            if (onValueChange) onValueChange(val)
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
