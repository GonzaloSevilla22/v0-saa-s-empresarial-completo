"use client"

/**
 * /organizacion/invitar — v3-rbac-multirole Parte C (grupo 17, task 17.5).
 *
 * Invita con un CONJUNTO de roles (account-membership-roles: "La invitación
 * de un miembro admite el conjunto de roles con que se incorpora") en vez
 * de un único Select — checkboxes contra el catálogo (D1), sin el rol
 * limitado por plan (D17 lo deroga: todos los roles en todos los planes).
 * El invitador NUNCA puede declarar owner/admin salvo que él mismo sea
 * owner (org-roles, "Invitación diferenciada por rol que puede invitar") —
 * mismo criterio de autoridad que /organizacion/roles.
 */

import { useMemo, useState } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useRoleCatalog } from "@/hooks/data/use-role-catalog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { ArrowLeft, Loader2, CheckCircle2, AlertCircle, Users, Copy, Check } from "lucide-react"
import Link from "next/link"
import type { OrgRole } from "@/lib/types"

// Ronda 1 adversarial (finding MAJOR): `rpc_accept_invitation` -- la única
// función que consume `account_invitations.roles` -- no tiene NINGÚN
// llamador en toda la app: no existe una ruta "/invitacion/[token]" ni un
// flujo de email de invitación. Esta pantalla creaba la fila igual y
// prometía "se enviará un link" sin que nada lo enviara, descartando el
// `token` que la RPC sí devuelve. Mientras esa ruta de aceptación no
// exista (OQ registrada para el PO -- ver tasks.md 17.5/CHANGES.md), el
// mínimo honesto es: (a) no prometer un email que nadie manda, (b) mostrar
// el token para que el administrador lo comparta él mismo por el canal que
// prefiera (WhatsApp, email manual, etc.) -- que es justo lo que la propia
// copia de éxito le pide hacer.

