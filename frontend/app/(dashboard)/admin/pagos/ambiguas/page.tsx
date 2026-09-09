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
import { toast } from "sonner"
import { AlertTriangle, CheckCircle2, HelpCircle, Loader2, RotateCw, ShieldAlert } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { AccountSearchCombobox } from "@/components/billing/AccountSearchCombobox"
import {
  useAmbiguousSubscriptions,
  useRecentSubscriptions,
  type AccountSearchResult,
  type RecentSubscription,
} from "@/hooks/data/use-ambiguous-subscriptions"

const PLAN_LABELS: Record<string, string> = {
  gratis: "Gratis", inicial: "Inicial", avanzado: "Avanzado", pro: "Pro",
}

const AMBIGUOUS_REASON_LABELS: Record<string, string> = {
  no_match: "Sin cuenta candidata",
  multiple_match: "Varias cuentas candidatas",
}

const SUBSCRIPTION_STATUS_LABELS: Record<string, string> = {
  pending: "Pendiente",
  authorized: "Activa",
  paused: "Pausada",
  cancelled: "Cancelada",
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
    data, isLoading, isError, error, resolveSubscription, discardSubscription,
  } = useAmbiguousSubscriptions()

  const [selectedAccounts, setSelectedAccounts] = useState<Record<string, AccountSearchResult | null>>({})
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({})
  const [notice, setNotice] = useState<string | null>(null)
  const [resolvingId, setResolvingId] = useState<string | null>(null)
  const [discardReasons, setDiscardReasons] = useState<Record<string, string>>({})
  const [discardingId, setDiscardingId] = useState<string | null>(null)

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

  const handleDiscard = useCallback(async (subscriptionId: string) => {
    setDiscardingId(subscriptionId)
    try {
      const reason = discardReasons[subscriptionId]?.trim()
      await discardSubscription({ subscriptionId, reason: reason ? reason : undefined })
      toast.success("Suscripción descartada de la cola.")
      setDiscardReasons((prev) => {
        const next = { ...prev }
        delete next[subscriptionId]
        return next
      })
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "No se pudo descartar la suscripción.")
    } finally {
      setDiscardingId(null)
    }
  }, [discardReasons, discardSubscription])

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
                      <div className="flex items-center justify-end gap-2 flex-wrap">
                        <Button
                          size="sm"
                          onClick={() => handleAssign(sub.id)}
                          disabled={!selected || isResolving}
                          aria-label={`Asignar suscripción ${sub.preapprovalId} a la cuenta seleccionada`}
                        >
                          {isResolving && <Loader2 className="mr-2 h-3.5 w-3.5 animate-spin" aria-hidden="true" />}
                          Asignar
                        </Button>
                        <AlertDialog>
                          <AlertDialogTrigger asChild>
                            <Button
                              size="sm"
                              variant="outline"
                              className="text-destructive hover:bg-destructive/10"
                              disabled={isResolving || discardingId === sub.id}
                              aria-label={`Descartar suscripción ${sub.preapprovalId}`}
                            >
                              {discardingId === sub.id && (
                                <Loader2 className="mr-2 h-3.5 w-3.5 animate-spin" aria-hidden="true" />
                              )}
                              Descartar
                            </Button>
                          </AlertDialogTrigger>
                          <AlertDialogContent>
                            <AlertDialogHeader>
                              <AlertDialogTitle>¿Descartar esta suscripción ambigua?</AlertDialogTitle>
                              <AlertDialogDescription asChild>
                                <div className="space-y-3 text-sm text-muted-foreground">
                                  <p>
                                    Sale de esta cola sin asignar ninguna cuenta — nunca toca el
                                    dinero ya acreditado en MercadoPago. Usalo cuando no hay
                                    ninguna cuenta legítima que la reclame.
                                  </p>
                                  <div className="space-y-1.5">
                                    <Label htmlFor={`discard-reason-${sub.id}`} className="text-foreground">
                                      Motivo (opcional)
                                    </Label>
                                    <Textarea
                                      id={`discard-reason-${sub.id}`}
                                      value={discardReasons[sub.id] ?? ""}
                                      onChange={(e) =>
                                        setDiscardReasons((prev) => ({ ...prev, [sub.id]: e.target.value }))
                                      }
                                      maxLength={200}
                                      placeholder="Ej: preapproval cancelado en MercadoPago, sin cuenta legítima"
                                      className="min-h-16"
                                    />
                                  </div>
                                </div>
                              </AlertDialogDescription>
                            </AlertDialogHeader>
                            <AlertDialogFooter>
                              <AlertDialogCancel>Volver</AlertDialogCancel>
                              <AlertDialogAction
                                onClick={() => handleDiscard(sub.id)}
                                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                              >
                                Descartar
                              </AlertDialogAction>
                            </AlertDialogFooter>
                          </AlertDialogContent>
                        </AlertDialog>
                      </div>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <RecentSubscriptionsSection />
    </div>
  )
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleDateString("es-AR", {
    day: "2-digit", month: "2-digit", year: "numeric",
  })
}

