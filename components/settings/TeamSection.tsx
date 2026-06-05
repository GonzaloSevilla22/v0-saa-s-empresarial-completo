"use client"

/**
 * TeamSection — C-05 Bloque G / Task 7.3
 *
 * Minimal team management UI shown in Configuración → Equipo tab.
 * Allows account owners to:
 *   - See current members + their roles
 *   - Invite a new member by email (gated by plan max_users quota)
 *
 * Invitations are enforced server-side by:
 *   - rpc_invite_member  — creates token, validates quota (owner only)
 *   - rpc_accept_invitation — invitee accepts via token link
 *
 * Non-owners see the member list read-only (no invite form).
 *
 * Governance: MEDIUM — business logic for invitations.
 */

import React, { useState } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Separator } from "@/components/ui/separator"
import { Crown, UserPlus, Users, Loader2, AlertCircle, CheckCircle2, Lock } from "lucide-react"
import { planHasAccess } from "@/lib/plan-utils"

// ── Types ────────────────────────────────────────────────────────────────────

interface MemberRow {
  id: string
  user_id: string
  role: "owner" | "member"
  created_at: string
  profiles: {
    name: string | null
    email: string | null
  } | null
}

// ── Data fetching ─────────────────────────────────────────────────────────────

function useTeamMembers(accountId: string) {
  const supabase = createClient()
  return useQuery({
    queryKey: ["teamMembers", accountId] as const,
    queryFn: async (): Promise<MemberRow[]> => {
      const { data, error } = await supabase
        .from("account_members")
        .select("id, user_id, role, created_at, profiles(name, email)")
        .eq("account_id", accountId)
        .order("created_at", { ascending: true })

      if (error) throw error
      // Supabase infers the profiles join as an array type; cast via unknown
      // to obtain the single-row object shape (1:1 join on user_id).
      return (data ?? []) as unknown as MemberRow[]
    },
    enabled: !!accountId,
    staleTime: 60_000, // 1 minute
  })
}

// ── Main component ────────────────────────────────────────────────────────────

export function TeamSection() {
  const { user } = useAuth()
  const { limits } = usePlanLimits()
  const queryClient = useQueryClient()
  const supabase = createClient()

  const accountId   = user?.accountId ?? ""
  const accountRole = user?.accountRole ?? "member"
  const isOwner     = accountRole === "owner"

  const { data: members = [], isLoading: membersLoading } = useTeamMembers(accountId)

  const maxUsers   = limits?.maxUsers ?? 1
  const curUsers   = members.length
  const canInvite  = isOwner && curUsers < maxUsers
  // Plans with max_users > 1 allow multiple members
  const planAllowsTeam = (limits?.maxUsers ?? 1) > 1

  // ── Invite form state ──────────────────────────────────────────────────────
  const [email, setEmail]   = useState("")
  const [feedback, setFeedback] = useState<{ type: "success" | "error"; msg: string } | null>(null)

  const inviteMutation = useMutation({
    mutationFn: async (inviteEmail: string) => {
      const { data, error } = await supabase.rpc("rpc_invite_member", {
        p_email:      inviteEmail,
        p_account_id: accountId,
      })
      if (error) throw error
      return data as { id: string; token: string; email: string; expires_at: string }
    },
    onSuccess: (data) => {
      setFeedback({
        type: "success",
        msg: `Invitación enviada a ${data.email}. Compartí el link de aceptación con tu equipo.`,
      })
      setEmail("")
      queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
    },
    onError: (err: Error) => {
      const msg = err.message ?? "Error al enviar la invitación"
      if (msg.includes("P403")) {
        setFeedback({ type: "error", msg: "Alcanzaste el límite de miembros de tu plan." })
      } else if (msg.includes("P409")) {
        setFeedback({ type: "error", msg: "Ya existe una invitación pendiente para ese email." })
      } else if (msg.includes("P401")) {
        setFeedback({ type: "error", msg: "Solo el owner de la cuenta puede invitar miembros." })
      } else {
        setFeedback({ type: "error", msg })
      }
    },
  })

  function handleInvite(e: React.FormEvent) {
    e.preventDefault()
    setFeedback(null)
    if (!email.trim()) return
    inviteMutation.mutate(email.trim().toLowerCase())
  }

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
                      {m.profiles?.name ?? "Usuario"}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {m.profiles?.email ?? m.user_id}
                    </span>
                  </div>
                  <RoleBadge role={m.role} />
                </div>
              </React.Fragment>
            ))
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
          {!isOwner && (
            <CardDescription className="text-xs text-muted-foreground">
              Solo el owner de la cuenta puede invitar nuevos miembros.
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
          ) : !isOwner ? (
            /* Non-owner informational */
            <p className="text-sm text-muted-foreground">
              Contactá al owner de la cuenta para gestionar los miembros del equipo.
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
            /* Invite form */
            <form onSubmit={handleInvite} className="flex flex-col gap-3">
              <div className="flex gap-2">
                <Input
                  type="email"
                  placeholder="email@empresa.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  disabled={inviteMutation.isPending}
                  className="flex-1 text-sm"
                  required
                />
                <Button
                  type="submit"
                  size="sm"
                  disabled={inviteMutation.isPending || !email.trim()}
                  className="shrink-0"
                >
                  {inviteMutation.isPending ? (
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  ) : (
                    <UserPlus className="h-3.5 w-3.5" />
                  )}
                  <span className="ml-1.5">Invitar</span>
                </Button>
              </div>

              {feedback && (
                <div
                  className={`flex items-start gap-2 rounded-md p-2.5 text-xs ${
                    feedback.type === "success"
                      ? "bg-green-500/10 text-green-600 border border-green-500/20"
                      : "bg-red-500/10 text-red-600 border border-red-500/20"
                  }`}
                >
                  {feedback.type === "success" ? (
                    <CheckCircle2 className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                  ) : (
                    <AlertCircle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                  )}
                  {feedback.msg}
                </div>
              )}

              <p className="text-xs text-muted-foreground">
                Se generará un token de invitación. Podés compartirlo directamente con la persona invitada.
              </p>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  )
}

// ── Sub-component: Role badge ─────────────────────────────────────────────────

function RoleBadge({ role }: { role: "owner" | "member" }) {
  if (role === "owner") {
    return (
      <Badge className="bg-yellow-500/20 text-yellow-600 border-yellow-500/30 text-xs gap-1">
        <Crown className="h-2.5 w-2.5" />
        Owner
      </Badge>
    )
  }
  return (
    <Badge variant="outline" className="text-xs text-muted-foreground">
      Miembro
    </Badge>
  )
}
