"use client"

/**
 * IdleWarningModal — accessible warning dialog shown before automatic idle logout.
 *
 * Design decision (design.md §Decision 9):
 *   Uses shadcn/ui Dialog (Radix) for built-in focus trap and Escape handling.
 *   Escape key is treated as "Seguir conectado" (stay connected).
 *   Countdown is in an aria-live="assertive" region (time-critical security prompt).
 *
 * This component is purely presentational:
 *   - It does NOT own the countdown interval.
 *   - The parent (IdleTimeoutProvider) passes `secondsRemaining` and calls reset.
 *   - ESC closes the dialog via Radix, and onOpenChange is wired to onStayConnected.
 */

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"

export interface IdleWarningModalProps {
  /** Whether the dialog is visible. */
  isOpen: boolean
  /** Seconds remaining until idle logout. Passed by the provider. */
  secondsRemaining: number
  /** Called when the user chooses to stay connected (button click or Escape). */
  onStayConnected: () => void
}

export function IdleWarningModal({
  isOpen,
  secondsRemaining,
  onStayConnected,
}: IdleWarningModalProps) {
  return (
    <Dialog
      open={isOpen}
      // Radix calls onOpenChange(false) when the user presses Escape or clicks
      // the overlay — both treated as "stay connected" per Decision 9.
      onOpenChange={(open) => {
        if (!open) onStayConnected()
      }}
    >
      <DialogContent
        // Suppress the default Radix close button (X) — only the explicit
        // "Seguir conectado" action should be visible.
        onPointerDownOutside={(e) => e.preventDefault()}
        onEscapeKeyDown={(e) => {
          e.preventDefault()
          onStayConnected()
        }}
      >
        <DialogHeader>
          <DialogTitle>Sesión por vencer</DialogTitle>
          <DialogDescription>
            Tu sesión se cerrará pronto por inactividad.
          </DialogDescription>
        </DialogHeader>

        {/* Countdown — aria-live="assertive" announces changes to screen readers. */}
        <div
          role="status"
          aria-live="assertive"
          aria-atomic="true"
          className="text-center py-4"
        >
          <span className="text-4xl font-bold tabular-nums text-foreground">
            {secondsRemaining}
          </span>
          <p className="mt-2 text-sm text-muted-foreground">
            Tu sesión se cerrará en {secondsRemaining}s
          </p>
        </div>

        <DialogFooter>
          <Button
            onClick={onStayConnected}
            className="w-full sm:w-auto"
            autoFocus
          >
            Seguir conectado
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
