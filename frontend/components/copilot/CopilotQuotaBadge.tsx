"use client"

import { Gauge } from "lucide-react"
import { Badge } from "@/components/ui/badge"

interface CopilotQuotaBadgeProps {
  remaining: number
  /** Consultas por mes del plan; 0 mientras el plan no cargó (no se muestra nada). */
  limit: number
  isLoading: boolean
}

/** «Te quedan N consultas este mes» (ia-copilot-v2, D11). El aviso de 0 vive en el chat. */
export function CopilotQuotaBadge({ remaining, limit, isLoading }: CopilotQuotaBadgeProps) {
  if (isLoading || limit <= 0) return null
  const text =
    remaining === 0
      ? "Sin consultas este mes"
      : remaining === 1
        ? "Te queda 1 consulta este mes"
        : `Te quedan ${remaining} consultas este mes`
  return (
    <Badge variant="secondary" className="gap-1.5 font-normal">
      <Gauge className="h-3.5 w-3.5" aria-hidden="true" />
      <span>{text}</span>
    </Badge>
  )
}
