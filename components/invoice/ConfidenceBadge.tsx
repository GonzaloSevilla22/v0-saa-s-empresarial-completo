import { cn } from "@/lib/utils"
import type { MatchType } from "@/lib/invoice-types"

interface Props {
  confidence: number   // 0–1
  matchType:  MatchType
  className?: string
}

const labels: Record<MatchType, string> = {
  exact_barcode: "Código de barras",
  exact_name:    "Exacto",
  alias:         "Alias conocido",
  high:          "Alta similitud",
  partial:       "Coincidencia parcial",
  none:          "Sin match",
}

export function ConfidenceBadge({ confidence, matchType, className }: Props) {
  const pct = Math.round(confidence * 100)
  const color =
    pct >= 95 ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-400" :
    pct >= 75 ? "border-yellow-500/40 bg-yellow-500/10 text-yellow-400" :
    pct >= 50 ? "border-orange-500/40 bg-orange-500/10 text-orange-400" :
                "border-red-500/40 bg-red-500/10 text-red-400"

  return (
    <span className={cn(
      "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] font-medium tabular-nums",
      color, className,
    )}>
      {labels[matchType]} · {pct}%
    </span>
  )
}