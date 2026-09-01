"use client"

import { useState } from "react"
import Link from "next/link"
import { Download, Crown, Loader2 } from "lucide-react"
import { createClient } from "@/lib/supabase/client"
import { useExportUsage, triggerExport } from "@/hooks/auth/use-export-usage"
import { useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
// G7 (H7): sonner es el ÚNICO sistema de toast montado en la app
// (app/layout.tsx) — el de @/hooks/use-toast emitía a un <Toaster /> que no
// existe en ningún layout, así que las 5 ramas eran invisibles (D5).
import { toast } from "sonner"
import type { ExportType } from "@/lib/types"

const EXPORT_LABELS: Record<ExportType, string> = {
  sales_csv:          "Exportar ventas CSV",
  purchases_csv:      "Exportar compras CSV",
  expenses_csv:       "Exportar gastos CSV",
  stock_csv:          "Exportar inventario CSV",
  full_report_xlsx:   "Exportar reporte completo XLSX",
}

interface ExportButtonProps {
  exportType: ExportType
  variant?: "default" | "outline" | "ghost"
  size?: "default" | "sm" | "lg"
  className?: string
}

export function ExportButton({
  exportType,
  variant = "outline",
  size = "sm",
  className,
}: ExportButtonProps) {
  const { user } = useAuth()
  const { exportsRemaining, exportsLimit, isLoading, canExport } = useExportUsage()
  const queryClient = useQueryClient()
  const supabase = createClient()
  const [loading, setLoading] = useState(false)

  if (isLoading || !user) return null

  const { allowed, reason } = canExport()

  // Plan gratis: replace button with upgrade CTA
  if (reason === "plan_gratis") {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <Button asChild variant="outline" size={size} className={className}>
            <Link href="/planes">
              <Crown className="h-4 w-4 mr-1.5 text-yellow-500" />
              Exportar
            </Link>
          </Button>
        </TooltipTrigger>
        <TooltipContent>Requiere plan Inicial o superior</TooltipContent>
      </Tooltip>
    )
  }

  async function handleExport() {
    if (!allowed || loading) return

    setLoading(true)
    try {
      const { data: session } = await supabase.auth.getSession()
      const token = session?.session?.access_token
      if (!token) {
        toast.error("No autenticado")
        return
      }

      const result = await triggerExport(exportType, token)

      if (!result.ok) {
        if (result.error === "quota_exceeded") {
          toast.error("Cuota agotada", {
            description: "Ya usaste todas tus exportaciones del mes.",
          })
          queryClient.invalidateQueries({ queryKey: ["exportUsage", user?.id] })
        } else {
          toast.error("Error al exportar", { description: result.error })
        }
        return
      }

      // Trigger browser download via signed URL
      if (result.signedUrl) {
        const a = document.createElement("a")
        a.href = result.signedUrl
        a.download = `${exportType.replace("_", "-")}-${new Date().toISOString().split("T")[0]}.${exportType.endsWith("xlsx") ? "xlsx" : "csv"}`
        document.body.appendChild(a)
        a.click()
        document.body.removeChild(a)
      }

      toast.success("Exportación lista", {
        description: "El archivo se descargó correctamente.",
      })
      // Refresh counter
      queryClient.invalidateQueries({ queryKey: ["exportUsage", user?.id] })
      queryClient.invalidateQueries({ queryKey: ["exportLogs", user?.id] })

    } catch {
      toast.error("Error inesperado al exportar")
    } finally {
      setLoading(false)
    }
  }

  const label = EXPORT_LABELS[exportType]
  const quotaText = exportsLimit > 0 ? `${exportsRemaining} restante${exportsRemaining !== 1 ? "s" : ""}` : ""
  const disabled = !allowed || loading

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant={variant}
          size={size}
          className={className}
          disabled={disabled}
          onClick={handleExport}
        >
          {loading
            ? <Loader2 className="h-4 w-4 mr-1.5 animate-spin" />
            : <Download className="h-4 w-4 mr-1.5" />
          }
          {/* qa-integral-modulos G2 (H2/2.5): colapso responsive de la
              etiqueta — "Exportar inventario CSV (50 restantes)" medía hasta
              295 px de una pieza; mismo patrón hidden sm:inline que sus
              hermanos de barra. */}
          <span className="hidden sm:inline">{label}</span>
          <span className="sm:hidden">Exportar</span>
          {quotaText && (
            <span className="ml-1.5 text-xs text-muted-foreground hidden sm:inline">({quotaText})</span>
          )}
        </Button>
      </TooltipTrigger>
      {reason === "quota_exceeded" && (
        <TooltipContent>Cuota mensual agotada. Se renueva el 1ro del próximo mes.</TooltipContent>
      )}
    </Tooltip>
  )
}
