"use client"

/**
 * PendingInvitations — las invitaciones de la cuenta con «Reenviar» y «Revocar».
 *
 * multiusuario-operativo tanda C (D13, spec account-invitation-flow «Las invitaciones pendientes se
 * gestionan desde la pantalla de invitación»). Lista, para quien tiene autoridad (dueño o administrador),
 * las pendientes vigentes y las vencidas o revocadas de los últimos 30 días, con email, roles, estado,
 * cuántas veces se envió y cuándo vence. El listado NUNCA trae el token (el backend no lo devuelve).
 *
 *   · «Reenviar» ROTA el token (el link del email anterior deja de servir), renueva el vencimiento y manda
 *     un email nuevo. Tras reenviar, el link NUEVO queda disponible para «Copiar link» (opción secundaria,
 *     OQ-6) hasta que se recargue la lista: es el único momento en que el cliente conoce ese token.
 *   · «Revocar» pide confirmación y deja la invitación inutilizable (la aceptación falla como un token vencido).
 *   · Los topes de envío (1 cada 10 minutos por invitación, 20 por día por cuenta) llegan como 429 y se
 *     traducen a un mensaje que dice qué esperar.
 */

import { useState } from "react"
import { toast } from "sonner"
import { Check, Copy, Loader2, MailPlus, RefreshCw, Ban } from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import {
  useInvitations,
  useResendInvitation,
  useRevokeInvitation,
  type InvitationRow,
  type InvitationState,
} from "@/hooks/data/use-invitations"
import { invitationErrorMessage } from "@/lib/invitation-errors"
import { invitationLink } from "@/lib/auth/invitation-next"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"

const STATE_LABEL: Record<InvitationState, string> = {
  pending: "Pendiente",
  expired: "Vencida",
  revoked: "Revocada",
}

function StateBadge({ state }: { state: InvitationState }) {
  if (state === "pending") {
    return <Badge className="border-primary/30 bg-primary/10 text-xs text-primary">{STATE_LABEL.pending}</Badge>
  }
  if (state === "expired") {
    return <Badge variant="outline" className="border-orange-500/40 text-xs text-orange-600 dark:text-orange-400">{STATE_LABEL.expired}</Badge>
  }
  return <Badge variant="outline" className="text-xs text-muted-foreground">{STATE_LABEL.revoked}</Badge>
}

function formatDate(iso: string | null): string {
  if (!iso) return ""
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? "" : date.toLocaleDateString("es-AR")
}

function sentSummary(row: InvitationRow): string {
  if (row.send_count <= 0) return "Todavía no se envió el email"
  const last = formatDate(row.last_sent_at)
  const times = row.send_count === 1 ? "1 vez" : `${row.send_count} veces`
  return last ? `Enviada ${times} · último envío ${last}` : `Enviada ${times}`
}

