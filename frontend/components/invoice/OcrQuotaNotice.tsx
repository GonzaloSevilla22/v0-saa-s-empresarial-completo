"use client"

import Link from "next/link"
import { Gauge, AlertTriangle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { formatAiResetDate, nextAiResetDate } from "@/lib/ai-usage"

interface Props {
  /** Lecturas de factura que le quedan al usuario este mes. */
  remaining: number
  /** Lecturas de factura por mes del plan efectivo. */
  limit: number
  /** Inyectable para tests; por defecto, ahora. */
  now?: Date
}

/**
 * Cupo mensual de lecturas de factura con IA (v31-ia-ratelimit-budget, D8). Con saldo es una
 * línea informativa; sin saldo explica el límite del plan, cuándo se renueva y ofrece «Ver
 * planes». Sólo tokens semánticos del design system (nada de colores literales).
 */
export function OcrQuotaNotice({ remaining, limit, now }: Props) {
  if (remaining > 0) {
    const text = remaining === 1
      ? "Te queda 1 lectura de factura este mes"
      : `Te quedan ${remaining} lecturas de factura este mes`
    return (
      <p className="flex items-center gap-2 rounded-lg border border-border bg-muted/50 px-3 py-2 text-sm text-muted-foreground">
        <Gauge className="h-4 w-4 shrink-0" aria-hidden="true" />
        <span>{text}</span>
      </p>
    )
  }

  const renewal = formatAiResetDate(nextAiResetDate(now ?? new Date()))
  return (
    <div className="flex flex-col gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4">
      <p className="flex items-start gap-2 text-sm text-foreground">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
        <span>
          {`Usaste las ${limit} lecturas de factura de tu plan este mes. Se renuevan el ${renewal}.`}
        </span>
      </p>
      <Button asChild size="sm" className="self-start">
        <Link href="/planes">Ver planes</Link>
      </Button>
    </div>
  )
}