/**
 * "Suscripciones recientes" (residuo (c) de mp-real-subscriptions): lista
 * suscripciones YA resueltas/activas y dispara "Replicar cuotas"
 * (`POST /payments/subscriptions/{id}/replay-charges`, endpoint admin ya
 * existente desde el hotfix H3) sin que el admin tenga que conocer de
 * antemano el id de la suscripción.
 */
function RecentSubscriptionsSection() {
  const { data, isLoading, isError, replaySubscriptionCharges } = useRecentSubscriptions(20)
  const [replayingId, setReplayingId] = useState<string | null>(null)

  const handleReplay = useCallback(async (subscriptionId: string) => {
    setReplayingId(subscriptionId)
    try {
      const result = await replaySubscriptionCharges(subscriptionId)
      const appliedCount = result.applied.length
      const alreadyCount = result.alreadyApplied.length
      if (appliedCount === 0 && alreadyCount === 0) {
        toast.success("No había ninguna cuota para replicar.")
      } else {
        toast.success(
          `${appliedCount} cuota(s) aplicada(s), ${alreadyCount} ya estaban aplicadas.`,
        )
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "No se pudieron replicar las cuotas.")
    } finally {
      setReplayingId(null)
    }
  }, [replaySubscriptionCharges])

  return (
    <section className="mt-10">
      <h2 className="text-xl font-semibold text-foreground tracking-tight mb-2">
        Suscripciones recientes
      </h2>
      <p className="text-muted-foreground text-sm mb-6">
        Suscripciones ya resueltas o activas. &quot;Replicar cuotas&quot; consulta MercadoPago y
        vuelve a aplicar cada cuota aprobada — es idempotente, sirve para completar un cobro
        que quedó a medio aplicar.
      </p>

      {isError ? (
        <div
          role="alert"
          className="flex items-center gap-2 rounded-lg border border-destructive/20 bg-destructive/10 p-4 text-sm text-destructive"
        >
          <AlertTriangle className="w-4 h-4 shrink-0" aria-hidden="true" />
          No se pudieron cargar las suscripciones recientes.
        </div>
      ) : isLoading ? (
        <div className="flex items-center justify-center gap-2 text-muted-foreground text-sm py-16">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden="true" />
          Cargando suscripciones recientes...
        </div>
      ) : !data || data.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-16 gap-2 text-center rounded-2xl border border-border bg-card">
          <p className="text-muted-foreground text-sm">No hay suscripciones recientes todavía.</p>
        </div>
      ) : (
        <div className="overflow-x-auto rounded-2xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Plan</TableHead>
                <TableHead>Estado</TableHead>
                <TableHead>Cuenta</TableHead>
                <TableHead>Próximo cobro</TableHead>
                <TableHead className="text-right">Acción</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.map((sub: RecentSubscription) => {
                const isReplaying = replayingId === sub.id
                const accountLabel = sub.accountName ?? (sub.accountId ? sub.accountId : "Sin cuenta")
                return (
                  <TableRow key={sub.id}>
                    <TableCell>{PLAN_LABELS[sub.plan] ?? sub.plan}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className="text-xs">
                        {SUBSCRIPTION_STATUS_LABELS[sub.status] ?? sub.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-foreground">{accountLabel}</TableCell>
                    <TableCell className="text-muted-foreground whitespace-nowrap">
                      {sub.nextPaymentDate ? formatDateTime(sub.nextPaymentDate) : "—"}
                    </TableCell>
                    <TableCell className="text-right">
                      <AlertDialog>
                        <AlertDialogTrigger asChild>
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={isReplaying}
                            aria-label={`Replicar cuotas de la suscripción ${sub.plan} de ${accountLabel}`}
                          >
                            {isReplaying ? (
                              <Loader2 className="mr-2 h-3.5 w-3.5 animate-spin" aria-hidden="true" />
                            ) : (
                              <RotateCw className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
                            )}
                            Replicar cuotas
                          </Button>
                        </AlertDialogTrigger>
                        <AlertDialogContent>
                          <AlertDialogHeader>
                            <AlertDialogTitle>¿Replicar cuotas de esta suscripción?</AlertDialogTitle>
                            <AlertDialogDescription>
                              Consulta MercadoPago y vuelve a aplicar cada cuota aprobada; es
                              idempotente — no duplica nada si ya se había aplicado.
                            </AlertDialogDescription>
                          </AlertDialogHeader>
                          <AlertDialogFooter>
                            <AlertDialogCancel>Cancelar</AlertDialogCancel>
                            <AlertDialogAction onClick={() => handleReplay(sub.id)}>
                              Replicar
                            </AlertDialogAction>
                          </AlertDialogFooter>
                        </AlertDialogContent>
                      </AlertDialog>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </section>
  )
}
