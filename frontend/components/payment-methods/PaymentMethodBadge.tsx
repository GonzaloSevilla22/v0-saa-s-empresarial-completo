/**
 * PaymentMethodBadge — canonización del badge de forma de pago
 * (gastos-forma-pago, D16 / task 8.2-8.3).
 *
 * Reemplaza 4 duplicaciones LITERALES ya existentes:
 *   · `components/ventas/sale-operations-list.tsx` (mobile + desktop)
 *   · `components/compras/purchase-operations-list.tsx` (mobile + desktop)
 * y evita las dos que agregaría el listado de gastos (serían 6).
 *
 * D17: tonos SEMÁNTICOS del design system (`text-muted-foreground` sobre la
 * variante `outline` de `Badge`, resuelta por cva). Está explícitamente
 * prohibido copiar el estilo de `categoryColors` de `gastos/page.tsx`
 * (`bg-blue-500/20 text-blue-400 …`) — literales de Tailwind, el patrón que
 * `tokens-contraste-aa` (#406-#408) desterró y que el gate
 * `token-contrast-aa.test.ts` custodia.
 */

import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { KIND_LABELS, UNASSIGNED_PAYMENT_METHOD_LABEL } from "@/lib/payment-method-meta"
import type { PaymentMethodKind } from "@/lib/types"

export interface PaymentMethodBadgeProps {
  /** Nombre resuelto por el backend (`payment_method_name`). Ausente/vacío = sin imputar. */
  name?: string | null
  /**
   * `kind` del catálogo, cuando la fila lo trae. Sólo alimenta el título
   * accesible: el badge NO cambia de color por kind (sería inventar una
   * semántica de color que el design system no tiene).
   */
  kind?: PaymentMethodKind | null
  /**
   * `block` (default): ocupa el ancho de su contenido — columna mobile.
   * `inline`: no se encoge dentro de una fila con texto truncado — desktop.
   * Son las dos variantes que ya usaban las 4 duplicaciones.
   */
  layout?: "block" | "inline"
  className?: string
}

export function PaymentMethodBadge({
  name,
  kind,
  layout = "block",
  className,
}: PaymentMethodBadgeProps) {
  const label = name?.trim() ? name.trim() : UNASSIGNED_PAYMENT_METHOD_LABEL

  return (
    <Badge
      variant="outline"
      data-testid="payment-method-badge"
      title={kind ? KIND_LABELS[kind] : undefined}
      className={cn(
        "text-[10px] text-muted-foreground",
        layout === "inline" ? "shrink-0" : "w-fit",
        className,
      )}
    >
      {label}
    </Badge>
  )
}
