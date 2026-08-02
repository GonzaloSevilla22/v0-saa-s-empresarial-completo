"use client"

/**
 * /admin/pagos/ambiguas — Cola de conciliación manual de suscripciones
 * ambiguas (mp-real-subscriptions, D2bis, follow-up task 8.8).
 *
 * El backend (PR #345) ya implementaba GET /payments/subscriptions/ambiguous
 * y POST /payments/subscriptions/ambiguous/{id}/resolve — admin-only,
 * auditado (billing_events 'subscription_ambiguous_resolved') — pero no
 * existía ninguna pantalla: el PO preguntó dónde estaba. Esta página cierra
 * ese gap.
 *
 * Gating: mismo patrón que /admin/pagos (fetch de profiles.role vía
 * Supabase client + redirect si no es admin) — sin pantalla intermedia para
 * no-admins.
 *
 * GAP CONOCIDO (documentado, no bloqueante): `public.subscriptions` no
 * persiste el email del pagador en filas `ambiguous` — solo
 * `subscription_intents.payer_email`, que en el caso ambiguo queda SIN
 * vincular (0 o >1 candidatas). El admin usa `preapproval_id` para cruzar
 * contra el panel de MercadoPago si necesita ver el email real. Agregar esa
 * columna requeriría tocar el webhook de pagos (governance CRÍTICO,
 * dinero real) — fuera de alcance de este follow-up de UI; ver tasks.md 8.8.
 */

import { useCallback, useEffect, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { AlertTriangle, CheckCircle2, HelpCircle, Loader2, ShieldAlert } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import { AccountSearchCombobox } from "@/components/billing/AccountSearchCombobox"
import {
  useAmbiguousSubscriptions,
  type AccountSearchResult,
} from "@/hooks/data/use-ambiguous-subscriptions"

const PLAN_LABELS: Record<string, string> = {
  gratis: "Gratis", inicial: "Inicial", avanzado: "Avanzado", pro: "Pro",
}

const AMBIGUOUS_REASON_LABELS: Record<string, string> = {
  no_match: "Sin cuenta candidata",
  multiple_match: "Varias cuentas candidatas",
}

function formatAmount(amount: number | null, currency: string): string {
  if (amount == null) return "—"
  return new Intl.NumberFormat("es-AR", {
    style: "currency", currency, minimumFractionDigits: 2,
  }).format(amount)
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("es-AR", {
    day: "2-digit", month: "2-digit", year: "numeric",
  })
}

type AdminGateState = "checking" | "denied" | "allowed"

export default function SuscripcionesAmbiguasPage() {
  const [gate, setGate] = useState<AdminGateState>("checking")

  useEffect(() => {
    let active = true

    async function checkAdmin() {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) {
        window.location.href = "/auth/login"
        return
      }
      const { data: profile } = await supabase
        .from("profiles").select("role").eq("id", user.id).single()
      if (!active) return
      if (!profile || profile.role !== "admin") {
        setGate("denied")
        window.location.href = "/dashboard"
        return
      }
      setGate("allowed")
    }

    checkAdmin()
    return () => { active = false }
  }, [])

  // No-admin (o todavía chequeando): degrada limpio, sin renderizar nada —
  // mismo patrón que /admin/pagos (redirect ya disparado en el effect).
  if (gate !== "allowed") {
    return null
  }

  return <AmbiguousQueueContent />
}

