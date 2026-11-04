"use client"

/**
 * TeamSection — C-05 Bloque G / Task 7.3
 *
 * Minimal team management UI shown in Configuración → Equipo tab.
 * Allows account owners and admins to:
 *   - See current members + their roles
 *   - Invite a new member by email WITH a set of roles (gated by plan max_users quota)
 *
 * multiusuario-operativo (tanda C, D14): la invitación rápida ya NO usa el overload de 2 argumentos de
 * `rpc_invite_member` (que resolvía a `viewer` sin que nadie lo eligiera y se retiró de la base): comparte
 * `InviteMemberForm` con /organizacion/invitar —declara el conjunto de roles y va por FastAPI
 * (`POST /members/invitations`), que crea la invitación y encola el email—. La aceptación vive en
 * /invitacion/[token]. Las invitaciones pendientes (reenviar / revocar) se gestionan en /organizacion/invitar.
 *
 * Quien no es dueño ni administrador ve la lista de miembros en sólo lectura (sin formulario).
 *
 * Governance: MEDIUM — business logic for invitations.
 */

import React, { useState } from "react"
import Link from "next/link"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useTeamMembers, type TeamMemberRow } from "@/hooks/data/use-team-members"
import { useMembers } from "@/hooks/data/use-members"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Separator } from "@/components/ui/separator"
import { Crown, Shield, UserPlus, Users, Loader2, AlertCircle, Lock, Settings } from "lucide-react"
import { InviteMemberForm } from "@/components/invitations/InviteMemberForm"

// ── Types ────────────────────────────────────────────────────────────────────
// MemberRow / useTeamMembers viven en hooks/data/use-team-members.ts
// (sucursal-guard-vaciado-auditoria: BranchList.tsx pasó a necesitar el
// mismo dato para resolver autoría — regla del proyecto, reutilización
// antes que repetición).
type MemberRow = TeamMemberRow

// ── Main component ────────────────────────────────────────────────────────────

