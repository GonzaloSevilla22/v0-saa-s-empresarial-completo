"use client"

import { Card, CardContent } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import type { Insight, InsightPriority } from "@/lib/types"
import { TrendingUp, AlertTriangle, Info } from "lucide-react"

const priorityConfig: Record<InsightPriority, { color: string; icon: typeof TrendingUp; label: string }> = {
  alta: { color: "bg-red-500/20 text-red-400 border-red-500/30", icon: AlertTriangle, label: "Alta" },
  media: { color: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30", icon: TrendingUp, label: "Media" },
  baja: { color: "bg-emerald-500/20 text-emerald-400 border-emerald-500/30", icon: Info, label: "Baja" },
}

export function InsightCard({ insight }: { insight: Insight }) {
  const config = priorityConfig[insight.priority]
  const Icon = config.icon

  return (
    <Card className="border-border bg-card hover:border-primary/30 transition-colors">
      <CardContent className="p-4">
        <div className="flex items-start gap-3">
          <div className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-md ${
            insight.priority === "alta" ? "bg-red-500/10" :
            insight.priority === "media" ? "bg-yellow-500/10" : "bg-emerald-500/10"
          }`}>
            <Icon className={`h-4 w-4 ${
              insight.priority === "alta" ? "text-red-400" :
              insight.priority === "media" ? "text-yellow-400" : "text-emerald-400"
            }`} />
          </div>
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <Badge variant="outline" className={`text-[10px] ${config.color}`}>
                {config.label}
              </Badge>
              <span className="text-[10px] text-muted-foreground capitalize">{insight.type}</span>
            </div>
            <p className="text-sm text-card-foreground leading-relaxed">{insight.message}</p>
            <p className="text-[10px] text-muted-foreground mt-2">
              {new Date(insight.date + "T12:00:00").toLocaleDateString("es-AR")}
            </p>
          </div>
        </div>
      </CardContent>
    </Card>
  )
}
