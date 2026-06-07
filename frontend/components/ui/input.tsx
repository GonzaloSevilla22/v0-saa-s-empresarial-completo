import * as React from 'react'

import { cn } from '@/lib/utils'

export interface InputProps extends React.ComponentProps<'input'> {
  /**
   * ERP-style "overwrite mode": when true, all text is selected on focus so
   * the first keystroke replaces the existing value instead of appending to it.
   *
   * Double-clicking still lets the user do partial edits (the browser's native
   * word-selection overrides the select-all after the dblclick event fires).
   *
   * Uses requestAnimationFrame to avoid the browser's default click-to-position
   * handler overriding the selection before our select() call completes.
   *
   * Safe on empty fields — select() with no content is a no-op.
   */
  selectOnFocus?: boolean
}

const Input = React.forwardRef<HTMLInputElement, InputProps>(
  ({ className, type, selectOnFocus, onFocus, ...props }, ref) => {
    const handleFocus = selectOnFocus
      ? (e: React.FocusEvent<HTMLInputElement>) => {
          const target = e.target
          // rAF runs after the browser positions the cursor from the click event,
          // so our select() always wins on single-click focus.
          requestAnimationFrame(() => target.select())
          onFocus?.(e)
        }
      : onFocus

    return (
      <input
        type={type}
        className={cn(
          'flex h-11 md:h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-base ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-medium file:text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 md:text-sm',
          className,
        )}
        ref={ref}
        onFocus={handleFocus}
        {...props}
      />
    )
  },
)
Input.displayName = 'Input'

export { Input }
