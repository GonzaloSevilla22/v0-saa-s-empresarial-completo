"use client"

import { useMemo, useState } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { useOrgRole } from "@/hooks/useOrgRole"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { ArrowLeft, Loader2, CheckCircle2, AlertCircle, Users } from "lucide-react"
import Link from "next/link"
import type { OrgRole } from "@/lib/types"

export default function InvitarPage() {
  const { user } = useAuth()
  const { role: callerRole } = useOrgRole()
  const { limits } = usePlanLimits()
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  const accountId   = user?.accountId  ?? ""
  const billingPlan = user?.billingPlan ?? "gratis"
  const isOwner     = callerRole === "owner"
  const isAdmin     = callerRole === "admin"
  const canInvite   = isOwner || isAdmin

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

  // Roles the caller can invite
  const availableRoles: OrgRole[] = isOwner && billingPlan === "pro"
    ? ["admin", "member"]
    : ["member"]

  // Form state
  const [email, setEmail] = useState("")
  const [role,  setRole]  = useState<OrgRole>("member")
  const [feedback, setFeedback] = useState<{ type: "success" | "error"; msg: string } | null>(null)

  const inviteMutation = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("rpc_invite_member", {
        p_email:      email.trim().toLowerCase(),
        p_account_id: accountId,
        p_role:       role,
      })
      if (error) throw error
      return data as { id: string; token: string; email: string; role: string; expires_at: string }
    },
    onSuccess: (data) => {
      setFeedback({
        type: "success",
        msg: `Invitación enviada a ${data.email} como ${data.role}. Compartí el link de aceptación.`,
      })
      setEmail("")
      setRole("member")
      queryClient.invalidateQueries({ queryKey: ["memberCount", accountId] })
      queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
    },
    onError: (err: Error) => {
      const msg = err.message ?? "Error al enviar la invitación"
      if (msg.includes("P403") || msg.toLowerCase().includes("quota")) {
        setFeedback({ type: "error", msg: "Alcanzaste el límite de miembros de tu plan." })
      } else if (msg.includes("P409")) {
        setFeedback({ type: "error", msg: "Ya existe una invitación pendiente para ese email." })
      } else if (msg.includes("P401")) {
        setFeedback({ type: "error", msg: "No tenés permisos para invitar miembros." })
      } else if (msg.toLowerCase().includes("solo el owner")) {
        setFeedback({ type: "error", msg: "Solo el owner puede invitar admins." })
      } else if (msg.toLowerCase().includes("plan pro")) {
        setFeedback({ type: "error", msg: "El rol admin requiere plan Pro." })
      } else {
        setFeedback({ type: "error", msg })
      }
    },
  })

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setFeedback(null)
    if (!email.trim()) return
    inviteMutation.mutate()
  }

  return (
    <div className="flex flex-col gap-6 max-w-lg mx-auto">
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
              Se enviará un link de aceptación para el email indicado.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="email" className="text-sm">Email</Label>
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

              <div className="flex flex-col gap-1.5">
                <Label htmlFor="role" className="text-sm">Rol</Label>
                <Select value={role} onValueChange={(v) => setRole(v as OrgRole)}>
                  <SelectTrigger id="role" className="bg-background border-border text-foreground">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {availableRoles.map((r) => (
                      <SelectItem key={r} value={r}>
                        {r === "admin"  ? "Admin — puede crear operaciones e invitar miembros" : ""}
                        {r === "member" ? "Miembro — solo lectura" : ""}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {isAdmin && (
                  <p className="text-xs text-muted-foreground">
                    Como admin, solo podés invitar miembros con rol Miembro.
                  </p>
                )}
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
