"use client"

import { useQuery, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { useExportUsage, triggerExport } from "@/hooks/auth/use-export-usage"
import { ExportButton } from "@/components/export/ExportButton"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Progress } from "@/components/ui/progress"
import { toast } from "@/hooks/use-toast"
import { Download, RefreshCw, FileText, FileSpreadsheet, Clock } from "lucide-react"
import { formatDate } from "@/lib/format"
import type { ExportLog, ExportType } from "@/lib/types"

const EXPORT_LABELS: Record<ExportType, string> = {
  sales_csv:        "Ventas CSV",
  purchases_csv:    "Compras CSV",
  expenses_csv:     "Gastos CSV",
  stock_csv:        "Inventario CSV",
  full_report_xlsx: "Reporte Completo XLSX",
}

function ExportIcon({ exportType }: { exportType: ExportType }) {
  if (exportType === "full_report_xlsx")
    return <FileSpreadsheet className="h-4 w-4 text-green-500" />
  return <FileText className="h-4 w-4 text-blue-500" />
}

function isExpired(expiresAt: string | null): boolean {
  if (!expiresAt) return true
  return new Date(expiresAt) < new Date()
}

function mapRow(r: Record<string, unknown>): ExportLog {
  return {
    id:                 r.id as string,
    userId:             r.user_id as string,
    orgId:              (r.org_id as string) ?? null,
    exportType:         r.export_type as ExportType,
    filePath:           r.file_path as string,
    signedUrl:          (r.signed_url as string) ?? null,
    signedUrlExpiresAt: (r.signed_url_expires_at as string) ?? null,
    status:             (r.status as ExportLog["status"]) ?? "generated",
    createdAt:          r.created_at as string,
  }
}

