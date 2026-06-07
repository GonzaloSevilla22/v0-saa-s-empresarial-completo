"use client"

import { useMemo, useState } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Crown, Shield, User, Trash2, Loader2, UserPlus, ArrowLeft } from "lucide-react"
import { toast } from "sonner"
import { formatDate } from "@/lib/format"
import Link from "next/link"
import type { OrgRole } from "@/lib/types"

interface MemberRow {
  id: string
  user_id: string
  role: OrgRole
  created_at: string
  profiles: { name: string | null; email: string | null } | null
}

const ROLE_LABELS: Record<OrgRole, string> = {
  owner:  "Owner",
  admin:  "Admin",
  member: "Miembro",
}

const ROLE_ICONS: Record<OrgRole, React.ElementType> = {
  owner:  Crown,
  admin:  Shield,
  member: User,
}

const ROLE_COLORS: Record<OrgRole, string> = {
  owner:  "bg-yellow-500/15 text-yellow-600 border-yellow-500/30 dark:text-yellow-400",
  admin:  "bg-blue-500/15 text-blue-600 border-blue-500/30 dark:text-blue-400",
  member: "bg-muted text-muted-foreground",
}

function RoleBadge({ role }: { role: OrgRole }) {
  const Icon = ROLE_ICONS[role]
  return (
    <Badge variant="outline" className={`gap-1 text-xs ${ROLE_COLORS[role]}`}>
      <Icon className="h-3 w-3" />
      {ROLE_LABELS[role]}
    </Badge>
  )
}

