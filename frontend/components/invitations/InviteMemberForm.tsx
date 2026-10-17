"use client"

/**
 * InviteMemberForm — invita a una persona por email con un CONJUNTO de roles.
 *
 * multiusuario-operativo tanda C (D10, D14, OQ-6). La comparten `/organizacion/invitar` y la invitación
 * rápida de Configuración → Equipo (`TeamSection`), que antes usaba el overload de 2 argumentos de
 * `rpc_invite_member` y resolvía a `viewer` sin que nadie lo eligiera (BREAKING interno, retirado en la
 * base). Ahora las dos declaran el conjunto de roles y van por FastAPI (`POST /members/invitations`),
 * que crea la invitación y encola el email en la misma transacción.
 *
 * Roles invitables: el dueño puede invitar con cualquiera; el administrador nunca con propietario ni
 * administrador (org-roles, «Invitación diferenciada por rol que puede invitar»).
 *
 * Tras invitar: «Le enviamos un email a {email}». «Copiar link» queda como opción SECUNDARIA (OQ-6 a): en
 * Argentina la invitación suele compartirse por WhatsApp, y la aceptación sigue ligada al email invitado,
 * así que reenviar el link no le da acceso a otra persona. Se copia el LINK completo, nunca el token suelto.
 */

import { useMemo, useState } from "react"
import { Check, CheckCircle2, Copy, AlertCircle, Loader2, UserPlus } from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { useRoleCatalog } from "@/hooks/data/use-role-catalog"
import { useInviteMember } from "@/hooks/data/use-invitations"
import { invitationErrorMessage } from "@/lib/invitation-errors"
import { invitationLink } from "@/lib/auth/invitation-next"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import type { OrgRole } from "@/lib/types"

/** Roles con que puede invitar quien tiene `callerRole` (el catálogo ya viene ordenado). */
export function invitableRoleCodes(callerRole: string | null | undefined): "all" | "operational" | "none" {
  if (callerRole === "owner") return "all"
  if (callerRole === "admin") return "operational"
  return "none"
}

interface InviteMemberFormProps {
  /** Rol del que invita (owner | admin | otro): decide qué roles puede ofrecer. */
  callerRole: string | null | undefined
  /** Prefijo de ids (dos formularios en una pantalla no pueden repetir `id`). */
  idPrefix?: string
  /** Variante compacta (Configuración → Equipo): sin tarjeta propia, email y botón en una fila. */
  compact?: boolean
}