export function PendingInvitations() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const { data: rows = [], isLoading, isError, refetch } = useInvitations(accountId)
  const resend = useResendInvitation(accountId)
  const revoke = useRevokeInvitation(accountId)

  const [revoking, setRevoking] = useState<InvitationRow | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  // El link NUEVO de cada reenvío (lo conoce el cliente sólo hasta que se recarga la lista).
  const [freshLinks, setFreshLinks] = useState<Record<string, string>>({})
  const [copiedId, setCopiedId] = useState<string | null>(null)

  async function handleResend(row: InvitationRow) {
    setBusyId(row.id)
    try {
      const sent = await resend.mutateAsync(row.id)
      setFreshLinks((prev) => ({ ...prev, [row.id]: sent.token }))
      toast.success(`Reenviamos la invitación a ${row.email}. El link anterior ya no sirve.`)
    } catch (error) {
      toast.error(invitationErrorMessage(error))
    } finally {
      setBusyId(null)
    }
  }

  async function handleRevoke() {
    if (!revoking) return
    const row = revoking
    setBusyId(row.id)
    try {
      await revoke.mutateAsync(row.id)
      setFreshLinks((prev) => {
        const { [row.id]: _gone, ...rest } = prev
        return rest
      })
      toast.success(`Revocamos la invitación a ${row.email}.`)
    } catch (error) {
      toast.error(invitationErrorMessage(error))
    } finally {
      setBusyId(null)
      setRevoking(null)
    }
  }

  async function copyFreshLink(id: string) {
    const token = freshLinks[id]
    if (!token) return
    try {
      await navigator.clipboard.writeText(invitationLink(token, window.location.origin))
      setCopiedId(id)
      setTimeout(() => setCopiedId((current) => (current === id ? null : current)), 2000)
    } catch {
      // Sin acceso al portapapeles: el email ya salió igual.
    }
  }

  if (isLoading) {
    return (
      <div className="flex flex-col gap-2" role="status" aria-label="Cargando invitaciones">
        <Skeleton className="h-16 w-full" />
        <Skeleton className="h-16 w-full" />
      </div>
    )
  }

  if (isError) {
    return (
      <div role="alert" className="flex flex-col items-start gap-2 rounded-md border border-destructive/20 bg-destructive/10 p-3 text-sm text-destructive">
        No pudimos cargar las invitaciones.
        <Button size="sm" variant="outline" className="border-border text-foreground" onClick={() => void refetch()}>
          Reintentar
        </Button>
      </div>
    )
  }

  if (rows.length === 0) {
    return (
      <div className="flex items-center gap-2 rounded-md border border-dashed border-border p-4 text-sm text-muted-foreground">
        <MailPlus className="h-4 w-4 shrink-0" aria-hidden="true" />
        No hay invitaciones pendientes. Las que envíes aparecen acá.
      </div>
    )
  }

  return (
    <>
      <ul className="flex flex-col gap-2" aria-label="Invitaciones de la cuenta">
        {rows.map((row) => {
          const actionable = row.state === "pending" || row.state === "expired"
          const busy = busyId === row.id
          const fresh = freshLinks[row.id]
          return (
            <li key={row.id} className="flex flex-col gap-3 rounded-lg border border-border bg-card p-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="flex min-w-0 flex-col gap-1.5">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="min-w-0 break-all text-sm font-medium text-foreground">{row.email}</span>
                  <StateBadge state={row.state} />
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {row.role_labels.map((label) => (
                    <Badge key={label} variant="secondary" className="text-xs">
                      {label}
                    </Badge>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  {sentSummary(row)} · {row.state === "expired" ? "venció" : "vence"} {formatDate(row.expires_at)}
                </p>
                {fresh && (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    className="mt-1 min-h-11 self-start border-border sm:min-h-8"
                    onClick={() => void copyFreshLink(row.id)}
                  >
                    {copiedId === row.id ? <Check className="h-3.5 w-3.5" aria-hidden="true" /> : <Copy className="h-3.5 w-3.5" aria-hidden="true" />}
                    <span className="ml-1.5">{copiedId === row.id ? "Link copiado" : "Copiar link nuevo"}</span>
                  </Button>
                )}
              </div>

              {actionable && (
                <div className="flex shrink-0 flex-wrap gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    className="min-h-11 border-border text-foreground sm:min-h-8"
                    disabled={busy}
                    onClick={() => void handleResend(row)}
                    aria-label={`Reenviar la invitación a ${row.email}`}
                  >
                    {busy && resend.isPending ? <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" /> : <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />}
                    <span className="ml-1.5">Reenviar</span>
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    className="min-h-11 border-destructive/40 text-destructive hover:bg-destructive/10 sm:min-h-8"
                    disabled={busy}
                    onClick={() => setRevoking(row)}
                    aria-label={`Revocar la invitación a ${row.email}`}
                  >
                    <Ban className="h-3.5 w-3.5" aria-hidden="true" />
                    <span className="ml-1.5">Revocar</span>
                  </Button>
                </div>
              )}
            </li>
          )
        })}
      </ul>

      <AlertDialog open={!!revoking} onOpenChange={(open) => !open && setRevoking(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Revocar la invitación?</AlertDialogTitle>
            <AlertDialogDescription>
              {revoking ? `${revoking.email} ya no va a poder sumarse con el link que recibió. ` : ""}
              Si cambiás de idea, podés invitarlo de nuevo.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="min-h-11 sm:min-h-9">Cancelar</AlertDialogCancel>
            <AlertDialogAction
              className="min-h-11 bg-destructive text-destructive-foreground hover:bg-destructive/90 sm:min-h-9"
              onClick={(event) => {
                event.preventDefault()
                void handleRevoke()
              }}
            >
              Revocar invitación
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
