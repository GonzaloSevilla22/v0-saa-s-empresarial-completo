"use client"

import { Card, CardContent } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { LucideIcon } from "lucide-react"

interface KpiCardProps {
  title: string
  value: string
  change?: number
  icon: LucideIcon
  iconColor?: string
}

export function KpiCard({ title, value, change, icon: Icon, iconColor = "text-primary" }: KpiCardProps) {
  return (
    <Card className="border-border bg-card">
      <CardContent className="p-4 md:p-6">
        <div className="flex items-start justify-between">
          <div className="flex flex-col gap-1">
            <span className="text-xs font-medium text-muted-foreground uppercase tracking-wider">
              {title}
            </span>
            <span className="text-2xl font-bold text-card-foreground tracking-tight">
              {value}
            </span>
            {change !== undefined && (
              <span
                className={cn(
                  "text-xs font-medium",
                  change >= 0 ? "text-emerald-400" : "text-red-400"
                )}
              >
                {change >= 0 ? "+" : ""}
                {change}% vs ayer
              </span>
            )}
          </div>
          <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/10", iconColor)}>
            <Icon className="h-5 w-5" />
          </div>
        </div>
      </CardContent>
    </Card>
  )
}
