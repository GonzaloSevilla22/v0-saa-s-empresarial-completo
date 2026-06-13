"use client"

import { useCallback, useEffect, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { pythonClient } from "@/lib/api/python-client"
import { Receipt, Download, FileText, AlertTriangle } from "lucide-react"

interface PaymentReceipt {
  id: string
  receipt_number: string | null
  payment_id: string | null
  plan: string | null
  amount: number | null
  created_at: string
  customer_email: string
  customer_name: string | null
}

interface ReceiptsPage {
  items: PaymentReceipt[]
  total: number
}

const PLAN_LABELS: Record<string, string> = {
  gratis: "Gratis", inicial: "Inicial", avanzado: "Avanzado", pro: "Pro",
}

function formatAmount(amount: number | null): string {
  if (amount == null) return "—"
  return new Intl.NumberFormat("es-AR", {
    style: "currency", currency: "ARS", minimumFractionDigits: 2,
  }).format(amount)
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("es-AR", {
    day: "2-digit", month: "2-digit", year: "numeric",
  })
}

export default function AdminPagosPage() {
  const [receipts, setReceipts] = useState<PaymentReceipt[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [downloadingId, setDownloadingId] = useState<string | null>(null)

  const loadData = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) { window.location.href = "/auth/login"; return }

      const { data: profile } = await supabase
        .from("profiles").select("role").eq("id", user.id).single()
      if (!profile || profile.role !== "admin") { window.location.href = "/dashboard"; return }

      const data = await pythonClient.get<ReceiptsPage>("/payments/receipts")
      setReceipts(data.items)
    } catch (err) {
      console.error("Error cargando recibos:", err)
      setError(err instanceof Error ? err.message : "No se pudieron cargar los pagos.")
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { loadData() }, [loadData])

  const downloadReceipt = useCallback(async (r: PaymentReceipt) => {
    setDownloadingId(r.id)
    setError(null)
    try {
      const supabase = createClient()
      const { data: { session } } = await supabase.auth.getSession()
      const token = session?.access_token ?? ""
      const res = await fetch(
        `${process.env.NEXT_PUBLIC_BACKEND_URL}/payments/receipt/${r.id}`,
        { headers: { Authorization: `Bearer ${token}` } },
      )
      if (!res.ok) throw new Error("No se pudo generar el PDF del recibo.")
      const blob = await res.blob()
      const url = URL.createObjectURL(blob)
      window.open(url, "_blank", "noopener,noreferrer")
      setTimeout(() => URL.revokeObjectURL(url), 60_000)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Error al descargar el recibo.")
    } finally {
      setDownloadingId(null)
    }
  }, [])

  return (
    <div className="container mx-auto p-6 max-w-6xl pb-20">
      <header className="flex items-center gap-3 mb-2">
        <Receipt className="w-6 h-6 text-emerald-500" />
        <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Recibos de Pago</h1>
      </header>
      <p className="text-slate-400 mb-8">
        Pagos aprobados de las suscripciones. Descargá el comprobante en PDF de cada uno.
      </p>

      <div className="mb-6 flex items-start gap-2 rounded-lg border border-amber-500/20 bg-amber-500/5 p-3 text-sm text-amber-300/90">
        <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
        <span>
          El envío automático del recibo por email a cada cliente se activa cuando se
          verifique el dominio de correo. Por ahora podés descargar el PDF acá.
        </span>
      </div>

      {error && (
        <div className="mb-6 rounded-lg border border-red-500/20 bg-red-500/10 p-4 text-sm text-red-400">
          {error}
        </div>
      )}

      {loading ? (
        <div className="flex flex-col items-center justify-center py-32 gap-4">
          <div className="h-8 w-8 animate-spin rounded-full border-2 border-emerald-500 border-t-transparent" />
          <p className="text-slate-400 text-sm animate-pulse">Cargando pagos...</p>
        </div>
      ) : receipts.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-24 gap-3 text-center">
          <FileText className="w-10 h-10 text-slate-600" />
          <p className="text-slate-400">Todavía no hay pagos registrados.</p>
        </div>
      ) : (
        <div className="overflow-x-auto rounded-2xl border border-slate-800 bg-slate-900/40 backdrop-blur-md">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-800 text-left text-slate-400">
                <th className="px-4 py-3 font-medium">N° Recibo</th>
                <th className="px-4 py-3 font-medium">Fecha</th>
                <th className="px-4 py-3 font-medium">Cliente</th>
                <th className="px-4 py-3 font-medium">Plan</th>
                <th className="px-4 py-3 font-medium text-right">Monto</th>
                <th className="px-4 py-3 font-medium text-right">Acción</th>
              </tr>
            </thead>
            <tbody>
              {receipts.map((r) => (
                <tr key={r.id} className="border-b border-slate-800/60 last:border-0 hover:bg-slate-800/30">
                  <td className="px-4 py-3 font-mono text-xs text-slate-300">{r.receipt_number ?? "—"}</td>
                  <td className="px-4 py-3 text-slate-300">{formatDate(r.created_at)}</td>
                  <td className="px-4 py-3">
                    <div className="text-slate-200">{r.customer_name ?? "—"}</div>
                    <div className="text-xs text-slate-500">{r.customer_email}</div>
                  </td>
                  <td className="px-4 py-3 text-slate-300">{PLAN_LABELS[r.plan ?? ""] ?? r.plan ?? "—"}</td>
                  <td className="px-4 py-3 text-right font-semibold text-slate-100">{formatAmount(r.amount)}</td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => downloadReceipt(r)}
                      disabled={downloadingId === r.id}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-1.5 text-xs font-medium text-emerald-400 transition-colors hover:bg-emerald-500/20 disabled:opacity-50"
                    >
                      <Download className="w-3.5 h-3.5" />
                      {downloadingId === r.id ? "Generando..." : "Descargar PDF"}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