export default function InvitarPage() {
  const { user } = useAuth()
  const { role: callerRole } = useOrgRole()
  const { limits } = usePlanLimits()
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  const accountId   = user?.accountId  ?? ""
  const isOwner     = callerRole === "owner"
  const isAdmin     = callerRole === "admin"
  const canInvite   = isOwner || isAdmin

  const { data: catalog = [] } = useRoleCatalog()

  // Current member count for quota display
  const { data: memberCount = 0 } = useQuery<number>({
    queryKey: ["memberCount", accountId],
    queryFn:  async () => {
      const { count, error } = await supabase
        .from("account_members")
        .select("id", { count: "exact", head: true })
        .eq("account_id", accountId)
      if (error) throw error
      return count ?? 0
    },
    enabled:   !!accountId,
    staleTime: 30_000,
  })

  const maxUsers  = limits?.maxUsers ?? 1
  const quotaFull = memberCount >= maxUsers

  // v3-rbac-multirole (D17): todos los roles están disponibles en todos los
  // planes — el gating comercial es sólo por cupo de usuarios (maxUsers).
  // org-roles ("Invitación diferenciada por rol que puede invitar"): el
  // admin nunca puede declarar owner/admin.
  const invitableRoles = useMemo(() => {
    if (isOwner) return catalog
    if (isAdmin) return catalog.filter((r) => r.code !== "owner" && r.code !== "admin")
    return []
  }, [catalog, isOwner, isAdmin])

  // Form state
  const [email, setEmail] = useState("")
  const [selectedRoles, setSelectedRoles] = useState<OrgRole[]>([])
  const [feedback, setFeedback] = useState<{ type: "success" | "error"; msg: string } | null>(null)
  // Ronda 1 adversarial (finding MAJOR): el token YA no se descarta -- se
  // guarda para mostrarlo y que el administrador lo comparta él mismo.
  const [lastInvite, setLastInvite] = useState<{ email: string; token: string } | null>(null)
  const [copied, setCopied] = useState(false)

  function toggleRole(code: OrgRole, checked: boolean) {
    setSelectedRoles((prev) => (checked ? [...prev, code] : prev.filter((r) => r !== code)))
  }

  async function copyToken(token: string) {
    try {
      await navigator.clipboard.writeText(token)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // Sin acceso al portapapeles (permiso denegado / contexto no seguro)
      // -- el token sigue visible y seleccionable a mano en el bloque de abajo.
    }
  }

  const inviteMutation = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("rpc_invite_member", {
        p_email:      email.trim().toLowerCase(),
        p_account_id: accountId,
        p_roles:      selectedRoles.length > 0 ? selectedRoles : null,
      })
      if (error) throw error
      return data as { id: string; token: string; email: string; roles: string[]; expires_at: string }
    },
    onSuccess: (data) => {
      const roleLabels = (data.roles ?? [])
        .map((code) => catalog.find((c) => c.code === code)?.label ?? code)
        .join(", ")
      setFeedback({
        type: "success",
        msg: `Invitación creada para ${data.email} con el rol${data.roles?.length > 1 ? "es" : ""} ${roleLabels || "Observador"}.`,
      })
      setLastInvite({ email: data.email, token: data.token })
      setCopied(false)
      setEmail("")
      setSelectedRoles([])
      queryClient.invalidateQueries({ queryKey: ["memberCount", accountId] })
      queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
      queryClient.invalidateQueries({ queryKey: ["members", "list", accountId] })
    },
    onError: (err: Error) => {
      const msg = err.message ?? "Error al enviar la invitación"
      if (msg.includes("member quota reached") || msg.includes("P403")) {
        setFeedback({ type: "error", msg: "Alcanzaste el límite de miembros de tu plan." })
      } else if (msg.includes("pending invitation already exists") || msg.includes("P409")) {
        setFeedback({ type: "error", msg: "Ya existe una invitación pendiente para ese email." })
      } else if (msg.toLowerCase().includes("owner or admin") || msg.includes("P401")) {
        setFeedback({ type: "error", msg: "No tenés permisos para invitar miembros." })
      } else if (msg.toLowerCase().includes("solo el owner")) {
        setFeedback({ type: "error", msg: "Solo el owner puede invitar con esos roles." })
      } else {
        setFeedback({ type: "error", msg })
      }
    },
  })

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setFeedback(null)
    setLastInvite(null)
    if (!email.trim()) return
    inviteMutation.mutate()
  }

  return (
    <div className="flex flex-col gap-6 max-w-lg mx-auto min-w-0">
      <div className="flex items-center gap-3">
        <Link href="/organizacion/roles" className="text-muted-foreground hover:text-foreground transition-colors">
          <ArrowLeft className="h-4 w-4" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Invitar miembro</h1>
          <p className="text-sm text-muted-foreground mt-1 flex items-center gap-1.5">
            <Users className="h-3.5 w-3.5" />
            {memberCount} de {maxUsers} usuarios usados
          </p>
        </div>
      </div>

      {quotaFull && (
        <div className="rounded-lg border border-orange-500/30 bg-orange-500/10 px-4 py-3 text-sm text-orange-600 dark:text-orange-400">
          <strong>Cupo lleno.</strong> Actualizá tu plan para agregar más miembros.
          <div className="mt-2">
            <Link href="/configuracion">
              <Button size="sm" variant="outline" className="border-orange-500/40 text-orange-600 dark:text-orange-400">
                Ver planes
              </Button>
            </Link>
          </div>
        </div>
      )}

      {!canInvite && (
        <div className="rounded-lg border border-border bg-muted/30 px-4 py-3 text-sm text-muted-foreground">
          Solo el owner o admin puede invitar miembros.
        </div>
      )}

      {canInvite && !quotaFull && (
        <Card className="border-border bg-card">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-card-foreground">Nueva invitación</CardTitle>
            <CardDescription className="text-xs text-muted-foreground">
              Genera un código de invitación para el email indicado — todavía no se
              envía por email: copiá el código y compartilo vos mismo con la persona invitada.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="email">Email</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="colaborador@email.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  className="bg-background border-border text-foreground"
                />
              </div>

              <div className="flex flex-col gap-2">
                <Label id="invite-roles-label">Roles</Label>
                <div
                  role="group"
                  aria-labelledby="invite-roles-label"
                  className="flex flex-col gap-2 rounded-md border border-border p-3"
                >
                  {invitableRoles.length === 0 && (
                    <p className="text-xs text-muted-foreground">No tenés autoridad para invitar con ningún rol.</p>
                  )}
                  {invitableRoles.map((r) => (
                    <div key={r.code} className="flex items-start gap-2">
                      <Checkbox
                        id={`invite-role-${r.code}`}
                        checked={selectedRoles.includes(r.code)}
                        onCheckedChange={(checked) => toggleRole(r.code, checked === true)}
                        className="mt-0.5 rounded-[3px]"
                      />
                      <Label htmlFor={`invite-role-${r.code}`} className="flex flex-col gap-0.5 font-normal cursor-pointer">
                        <span className="text-sm text-foreground">{r.label}</span>
                        <span className="text-xs text-muted-foreground">{r.description}</span>
                      </Label>
                    </div>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  Sin roles seleccionados, se incorpora como Observador (solo lectura).
                </p>
              </div>

              {feedback && (
                <div className={`flex items-start gap-2 rounded-md px-3 py-2.5 text-sm ${
                  feedback.type === "success"
                    ? "bg-green-500/10 text-green-600 dark:text-green-400 border border-green-500/20"
                    : "bg-destructive/10 text-destructive border border-destructive/20"
                }`}>
                  {feedback.type === "success"
                    ? <CheckCircle2 className="h-4 w-4 mt-0.5 shrink-0" />
                    : <AlertCircle   className="h-4 w-4 mt-0.5 shrink-0" />
                  }
                  {feedback.msg}
                </div>
              )}

              {/* Ronda 1 adversarial (finding MAJOR): el token ya no se
                  descarta -- se muestra para que el administrador lo
                  comparta él mismo (no existe todavía una ruta de
                  aceptación en la app; ver comentario al inicio del archivo). */}
              {lastInvite && (
                <div className="flex flex-col gap-1.5 rounded-md border border-border bg-muted/30 p-3">
                  <Label htmlFor="invite-token" className="text-xs">
                    Código de invitación para {lastInvite.email}
                  </Label>
                  <div className="flex items-center gap-2">
                    <code
                      id="invite-token"
                      className="flex-1 min-w-0 truncate rounded bg-background border border-border px-2 py-1.5 text-xs text-foreground"
                    >
                      {lastInvite.token}
                    </code>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() => copyToken(lastInvite.token)}
                      aria-label="Copiar código de invitación"
                    >
                      {copied
                        ? <Check className="h-3.5 w-3.5" />
                        : <Copy className="h-3.5 w-3.5" />
                      }
                      <span className="ml-1.5">{copied ? "Copiado" : "Copiar"}</span>
                    </Button>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    Compartilo con la persona invitada por el medio que prefieras
                    (WhatsApp, email). Vence en 7 días.
                  </p>
                </div>
              )}

              <Button
                type="submit"
                disabled={inviteMutation.isPending || !email.trim()}
                className="self-end"
              >
                {inviteMutation.isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
                Enviar invitación
              </Button>
            </form>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
