"use client"

/**
 * /organizacion/invitar — la invitación de punta a punta (multiusuario-operativo tanda C, grupo 17).
 *
 * Antes (v3-rbac-multirole Parte C) esta pantalla creaba la fila por supabase-js y mostraba el token
 * para que el administrador lo compartiera a mano: no existía ni el email ni la ruta de aceptación.
 * Ahora:
 *   · INVITA por FastAPI (`POST /members/invitations`): crea la invitación y encola el email en la misma
 *     transacción; «Copiar link» queda como opción secundaria (OQ-6) y copia el LINK, no el token suelto.
 *   · LISTA las invitaciones de la cuenta con «Reenviar» (rota el token) y «Revocar» (con confirmación).
 *
 * El invitador nunca puede declarar owner/admin salvo que él mismo sea owner (org-roles, «Invitación
 * diferenciada por rol que puede invitar»). El gating comercial es sólo por cupo de usuarios.
 */

import Link from "next/link"
import { ArrowLeft, Users } from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useMembers } from "@/hooks/data/use-members"
import { InviteMemberForm } from "@/components/invitations/InviteMemberForm"
import { PendingInvitations } from "@/components/invitations/PendingInvitations"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"

export default function InvitarPage() {
  const { user } = useAuth()
  const { role: callerRole } = useOrgRole()
  const { limits } = usePlanLimits()

  const accountId = user?.accountId ?? ""
  const canInvite = callerRole === "owner" || callerRole === "admin"

  // Miembros actuales para mostrar el cupo (los mismos de /organizacion/roles).
  const { members } = useMembers(accountId || null)
  const memberCount = members.length

  const maxUsers = limits?.maxUsers ?? 1
  const quotaFull = memberCount >= maxUsers

  return (
    <div className="mx-auto flex min-w-0 max-w-lg flex-col gap-6">
      <div className="flex items-center gap-3">
        <Link
          href="/organizacion/roles"
          aria-label="Volver a la gestión de roles"
          className="text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">Invitar miembro</h1>
          <p className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
            <Users className="h-3.5 w-3.5" aria-hidden="true" />
            {memberCount} de {maxUsers} usuarios usados
          </p>
        </div>
      </div>

      {quotaFull && (
        <div className="rounded-lg border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
          <strong>Cupo lleno.</strong> Actualizá tu plan para agregar más miembros.
          <div className="mt-2">
            <Link href="/configuracion">
              <Button size="sm" variant="outline" className="min-h-11 border-warning/50 text-warning sm:min-h-8">
                Ver planes
              </Button>
            </Link>
          </div>
        </div>
      )}

      {!canInvite && (
        <div className="rounded-lg border border-border bg-muted/30 px-4 py-3 text-sm text-muted-foreground">
          Solo el dueño o un administrador puede invitar miembros.
        </div>
      )}

      {canInvite && !quotaFull && (
        <Card className="border-border bg-card">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-card-foreground">Nueva invitación</CardTitle>
            <CardDescription className="text-xs text-muted-foreground">
              Le mandamos un email a la persona con un link para sumarse a tu negocio. Tiene que ingresar (o crear su
              cuenta) con ese mismo email. La invitación vence en 7 días.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <InviteMemberForm callerRole={callerRole} idPrefix="invitar" />
          </CardContent>
        </Card>
      )}

      {canInvite && (
        <section aria-labelledby="invitaciones-titulo" className="flex flex-col gap-3">
          <h2 id="invitaciones-titulo" className="text-sm font-semibold text-foreground">
            Invitaciones
          </h2>
          <PendingInvitations />
        </section>
      )}
    </div>
  )
}
