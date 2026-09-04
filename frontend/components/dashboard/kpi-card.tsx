"use client"

import Link from "next/link"
import { Card, CardContent } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { LucideIcon } from "lucide-react"

interface KpiCardProps {
  title: string
  value: string
  change?: number
  icon: LucideIcon
  iconColor?: string
  /**
   * cobranzas-panel (D7): convierte la tarjeta entera en un enlace con foco
   * visible. Definido acá, en la capa canónica, para que el área clickeable
   * y el aria queden resueltos UNA vez para todas las tarjetas — no envolver
   * en <Link> ad-hoc desde las páginas.
   */
  href?: string
  /**
   * estadisticas-ventas E1 (task 4.4): rótulo de la variación. Las tarjetas
   * del Tablero comparan contra ayer; las del módulo de estadísticas, contra
   * el período anterior de igual longitud. Default = comportamiento previo.
   */
  changeLabel?: string
  /**
   * estadisticas-ventas E3 (task 9.4): nota breve bajo el valor cuando no
   * hay variación que mostrar (p. ej. la marca de cobertura del margen,
   * "25% con costo" — D11). Se ignora si `change` está definido.
   */
  caption?: string
}

export function KpiCard({ title, value, change, icon: Icon, iconColor = "text-primary", href, changeLabel = "vs ayer", caption }: KpiCardProps) {
  const card = (
    <Card
      className={cn(
        "border-border bg-card",
        href && "transition-colors hover:border-primary/50",
      )}
    >
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
                  change >= 0 ? "text-success" : "text-destructive"
                )}
              >
                {change >= 0 ? "+" : ""}
                {change}% {changeLabel}
              </span>
            )}
            {change === undefined && caption && (
              <span className="text-xs text-muted-foreground">{caption}</span>
            )}
          </div>
          <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/10", iconColor)}>
            <Icon className="h-5 w-5" />
          </div>
        </div>
      </CardContent>
    </Card>
  )

  if (href) {
    return (
      <Link
        href={href}
        className="block rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
      >
        {card}
      </Link>
    )
  }

  return card
}