export function InviteMemberForm({ callerRole, idPrefix = "invite", compact = false }: InviteMemberFormProps) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const { data: catalog = [] } = useRoleCatalog()
  const invite = useInviteMember(accountId)

  const [email, setEmail] = useState("")
  const [selectedRoles, setSelectedRoles] = useState<OrgRole[]>([])
  const [feedback, setFeedback] = useState<{ type: "success" | "error"; msg: string } | null>(null)
  const [lastInvite, setLastInvite] = useState<{ email: string; token: string } | null>(null)
  const [copied, setCopied] = useState(false)

  const scope = invitableRoleCodes(callerRole)
  const invitableRoles = useMemo(() => {
    if (scope === "all") return catalog
    if (scope === "operational") return catalog.filter((r) => r.code !== "owner" && r.code !== "admin")
    return []
  }, [catalog, scope])

  function toggleRole(code: OrgRole, checked: boolean) {
    setSelectedRoles((prev) => (checked ? [...prev, code] : prev.filter((r) => r !== code)))
  }

  async function copyLink(token: string) {
    try {
      await navigator.clipboard.writeText(invitationLink(token, window.location.origin))
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // Sin acceso al portapapeles (permiso denegado / contexto no seguro): el email ya salió igual.
    }
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setFeedback(null)
    setLastInvite(null)
    setCopied(false)
    const target = email.trim().toLowerCase()
    if (!target) return
    invite.mutate(
      { email: target, roles: selectedRoles },
      {
        onSuccess: (sent) => {
          setFeedback({ type: "success", msg: `Le enviamos un email a ${sent.email} con el link para sumarse.` })
          setLastInvite({ email: sent.email, token: sent.token })
          setEmail("")
          setSelectedRoles([])
        },
        onError: (error) => setFeedback({ type: "error", msg: invitationErrorMessage(error) }),
      },
    )
  }

  const emailId = `${idPrefix}-email`
  const rolesLabelId = `${idPrefix}-roles-label`

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className={compact ? "flex flex-col gap-2 sm:flex-row" : "flex flex-col gap-1.5"}>
        {!compact && <Label htmlFor={emailId}>Email</Label>}
        <Input
          id={emailId}
          type="email"
          aria-label={compact ? "Email de la persona a invitar" : undefined}
          placeholder={compact ? "email@empresa.com" : "colaborador@email.com"}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          disabled={invite.isPending}
          required
          className="bg-background border-border text-foreground sm:flex-1"
        />
        {compact && (
          <Button type="submit" size="sm" disabled={invite.isPending || !email.trim()} className="min-h-11 shrink-0 sm:min-h-9">
            {invite.isPending ? <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" /> : <UserPlus className="h-3.5 w-3.5" aria-hidden="true" />}
            <span className="ml-1.5">Invitar</span>
          </Button>
        )}
      </div>

      <div className="flex flex-col gap-2">
        <Label id={rolesLabelId}>Roles</Label>
        <div role="group" aria-labelledby={rolesLabelId} className="flex flex-col gap-2 rounded-md border border-border p-3">
          {invitableRoles.length === 0 && (
            <p className="text-xs text-muted-foreground">No tenés autoridad para invitar con ningún rol.</p>
          )}
          {invitableRoles.map((r) => (
            <div key={r.code} className="flex items-start gap-2">
              <Checkbox
                id={`${idPrefix}-role-${r.code}`}
                checked={selectedRoles.includes(r.code)}
                onCheckedChange={(checked) => toggleRole(r.code, checked === true)}
                className="mt-0.5 rounded-[3px]"
              />
              <Label htmlFor={`${idPrefix}-role-${r.code}`} className="flex cursor-pointer flex-col gap-0.5 font-normal">
                <span className="text-sm text-foreground">{r.label}</span>
                <span className="text-xs text-muted-foreground">{r.description}</span>
              </Label>
            </div>
          ))}
        </div>
        <p className="text-xs text-muted-foreground">Sin roles seleccionados, se incorpora como Observador (solo lectura).</p>
      </div>

      {feedback && (
        <div
          role={feedback.type === "error" ? "alert" : "status"}
          className={`flex items-start gap-2 rounded-md border px-3 py-2.5 text-sm ${
            feedback.type === "success"
              ? "border-green-500/20 bg-green-500/10 text-green-700 dark:text-green-400"
              : "border-destructive/20 bg-destructive/10 text-destructive"
          }`}
        >
          {feedback.type === "success" ? (
            <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          ) : (
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          )}
          {feedback.msg}
        </div>
      )}

      {lastInvite && (
        <div className="flex flex-col gap-2 rounded-md border border-border bg-muted/30 p-3">
          <p className="text-xs text-muted-foreground">
            ¿No le llegó o preferís mandarlo por WhatsApp? Copiá el link y compartilo: solo funciona con el email{" "}
            <span className="font-medium text-foreground">{lastInvite.email}</span>. Vence en 7 días.
          </p>
          <Button
            type="button"
            size="sm"
            variant="outline"
            className="min-h-11 self-start border-border sm:min-h-9"
            onClick={() => void copyLink(lastInvite.token)}
          >
            {copied ? <Check className="h-3.5 w-3.5" aria-hidden="true" /> : <Copy className="h-3.5 w-3.5" aria-hidden="true" />}
            <span className="ml-1.5">{copied ? "Link copiado" : "Copiar link"}</span>
          </Button>
        </div>
      )}

      {!compact && (
        <Button type="submit" disabled={invite.isPending || !email.trim()} className="min-h-11 self-end sm:min-h-9">
          {invite.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />}
          Enviar invitación
        </Button>
      )}
    </form>
  )
}