export default function ExportacionesPage() {
  const { user } = useAuth()
  const supabase = createClient()
  const queryClient = useQueryClient()
  const { exportsUsed, exportsRemaining, exportsLimit, isLoading: limitsLoading } = useExportUsage()

  // ── Load export history for current month ─────────────────────────────────
  const startOfMonth = new Date()
  startOfMonth.setDate(1)
  startOfMonth.setHours(0, 0, 0, 0)

  const { data: logs = [], isLoading: logsLoading } = useQuery({
    queryKey: ["exportLogs", user?.id],
    queryFn: async (): Promise<ExportLog[]> => {
      const { data } = await supabase
        .from("export_logs")
        .select("*")
        .gte("created_at", startOfMonth.toISOString())
        .order("created_at", { ascending: false })
        .limit(100)
      return (data ?? []).map(mapRow)
    },
    enabled: !!user,
    staleTime: 30_000,
  })

  // ── Regenerate an expired export ──────────────────────────────────────────
  async function handleRegenerate(exportType: ExportType) {
    const { data: session } = await supabase.auth.getSession()
    const token = session?.session?.access_token
    if (!token) return

    const result = await triggerExport(exportType, token)
    if (!result.ok) {
      toast({ title: "No se pudo regenerar", description: result.error, variant: "destructive" })
      return
    }
    if (result.signedUrl) {
      const a = document.createElement("a")
      a.href = result.signedUrl
      a.download = `${exportType}-${new Date().toISOString().split("T")[0]}.${exportType.endsWith("xlsx") ? "xlsx" : "csv"}`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
    }
    toast({ title: "Exportación regenerada" })
    queryClient.invalidateQueries({ queryKey: ["exportLogs", user?.id] })
    queryClient.invalidateQueries({ queryKey: ["exportUsage", user?.id] })
  }

  const quotaPct = exportsLimit > 0 ? Math.round((exportsUsed / exportsLimit) * 100) : 0

  return (
    <div className="flex flex-col gap-6">
      {/* ── Header ─────────────────────────────────────────────────────────── */}
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Exportaciones</h1>
        <p className="text-sm text-muted-foreground mt-1">Descargá tus datos en CSV o Excel</p>
      </div>

      {/* ── Quota card ─────────────────────────────────────────────────────── */}
      {!limitsLoading && (
        <div className="rounded-lg border border-border bg-card p-4 flex flex-col gap-3">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-foreground">
              Exportaciones usadas este mes
            </span>
            <span className="text-sm tabular-nums text-muted-foreground">
              {exportsLimit === 0
                ? "No disponible en tu plan"
                : `${exportsUsed} / ${exportsLimit}`
              }
            </span>
          </div>
          {exportsLimit > 0 && (
            <Progress value={quotaPct} className="h-2" />
          )}
          {exportsLimit > 0 && exportsRemaining > 0 && (
            <p className="text-xs text-muted-foreground">
              Te quedan <span className="font-medium text-foreground">{exportsRemaining}</span> exportaciones para este mes.
              La cuota se renueva el 1ro del mes próximo.
            </p>
          )}
          {exportsLimit > 0 && exportsRemaining === 0 && (
            <p className="text-xs text-amber-500">
              Cuota mensual agotada. Se renueva el 1ro del mes próximo.
            </p>
          )}
        </div>
      )}

      {/* ── New export — full report ────────────────────────────────────────── */}
      <div className="rounded-lg border border-border bg-card p-4 flex flex-col gap-3">
        <p className="text-sm font-medium text-foreground">Reporte completo (todas las entidades)</p>
        <p className="text-xs text-muted-foreground">
          Un archivo XLSX con hojas de Ventas, Compras, Gastos e Inventario.
        </p>
        <div>
          <ExportButton exportType="full_report_xlsx" />
        </div>
      </div>

      {/* ── Quick exports ───────────────────────────────────────────────────── */}
      <div className="rounded-lg border border-border bg-card p-4 flex flex-col gap-3">
        <p className="text-sm font-medium text-foreground">Exportar por módulo</p>
        <div className="flex flex-wrap gap-2">
          <ExportButton exportType="sales_csv" />
          <ExportButton exportType="purchases_csv" />
          <ExportButton exportType="expenses_csv" />
          <ExportButton exportType="stock_csv" />
        </div>
      </div>

      {/* ── Export history ──────────────────────────────────────────────────── */}
      <div className="flex flex-col gap-3">
        <h2 className="text-base font-semibold text-foreground">Historial del mes</h2>

        {logsLoading && (
          <p className="text-sm text-muted-foreground">Cargando historial...</p>
        )}

        {!logsLoading && logs.length === 0 && (
          <div className="rounded-lg border border-dashed border-border bg-card/50 py-10 flex flex-col items-center gap-2">
            <Download className="h-8 w-8 text-muted-foreground/40" />
            <p className="text-sm text-muted-foreground">No hay exportaciones este mes</p>
          </div>
        )}

        {!logsLoading && logs.length > 0 && (
          <div className="rounded-lg border border-border overflow-hidden">
            <table className="w-full text-sm">
              <thead className="bg-muted/40 border-b border-border">
                <tr>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Tipo</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Fecha</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Estado</th>
                  <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">Acción</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {logs.map((log) => {
                  const expired = isExpired(log.signedUrlExpiresAt)
                  return (
                    <tr key={log.id} className="bg-card hover:bg-muted/20 transition-colors">
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-2">
                          <ExportIcon exportType={log.exportType} />
                          <span className="text-foreground">{EXPORT_LABELS[log.exportType]}</span>
                        </div>
                      </td>
                      <td className="px-4 py-3 text-muted-foreground tabular-nums">
                        {formatDate(log.createdAt)}
                      </td>
                      <td className="px-4 py-3">
                        {expired
                          ? <Badge variant="outline" className="text-muted-foreground gap-1">
                              <Clock className="h-3 w-3" />Vencido
                            </Badge>
                          : <Badge variant="outline" className="text-green-500 border-green-500/30 gap-1">
                              <Download className="h-3 w-3" />Disponible
                            </Badge>
                        }
                      </td>
                      <td className="px-4 py-3 text-right">
                        {!expired && log.signedUrl ? (
                          <Button variant="ghost" size="sm" asChild>
                            <a href={log.signedUrl} download>
                              <Download className="h-4 w-4 mr-1" />Descargar
                            </a>
                          </Button>
                        ) : (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => handleRegenerate(log.exportType)}
                          >
                            <RefreshCw className="h-4 w-4 mr-1" />Regenerar
                          </Button>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