function AmbiguousQueueContent() {
  const {
    data, isLoading, isError, error, resolveSubscription,
  } = useAmbiguousSubscriptions()

  const [selectedAccounts, setSelectedAccounts] = useState<Record<string, AccountSearchResult | null>>({})
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({})
  const [notice, setNotice] = useState<string | null>(null)
  const [resolvingId, setResolvingId] = useState<string | null>(null)

  const handleAssign = useCallback(async (subscriptionId: string) => {
    const account = selectedAccounts[subscriptionId]
    if (!account) return

    setResolvingId(subscriptionId)
    setRowErrors((prev) => ({ ...prev, [subscriptionId]: "" }))
    setNotice(null)
    try {
      await resolveSubscription({ subscriptionId, accountId: account.accountId })
      setNotice(`Suscripción asignada a ${account.ownerEmail}.`)
      setSelectedAccounts((prev) => {
        const next = { ...prev }
        delete next[subscriptionId]
        return next
      })
    } catch (err) {
      setRowErrors((prev) => ({
        ...prev,
        [subscriptionId]: err instanceof Error ? err.message : "No se pudo asignar la cuenta.",
      }))
    } finally {
      setResolvingId(null)
    }
  }, [selectedAccounts, resolveSubscription])

  return (
    <div className="container mx-auto p-6 max-w-6xl pb-20">
      <header className="flex items-center gap-3 mb-2">
        <ShieldAlert className="w-6 h-6 text-warning" aria-hidden="true" />
        <h1 className="text-3xl font-bold text-foreground tracking-tight">Suscripciones ambiguas</h1>
      </header>
      <p className="text-muted-foreground mb-8">
        Pagos de suscripción cuyo email no pudo asociarse automáticamente a una cuenta.
        El dinero ya se acreditó — acá corregís a qué cuenta pertenece.
      </p>

      {notice && (
        <div
          role="status"
          className="mb-6 flex items-center gap-2 rounded-lg border border-success/20 bg-success/10 p-4 text-sm text-success-foreground"
        >
          <CheckCircle2 className="w-4 h-4 shrink-0" aria-hidden="true" />
          {notice}
        </div>
      )}

      {isError && (
        <div
          role="alert"
          className="mb-6 flex items-center gap-2 rounded-lg border border-destructive/20 bg-destructive/10 p-4 text-sm text-destructive"
        >
          <AlertTriangle className="w-4 h-4 shrink-0" aria-hidden="true" />
          {error instanceof Error ? error.message : "No se pudo cargar la cola de suscripciones ambiguas."}
        </div>
      )}

      {isLoading ? (
        <div className="flex flex-col items-center justify-center py-32 gap-4">
          <Loader2 className="h-8 w-8 animate-spin text-primary" aria-hidden="true" />
          <p className="text-muted-foreground text-sm">Cargando cola...</p>
        </div>
      ) : !data || data.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-24 gap-3 text-center rounded-2xl border border-border bg-card">
          <HelpCircle className="w-10 h-10 text-muted-foreground" aria-hidden="true" />
          <p className="text-muted-foreground">No hay suscripciones pendientes de revisión.</p>
        </div>
      ) : (
        <div className="overflow-x-auto rounded-2xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Fecha</TableHead>
                <TableHead>Plan</TableHead>
                <TableHead className="text-right">Monto</TableHead>
                <TableHead>Motivo</TableHead>
                <TableHead className="min-w-[280px]">Cuenta destino</TableHead>
                <TableHead className="text-right">Acción</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.map((sub) => {
                const isResolving = resolvingId === sub.id
                const rowError = rowErrors[sub.id]
                const selected = selectedAccounts[sub.id] ?? null

                return (
                  <TableRow key={sub.id}>
                    <TableCell className="text-muted-foreground whitespace-nowrap">
                      {formatDate(sub.createdAt)}
                    </TableCell>
                    <TableCell>{PLAN_LABELS[sub.plan] ?? sub.plan}</TableCell>
                    <TableCell className="text-right font-semibold text-foreground whitespace-nowrap">
                      {formatAmount(sub.amount, sub.currency)}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline" className="text-xs">
                        {AMBIGUOUS_REASON_LABELS[sub.ambiguousReason] ?? sub.ambiguousReason}
                      </Badge>
                      <div className="text-[11px] text-muted-foreground mt-1 font-mono truncate max-w-[180px]">
                        {sub.preapprovalId}
                      </div>
                    </TableCell>
                    <TableCell>
                      <label htmlFor={`account-search-${sub.id}`} className="sr-only">
                        Cuenta destino para la suscripción {sub.preapprovalId}
                      </label>
                      <AccountSearchCombobox
                        id={`account-search-${sub.id}`}
                        aria-label={`Cuenta destino para la suscripción ${sub.preapprovalId}`}
                        value={selected}
                        onSelect={(account) =>
                          setSelectedAccounts((prev) => ({ ...prev, [sub.id]: account }))
                        }
                        disabled={isResolving}
                      />
                      {rowError && (
                        <p role="alert" className="text-xs text-destructive mt-1">{rowError}</p>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        size="sm"
                        onClick={() => handleAssign(sub.id)}
                        disabled={!selected || isResolving}
                        aria-label={`Asignar suscripción ${sub.preapprovalId} a la cuenta seleccionada`}
                      >
                        {isResolving && <Loader2 className="mr-2 h-3.5 w-3.5 animate-spin" aria-hidden="true" />}
                        Asignar
                      </Button>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  )
}
