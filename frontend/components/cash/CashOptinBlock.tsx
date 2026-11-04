"use client"

/**
 * CashOptinBlock — el bloque «Registrar en caja» de las operaciones en efectivo
 * (fix `caja-optin-carga`).
 *
 * Vivía copiado a mano en cinco consumidores (venta, gasto, compra, cobro y pago
 * de cuenta corriente) con los mismos tres estados. Al sumar el cuarto se extrae
 * en vez de copiar el cambio cinco veces. Es presentacional: el estado lo resuelve
 * `useCashOptin` y el padre decide el default de la casilla (la venta nace
 * desmarcada, el resto pre-marcada — asimetría deliberada que NO se toca acá).
 *
 * Estados, en este orden de prioridad:
 *   1. cargando — `cash.isLoading`: todavía se averigua si hay sesión abierta. Se
 *      dice «Verificando la caja…» y NO se afirma «no hay caja» (sería mentira
 *      hasta que resuelva). Es un `role="status"` con `aria-live="polite"` para que
 *      el lector de pantalla anuncie por qué el botón de confirmar está bloqueado.
 *   2. elegible — la casilla, con el prefijo de la sesión.
 *   3. no elegible — el motivo concreto como nota; nunca se oculta en silencio.
 */

import { AlertCircle, Loader2 } from "lucide-react"
import { Checkbox } from "@/components/ui/checkbox"
import type { CashOptinState } from "@/hooks/use-cash-optin"
import { CASH_OPTIN_PENDING_TEXT } from "@/lib/cash-optin"

interface CashOptinBlockProps {
  cash: CashOptinState
  /** Intención del usuario de registrar la operación en la caja. */
  registerInCash: boolean
  onRegisterInCashChange: (value: boolean) => void
}

export function CashOptinBlock({ cash, registerInCash, onRegisterInCashChange }: CashOptinBlockProps) {
  return (
    <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
      {cash.isLoading ? (
        <div role="status" aria-live="polite" className="flex items-center gap-2 text-muted-foreground">
          <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin" aria-hidden="true" />
          <span>{CASH_OPTIN_PENDING_TEXT}</span>
        </div>
      ) : cash.eligible ? (
        <label className="flex items-center gap-2 cursor-pointer text-foreground">
          <Checkbox
            checked={registerInCash}
            onCheckedChange={(v) => onRegisterInCashChange(v === true)}
          />
          <span>Registrar en caja — sesión {cash.session?.id.slice(0, 8)}…</span>
        </label>
      ) : (
        <div role="note" className="flex items-center gap-2 text-muted-foreground">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" aria-hidden="true" />
          <span>{cash.reason}</span>
        </div>
      )}
    </div>
  )
}
