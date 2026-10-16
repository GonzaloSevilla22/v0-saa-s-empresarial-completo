"use client"

/**
 * PurchaseCheckoutSuccess — el panel final de una compra registrada desde un
 * documento (remitos-compra tanda B, D11, task 7.5): "Compra registrada" +
 * "Ver en Compras" + "Cerrar".
 *
 * Es el gemelo mínimo de `SaleCheckoutSuccess`, SIN lo que es de venta (Facturar:
 * una compra no emite comprobante propio). Misma accesibilidad: al aparecer, el
 * foco va al título (el contenedor lo anuncia y el usuario sigue desde ahí con el
 * teclado).
 */

import { useEffect, useRef } from "react"
import Link from "next/link"
import { CheckCircle2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { formatMoney } from "@/lib/format"

interface PurchaseCheckoutSuccessProps {
  total: number
  /** La clave ya había registrado esta compra: se muestra igual, avisando. */
  replayed?: boolean
  onClose: () => void
  /** Destino de "Ver en Compras". */
  viewHref?: string
}

export function PurchaseCheckoutSuccess({
  total,
  replayed = false,
  onClose,
  viewHref = "/compras",
}: PurchaseCheckoutSuccessProps) {
  const titleRef = useRef<HTMLHeadingElement>(null)

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
            Compra registrada
          </h2>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Total <span className="font-medium tabular-nums text-foreground">{formatMoney(total, "ARS")}</span>
          </p>
          {replayed && (
            <p className="mt-1 text-xs text-muted-foreground">
              Esta compra ya estaba registrada: no se registró dos veces.
            </p>
          )}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button asChild variant="outline" size="sm">
          <Link href={viewHref}>Ver en Compras</Link>
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onClose}>
          Cerrar
        </Button>
      </div>
    </div>
  )
}
