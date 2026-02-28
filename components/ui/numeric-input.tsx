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
            // Reset click count on focus to ensure logic starts fresh
            setClickCount(0)
        }

        const handleClick = (e: React.MouseEvent<HTMLInputElement>) => {
            const newCount = clickCount + 1
            setClickCount(newCount)

            if (newCount === 1) {
                // First click: select all or clear if preferred. 
                // User requested "borrar el valor actual automáticamente".
                // We set to empty string temporarily or just select all so typing replaces it.
                // To truly "borrar", we notify the parent of a 0 or null value.
                if (onValueChange) onValueChange(0)
                if (inputRef.current) {
                    inputRef.current.value = ""
                }
            }
            // Second click (count > 1) does nothing special, allowing default cursor behavior
        }

        const handleBlur = () => {
            setClickCount(0)
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
                value={value}
                onFocus={handleFocus}
                onClick={handleClick}
                onBlur={handleBlur}
                onChange={handleChange}
                {...props}
            />
        )
    }
)
NumericInput.displayName = "NumericInput"

export { NumericInput }
