"use client"

/**
 * SaleCheckoutSuccess — el panel final de una venta registrada
 * (presupuestos-modulo D12, task 6.9): "Venta registrada" + Facturar + "Ver en
 * Ventas" + "Cerrar".
 *
 * No conoce el presupuesto: lo reutiliza cualquier cierre de venta
 * (`remitos-venta`). Accesibilidad: al aparecer, el foco va al título (el
 * contenedor lo anuncia y el usuario sigue desde ahí con el teclado).
 * "Facturar" es el `EmitInvoiceButton` de siempre: la venta queda `confirmed` y
 * sin comprobante (la facturación es una acción posterior explícita) y el botón
 * resuelve el punto de venta por su cuenta.
 */

import { useEffect, useRef } from "react"
import Link from "next/link"
import { CheckCircle2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { EmitInvoiceButton } from "@/components/fiscal/EmitInvoiceButton"
import { useFiscalProfile } from "@/hooks/data/use-fiscal-profile"
import { formatMoney } from "@/lib/format"

interface SaleCheckoutSuccessProps {
  salesOrderId: string
  total: number
  /** La clave ya había registrado esta venta: se muestra igual, avisando. */
  replayed?: boolean
  onClose: () => void
  /** Destino de "Ver en Ventas". */
  viewHref?: string
}

export function SaleCheckoutSuccess({
  salesOrderId,
  total,
  replayed = false,
  onClose,
  viewHref = "/ventas",
}: SaleCheckoutSuccessProps) {
  const titleRef = useRef<HTMLHeadingElement>(null)
  const { profile } = useFiscalProfile()

  useEffect(() => {
    titleRef.current?.focus()
  }, [])

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <div className="flex items-start gap-3">
        <CheckCircle2 className="mt-0.5 h-6 w-6 shrink-0 text-success" aria-hidden="true" />
        <div className="min-w-0">
          <h2
            ref={titleRef}
            tabIndex={-1}
            className="text-lg font-semibold text-foreground outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Venta registrada
          </h2>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Total <span className="font-medium tabular-nums text-foreground">{formatMoney(total, "ARS")}</span>
          </p>
          {replayed && (
            <p className="mt-1 text-xs text-muted-foreground">
              Esta venta ya estaba registrada: no se cobró dos veces.
            </p>
          )}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <EmitInvoiceButton
          salesOrderId={salesOrderId}
          salesOrderStatus="confirmed"
          fiscalDocumentId={null}
          ivaConditionEmisor={profile?.ivaCondition ?? null}
        />
        <Button asChild variant="outline" size="sm">
          <Link href={viewHref}>Ver en Ventas</Link>
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onClose}>
          Cerrar
        </Button>
      </div>
    </div>
  )
}