export function TeamSection() {
  const { user } = useAuth()
  const { limits } = usePlanLimits()

  const accountId   = user?.accountId ?? ""
  const accountRole = user?.accountRole ?? "member"
  const isOwner     = accountRole === "owner"
  // Dueño y administrador invitan (CAN_CONFIGURE); el administrador nunca con propietario ni administrador.
  const canManage   = isOwner || accountRole === "admin"

  const { data: members = [], isLoading: membersLoading } = useTeamMembers(accountId)
  // Nombre y email de cada miembro salen de /members (rpc_list_account_members, SECURITY DEFINER), cruzado por
  // user_id: el email no está en profiles (vive en auth.users) y la RLS de profiles sólo deja leer el perfil
  // PROPIO, así que el nombre de un compañero tampoco llega por useTeamMembers. El perfil queda de respaldo
  // del nombre propio mientras /members no responde; sin email resuelto la fila conserva el fallback al user_id.
  const { members: directory } = useMembers(accountId || null)
  const directoryByUserId = new Map(directory.map((row) => [row.user_id, row]))

  const maxUsers   = limits?.maxUsers ?? 1
  const curUsers   = members.length
  const canInvite  = canManage && curUsers < maxUsers
  // Plans with max_users > 1 allow multiple members
  const planAllowsTeam = (limits?.maxUsers ?? 1) > 1

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className="flex flex-col gap-4">
      {/* Member list card */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <div className="flex items-center justify-between">
            <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
              <Users className="h-4 w-4" />
              Equipo
            </CardTitle>
            <Badge variant="outline" className="text-xs text-muted-foreground">
              {curUsers} / {maxUsers} {maxUsers === 1 ? "usuario" : "usuarios"}
            </Badge>
          </div>
          <CardDescription className="text-xs text-muted-foreground mt-1">
            {planAllowsTeam
              ? "Miembros con acceso a esta cuenta"
              : "Tu plan actual solo permite 1 usuario. Actualizá para agregar equipo."}
          </CardDescription>
        </CardHeader>

        <CardContent className="flex flex-col gap-2">
          {membersLoading ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
              Cargando miembros…
            </div>
          ) : members.length === 0 ? (
            <p className="text-sm text-muted-foreground py-2">No hay miembros registrados.</p>
          ) : (
            members.map((m, idx) => (
              <React.Fragment key={m.id}>
                {idx > 0 && <Separator className="bg-border" />}
                <div className="flex items-center justify-between py-0.5">
                  <div className="flex flex-col gap-0.5">
                    <span className="text-sm text-foreground font-medium">
                      {directoryByUserId.get(m.user_id)?.name ?? m.profiles?.name ?? "Usuario"}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {directoryByUserId.get(m.user_id)?.email ?? m.user_id}
                    </span>
                  </div>
                  <RoleBadge role={m.role} />
                </div>
              </React.Fragment>
            ))
          )}
          {/* Quick links to dedicated role management pages */}
          {canManage && planAllowsTeam && (
            <div className="flex gap-2 pt-1 mt-1 border-t border-border">
              <Link href="/organizacion/roles">
                <Button variant="outline" size="sm" className="gap-1.5 text-xs border-border text-foreground">
                  <Settings className="h-3.5 w-3.5" />
                  Gestión de roles
                </Button>
              </Link>
              <Link href="/organizacion/invitar">
                <Button variant="outline" size="sm" className="gap-1.5 text-xs border-border text-foreground">
                  <UserPlus className="h-3.5 w-3.5" />
                  Invitar miembro
                </Button>
              </Link>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Invite form — owners only, gated by quota */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
            <UserPlus className="h-4 w-4" />
            Invitar miembro
          </CardTitle>
          {!canManage && (
            <CardDescription className="text-xs text-muted-foreground">
              Solo el dueño o un administrador puede invitar nuevos miembros.
            </CardDescription>
          )}
        </CardHeader>

        <CardContent>
          {!planAllowsTeam ? (
            /* Plan lock — show upgrade prompt */
            <div className="flex items-start gap-3 rounded-lg bg-muted/40 border border-border p-3">
              <Lock className="h-4 w-4 text-muted-foreground mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <p className="text-sm text-foreground font-medium">Función de equipo no disponible</p>
                <p className="text-xs text-muted-foreground">
                  El plan <strong>Gratis</strong> permite 1 usuario. Actualizá al plan{" "}
                  <strong>Inicial</strong> o superior para invitar miembros a tu equipo.
                </p>
              </div>
            </div>
          ) : !canManage ? (
            /* Sin autoridad para invitar: informativo */
            <p className="text-sm text-muted-foreground">
              Contactá al dueño de la cuenta para gestionar los miembros del equipo.
            </p>
          ) : !canInvite ? (
            /* Quota reached */
            <div className="flex items-start gap-3 rounded-lg bg-muted/40 border border-border p-3">
              <AlertCircle className="h-4 w-4 text-yellow-500 mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <p className="text-sm text-foreground font-medium">Cupo de equipo alcanzado</p>
                <p className="text-xs text-muted-foreground">
                  Tu cuenta tiene {curUsers}/{maxUsers} miembros. Actualizá tu plan para agregar más.
                </p>
              </div>
            </div>
          ) : (
            /* Invitación rápida: email + conjunto de roles, por FastAPI (misma pieza que /organizacion/invitar) */
            <div className="flex flex-col gap-3">
              <InviteMemberForm callerRole={accountRole} idPrefix="team" compact />
              <p className="text-xs text-muted-foreground">
                Le mandamos un email con el link para sumarse. Las invitaciones pendientes se gestionan en{" "}
                <Link href="/organizacion/invitar" className="text-foreground underline underline-offset-2">
                  Invitar miembro
                </Link>
                .
              </p>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}

// ── Sub-component: Role badge ─────────────────────────────────────────────────

function RoleBadge({ role }: { role: "owner" | "admin" | "member" }) {
  if (role === "owner") {
    return (
      <Badge className="bg-yellow-500/20 text-yellow-600 border-yellow-500/30 text-xs gap-1">
        <Crown className="h-2.5 w-2.5" />
        Owner
      </Badge>
    )
  }
  if (role === "admin") {
    return (
      <Badge className="bg-blue-500/20 text-blue-600 border-blue-500/30 text-xs gap-1">
        <Shield className="h-2.5 w-2.5" />
        Admin
      </Badge>
    )
  }
  return (
    <Badge variant="outline" className="text-xs text-muted-foreground">
      Miembro
    </Badge>
  )
}
