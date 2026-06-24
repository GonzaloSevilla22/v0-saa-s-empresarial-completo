"use client"

/**
 * v22-afip-delegation-billing — Admin Pagos page.
 *
 * Lista recibos de pago de suscripciones. Por cada recibo el admin puede:
 *   - Descargar PDF
 *   - Reenviar por email
 *   - Enviar al ARCA (emitir Factura C ante AFIP) — NUEVO v22
 *
 * Idempotency: en el cargado inicial, cada recibo consulta si ya tiene un
 * fiscal_document vinculado (GET /fiscal/documents/by-receipt/{id}). Si lo
 * tiene, muestra el FiscalDocumentBadge en lugar del botón "Enviar al ARCA".
 *
 * El dialog EmitirSuscripcionDialog captura el CUIT/DNI del receptor.
 * La emisión es SIEMPRE deliberada — el admin confirma explícitamente.
 *
 * Design ref: v22 admin-subscription-invoicing — PO sign-off 2026-06-24.
 */

import { useCallback, useEffect, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { pythonClient } from "@/lib/api/python-client"
import { Receipt, Download, FileText, AlertTriangle, Send, CheckCircle2, FileCheck } from "lucide-react"
import { FiscalDocumentBadge, type FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"
import { EmitirSuscripcionDialog, type SubscriptionReceipt } from "@/components/fiscal/EmitirSuscripcionDialog"
import { useEmitSubscriptionPayment } from "@/hooks/data/use-emit-subscription-payment"
import { usePointsOfSale } from "@/hooks/data/use-points-of-sale"
import { translateEmitError, isDelegationError } from "@/hooks/data/use-emit-comprobante"
import type { EmitSubscriptionPaymentInput } from "@/hooks/data/use-emit-subscription-payment"

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

/** Fiscal doc state for a receipt row (loaded on page init for idempotency). */
interface RowFiscalState {
  documentId: string
  status: FiscalDocumentStatus
  cae?: string | null
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
  const [notice, setNotice] = useState<string | null>(null)
  const [downloadingId, setDownloadingId] = useState<string | null>(null)
  const [resendingId, setResendingId] = useState<string | null>(null)

  // ── v22: Enviar al ARCA ────────────────────────────────────────────────────
  const [dialogOpen, setDialogOpen] = useState(false)
  const [selectedReceipt, setSelectedReceipt] = useState<PaymentReceipt | null>(null)
  /** Map receiptId → fiscal doc state for rows already invoiced */
  const [fiscalStates, setFiscalStates] = useState<Record<string, RowFiscalState>>({})

  const emitMutation = useEmitSubscriptionPayment()
  const { pointsOfSale, isLoading: pvLoading } = usePointsOfSale()

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

      // Idempotency: load fiscal doc state for each receipt in parallel
      // Only the receipts we don't already know about (on re-loads, keep existing)
      const existing = fiscalStates
      const newStates: Record<string, RowFiscalState> = { ...existing }

      await Promise.all(
        data.items
          .filter((r) => !(r.id in existing))
          .map(async (r) => {
            try {
              const doc = await pythonClient.get<{
                id: string
                status: FiscalDocumentStatus
                cae?: string | null
              } | null>(`/fiscal/documents/by-receipt/${r.id}`)
              if (doc) {
                newStates[r.id] = {
                  documentId: doc.id,
                  status:     doc.status,
                  cae:        doc.cae,
                }
              }
            } catch {
              // 403 = can happen if backend rejects, ignore silently per-row
            }
          }),
      )
      setFiscalStates(newStates)
    } catch (err) {
      console.error("Error cargando recibos:", err)
      setError(err instanceof Error ? err.message : "No se pudieron cargar los pagos.")
    } finally {
      setLoading(false)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

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

  const resendReceipt = useCallback(async (r: PaymentReceipt) => {
    setResendingId(r.id)
    setError(null)
    setNotice(null)
    try {
      await pythonClient.post(`/payments/receipts/${r.id}/resend`, {})
      setNotice(`Recibo reenviado por email a ${r.customer_email}.`)
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo reenviar el recibo.")
    } finally {
      setResendingId(null)
    }
  }, [])

  // ── Enviar al ARCA ─────────────────────────────────────────────────────────

  function openEmitDialog(r: PaymentReceipt) {
    setSelectedReceipt(r)
    setError(null)
    setNotice(null)
    setDialogOpen(true)
  }

  async function handleEmitConfirm(payload: EmitSubscriptionPaymentInput) {
    try {
      const result = await emitMutation.mutateAsync(payload)

      if (result.already_emitted) {
        setNotice("Este recibo ya fue enviado al ARCA anteriormente. Se muestra el estado actual del comprobante.")
      } else {
        setNotice("Comprobante enviado a ARCA. El CAE se obtendrá en segundos.")
      }

      // Update fiscal state for this row
      setFiscalStates((prev) => ({
        ...prev,
        [payload.receipt_id]: {
          documentId: result.fiscal_document_id,
          status:     result.status,
          cae:        result.cae ?? null,
        },
      }))

      setDialogOpen(false)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error al emitir el comprobante."
      if (isDelegationError(msg)) {
        setError(
          "ARCA rechazó la solicitud: Aliadata no está autorizado como representante. " +
          "Configurá la delegación en Ajustes → Datos fiscales.",
        )
      } else {
        setError(translateEmitError(msg))
      }
      setDialogOpen(false)
    }
  }

  return (
    <div className="container mx-auto p-6 max-w-6xl pb-20">
      <header className="flex items-center gap-3 mb-2">
        <Receipt className="w-6 h-6 text-emerald-500" />
        <h1 className="text-3xl font-bold text-slate-100 tracking-tight">Recibos de Pago</h1>
      </header>
      <p className="text-slate-400 mb-8">
        Pagos aprobados de las suscripciones. Descargá el comprobante en PDF o emití la Factura C ante AFIP.
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
          {error.includes("Datos fiscales") && (
            <span>
              {" "}<a href="/configuracion/fiscal" className="underline underline-offset-2 hover:opacity-80">
                Ir a Datos fiscales →
              </a>
            </span>
          )}
        </div>
      )}

      {notice && (
        <div className="mb-6 flex items-center gap-2 rounded-lg border border-emerald-500/20 bg-emerald-500/10 p-4 text-sm text-emerald-400">
          <CheckCircle2 className="w-4 h-4 shrink-0" />
          {notice}
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
                <th className="px-4 py-3 font-medium text-right">ARCA</th>
                <th className="px-4 py-3 font-medium text-right">Acciones</th>
              </tr>
            </thead>
            <tbody>
              {receipts.map((r) => {
                const fiscal = fiscalStates[r.id]
                return (
                  <tr key={r.id} className="border-b border-slate-800/60 last:border-0 hover:bg-slate-800/30">
                    <td className="px-4 py-3 font-mono text-xs text-slate-300">{r.receipt_number ?? "—"}</td>
                    <td className="px-4 py-3 text-slate-300">{formatDate(r.created_at)}</td>
                    <td className="px-4 py-3">
                      <div className="text-slate-200">{r.customer_name ?? "—"}</div>
                      <div className="text-xs text-slate-500">{r.customer_email}</div>
                    </td>
                    <td className="px-4 py-3 text-slate-300">{PLAN_LABELS[r.plan ?? ""] ?? r.plan ?? "—"}</td>
                    <td className="px-4 py-3 text-right font-semibold text-slate-100">{formatAmount(r.amount)}</td>

                    {/* ARCA column: badge or placeholder */}
                    <td className="px-4 py-3 text-right">
                      {fiscal ? (
                        <FiscalDocumentBadge
                          documentId={fiscal.documentId}
                          initialStatus={fiscal.status}
                        />
                      ) : (
                        <span className="text-xs text-slate-600">—</span>
                      )}
                    </td>

                    {/* Actions column */}
                    <td className="px-4 py-3">
                      <div className="flex items-center justify-end gap-2">
                        <button
                          onClick={() => downloadReceipt(r)}
                          disabled={downloadingId === r.id}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-1.5 text-xs font-medium text-emerald-400 transition-colors hover:bg-emerald-500/20 disabled:opacity-50"
                        >
                          <Download className="w-3.5 h-3.5" />
                          {downloadingId === r.id ? "Generando..." : "Descargar PDF"}
                        </button>
                        <button
                          onClick={() => resendReceipt(r)}
                          disabled={resendingId === r.id}
                          className="inline-flex items-center gap-1.5 rounded-lg border border-slate-700 bg-slate-800 px-3 py-1.5 text-xs font-medium text-slate-200 transition-colors hover:bg-slate-700 disabled:opacity-50"
                        >
                          <Send className="w-3.5 h-3.5" />
                          {resendingId === r.id ? "Enviando..." : "Reenviar"}
                        </button>

                        {/* Enviar al ARCA: only when no fiscal doc yet */}
                        {!fiscal && (
                          <button
                            onClick={() => openEmitDialog(r)}
                            disabled={emitMutation.isPending || pvLoading}
                            className="inline-flex items-center gap-1.5 rounded-lg border border-violet-500/30 bg-violet-500/10 px-3 py-1.5 text-xs font-medium text-violet-400 transition-colors hover:bg-violet-500/20 disabled:opacity-50"
                          >
                            <FileCheck className="w-3.5 h-3.5" />
                            Enviar al ARCA
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Dialog */}
      <EmitirSuscripcionDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        receipt={selectedReceipt}
        pointsOfSale={pointsOfSale}
        onConfirm={handleEmitConfirm}
        isSubmitting={emitMutation.isPending}
      />
    </div>
  )
}