export default function RolesPage() {
  const { user } = useAuth()
  const { role: callerRole } = useOrgRole()
  const { limits } = usePlanLimits()
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  const accountId  = user?.accountId ?? ""
  const billingPlan = user?.billingPlan ?? "gratis"
  const isOwner    = callerRole === "owner"
  const isAdmin    = callerRole === "admin"
  const canManage  = isOwner || isAdmin

  // Members query
  const { data: members = [], isLoading } = useQuery<MemberRow[]>({
    queryKey: ["teamMembers", accountId],
    queryFn:  async () => {
      const { data, error } = await supabase
        .from("account_members")
        .select("id, user_id, role, created_at, profiles(name, email)")
        .eq("account_id", accountId)
        .order("created_at", { ascending: true })
      if (error) throw error
      return (data ?? []) as unknown as MemberRow[]
    },
    enabled:   !!accountId,
    staleTime: 60_000,
  })

  // Change role mutation
  const [changingId, setChangingId] = useState<string | null>(null)
  const changeRoleMutation = useMutation({
    mutationFn: async ({ targetUserId, newRole }: { targetUserId: string; newRole: string }) => {
      const { data, error } = await supabase.rpc("rpc_change_member_role", {
        p_account_id:     accountId,
        p_target_user_id: targetUserId,
        p_new_role:       newRole,
      })
      if (error) throw error
      const result = data as { ok?: boolean; error?: string }
      if (result?.error) throw new Error(result.error)
      return result
    },
    onSuccess: () => {
      toast.success("Rol actualizado")
      queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
      queryClient.invalidateQueries({ queryKey: ["orgRole", accountId] })
    },
    onError: (err: Error) => toast.error(err.message),
    onSettled: () => setChangingId(null),
  })

  // Remove member mutation
  const [removingId, setRemovingId] = useState<string | null>(null)
  const removeMutation = useMutation({
    mutationFn: async (targetUserId: string) => {
      const { data, error } = await supabase.rpc("rpc_remove_member", {
        p_account_id:     accountId,
        p_target_user_id: targetUserId,
      })
      if (error) throw error
      const result = data as { ok?: boolean; error?: string }
      if (result?.error) throw new Error(result.error)
      return result
    },
    onSuccess: () => {
      toast.success("Miembro eliminado")
      queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
    },
    onError: (err: Error) => toast.error(err.message),
    onSettled: () => setRemovingId(null),
  })

  // Roles available in the selector based on caller and plan
  const availableRoles = useMemo((): OrgRole[] => {
    if (!isOwner) return ["member"]
    if (billingPlan === "pro") return ["owner", "admin", "member"]
    return ["owner", "member"]
  }, [isOwner, billingPlan])

  const maxUsers = limits?.maxUsers ?? 1

  return (
    <div className="flex flex-col gap-6 max-w-2xl mx-auto">
      <div className="flex items-center gap-3">
        <Link href="/configuracion" className="text-muted-foreground hover:text-foreground transition-colors">
          <ArrowLeft className="h-4 w-4" />
        </Link>
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Gestión de roles</h1>
          <p className="text-sm text-muted-foreground mt-1">
            {members.length} / {maxUsers} {maxUsers === 1 ? "usuario" : "usuarios"}
          </p>
        </div>
        <div className="ml-auto">
          <Link href="/organizacion/invitar">
            <Button size="sm" className="gap-2">
              <UserPlus className="h-4 w-4" />
              Invitar
            </Button>
          </Link>
        </div>
      </div>

      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm text-card-foreground">Miembros de la cuenta</CardTitle>
          <CardDescription className="text-xs text-muted-foreground">
            {isOwner && "Podés cambiar el rol de cualquier miembro o expulsarlos."}
            {isAdmin && "Podés cambiar el rol de los miembros o expulsarlos."}
            {!canManage && "Solo lectura — necesitás ser owner o admin para gestionar roles."}
          </CardDescription>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading && (
            <div className="flex items-center justify-center py-10 text-muted-foreground">
              <Loader2 className="h-5 w-5 animate-spin" />
            </div>
          )}

          {!isLoading && members.length === 0 && (
            <p className="px-4 py-8 text-center text-sm text-muted-foreground">Sin miembros.</p>
          )}

          <div className="divide-y divide-border">
            {members.map((m) => {
              const name  = m.profiles?.name  ?? "—"
              const email = m.profiles?.email ?? "—"
              const isSelf   = m.user_id === user?.id
              const isTarget = m.role === "owner"

              // Can caller change this member's role?
              const canChangeRole = canManage && (
                isOwner || (isAdmin && m.role === "member")
              )
              // Can caller remove this member?
              const canRemove = canManage && !isTarget && (
                isOwner || (isAdmin && m.role === "member")
              ) && !isSelf

              return (
                <div key={m.id} className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 px-4 py-3">
                  <div className="flex flex-col gap-0.5 min-w-0">
                    <span className="text-sm font-medium text-foreground truncate">
                      {name} {isSelf && <span className="text-xs text-muted-foreground">(vos)</span>}
                    </span>
                    <span className="text-xs text-muted-foreground truncate">{email}</span>
                    <span className="text-xs text-muted-foreground">{formatDate(m.created_at)}</span>
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    {canChangeRole && !isSelf ? (
                      <Select
                        value={m.role}
                        disabled={changingId === m.user_id}
                        onValueChange={(newRole) => {
                          setChangingId(m.user_id)
                          changeRoleMutation.mutate({ targetUserId: m.user_id, newRole })
                        }}
                      >
                        <SelectTrigger className="h-7 w-28 text-xs border-border bg-background">
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {availableRoles.map((r) => (
                            <SelectItem key={r} value={r} className="text-xs">
                              {ROLE_LABELS[r]}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    ) : (
                      <RoleBadge role={m.role} />
                    )}

                    {canRemove && (
                      <Button
                        variant="ghost" size="icon"
                        className="h-7 w-7 text-muted-foreground hover:text-destructive"
                        disabled={removingId === m.user_id}
                        onClick={() => {
                          setRemovingId(m.user_id)
                          removeMutation.mutate(m.user_id)
                        }}
                      >
                        {removingId === m.user_id
                          ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          : <Trash2 className="h-3.5 w-3.5" />
                        }
                      </Button>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </CardContent>
      </Card>

      {billingPlan !== "pro" && isOwner && (
        <div className="rounded-lg border border-blue-500/20 bg-blue-500/5 px-4 py-3 text-sm text-blue-600 dark:text-blue-400">
          El rol <strong>Admin</strong> está disponible solo en el plan <strong>Pro</strong>.
          Actualizá para asignar admins a tu equipo.
        </div>
      )}
    </div>
  )
}
