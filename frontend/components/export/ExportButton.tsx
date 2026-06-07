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
import { toast } from "@/hooks/use-toast"
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
        toast({ title: "No autenticado", variant: "destructive" })
        return
      }

      const result = await triggerExport(exportType, token)

      if (!result.ok) {
        if (result.error === "quota_exceeded") {
          toast({
            title: "Cuota agotada",
            description: "Ya usaste todas tus exportaciones del mes.",
            variant: "destructive",
          })
          queryClient.invalidateQueries({ queryKey: ["exportUsage", user?.id] })
        } else {
          toast({ title: "Error al exportar", description: result.error, variant: "destructive" })
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

      toast({ title: "Exportación lista", description: "El archivo se descargó correctamente." })
      // Refresh counter
      queryClient.invalidateQueries({ queryKey: ["exportUsage", user?.id] })
      queryClient.invalidateQueries({ queryKey: ["exportLogs", user?.id] })

    } catch {
      toast({ title: "Error inesperado al exportar", variant: "destructive" })
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
          {label}
          {quotaText && (
            <span className="ml-1.5 text-xs text-muted-foreground">({quotaText})</span>
          )}
        </Button>
      </TooltipTrigger>
      {reason === "quota_exceeded" && (
        <TooltipContent>Cuota mensual agotada. Se renueva el 1ro del próximo mes.</TooltipContent>
      )}
    </Tooltip>
  )
}
