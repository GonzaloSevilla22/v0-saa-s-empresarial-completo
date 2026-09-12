"use client"

/**
 * /organizacion/roles — v3-rbac-multirole Parte C (grupo 17, D0 6.3).
 *
 * Extiende la pantalla EN EL LUGAR (misma ruta, mismos accesos desde
 * /organizacion/invitar y /configuracion → TeamSection): pasa del selector
 * de un rol único (owner|admin|member) a la gestión del CONJUNTO de roles
 * de cada miembro, con vencimiento opcional — account-membership-roles, "La
 * gestión de miembros y sus roles tiene superficie propia".
 *
 * Etiquetas SIEMPRE desde el catálogo (useRoleCatalog, D1) — nunca un objeto
 * hardcodeado como el ROLE_LABELS que tenía esta pantalla antes. Sin el
 * aviso "Admin sólo en plan Pro" (D17, derogado). Lectura abierta a
 * cualquier miembro; las acciones de gestión (asignar/revocar/quitar) sólo
 * se muestran a owner/admin.
 */

import { useMemo, useState } from "react"
import { useAuth } from "@/contexts/auth-context"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useMembers, type MemberRow } from "@/hooks/data/use-members"
import { useRoleCatalog, resolveRoleLabel } from "@/hooks/data/use-role-catalog"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Card, CardContent, CardFooter, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { Crown, Loader2, UserPlus, ArrowLeft, Plus, X, UserMinus, CalendarClock } from "lucide-react"
import { toast } from "sonner"
import { formatDate, localDateEndOfDayISO } from "@/lib/format"
import Link from "next/link"
import type { OrgRole } from "@/lib/types"
import { humanizeOperationError } from "@/lib/operation-errors"

function friendlyMessage(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err)
  return humanizeOperationError(raw).message
}

export default function RolesPage() {
  const { user } = useAuth()
  const { role: callerRole } = useOrgRole()

  const accountId = user?.accountId ?? null
  const isOwner = callerRole === "owner"
  const isAdmin = callerRole === "admin"
  const canManage = isOwner || isAdmin

  const { data: catalog = [], isLoading: catalogLoading } = useRoleCatalog()
  const {
    members, isLoading, assignRole, revokeRole, removeMember,
    assignRoleMutation, revokeRoleMutation, removeMemberMutation,
  } = useMembers(accountId)

  // Ronda 3 adversarial (fix defensivo del MAJOR-1): con accountId sin
  // resolver, useMembers queda `enabled: false` -- isLoading nunca pasa por
  // `true` y `members` cae en `[]` por default, así que sin este chequeo la
  // pantalla mostraba "Sin miembros." (y habilitaba el CTA de gestión) como
  // si la cuenta REALMENTE no tuviera nadie, en vez de admitir que no pudo
  // resolver la cuenta activa del usuario.
  const accountUnresolved = !accountId

  // Roles que ESTE caller puede otorgar/revocar — defensa en profundidad
  // (D-org-roles "Cambio de rol controlado por jerarquía": el admin nunca
  // otorga owner/admin). La RPC ya lo hace cumplir; esto sólo evita
  // ofrecer en el selector una opción que va a rebotar con P0403.
  const assignableRoles = useMemo(() => {
    if (isOwner) return catalog
    if (isAdmin) return catalog.filter((r) => r.code !== "owner" && r.code !== "admin")
    return []
  }, [catalog, isOwner, isAdmin])

  // Ronda 2 adversarial (finding NIT, corregido): la base SÍ acepta que un
  // owner revoque el rol owner de OTRO owner cuando queda al menos uno
  // activo (rpc_revoke_member_role, vector V15 verificado) -- la pantalla
  // no ofrecía NINGÚN camino para repartir/ceder la propiedad porque el
  // badge de owner bloqueaba la X incondicionalmente. Contar los owners
  // ACTIVOS del conjunto ya cargado (rpc_list_account_members) alcanza sin
  // una consulta propia -- sólo el propio caller-owner puede intentarlo, y
  // sólo cuando hacerlo no dejaría a la cuenta sin ninguno (el invariante
  // P0405 lo sigue aplicando la base como defensa en profundidad).
  const activeOwnerCount = useMemo(
    () => members.filter((m) => m.roles.some((r) => r.role === "owner" && r.is_active)).length,
    [members],
  )
  const canTransferOwnership = isOwner && activeOwnerCount > 1

  return (
    <div className="flex flex-col gap-6 max-w-3xl mx-auto min-w-0">
      <div className="flex items-center gap-3">
        <Link href="/configuracion" className="text-muted-foreground hover:text-foreground transition-colors">
          <ArrowLeft className="h-4 w-4" />
        </Link>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Gestión de roles</h1>
          <p className="text-sm text-muted-foreground mt-1">
            {accountUnresolved
              ? "Cuenta no resuelta"
              : `${members.length} ${members.length === 1 ? "miembro" : "miembros"}`}
          </p>
        </div>
        {canManage && !accountUnresolved && (
          <div className="ml-auto shrink-0">
            <Link href="/organizacion/invitar">
              <Button size="sm" className="gap-2">
                <UserPlus className="h-4 w-4" />
                Invitar
              </Button>
            </Link>
          </div>
        )}
      </div>

      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm text-card-foreground">Miembros de la cuenta</CardTitle>
          <CardDescription className="text-xs text-muted-foreground">
            {canManage
              ? "Asigná y revocá roles, con vencimiento opcional, para cada miembro."
              : "Solo lectura — necesitás ser owner o admin para gestionar roles."}
          </CardDescription>
        </CardHeader>
        <CardContent className="p-0">
          {/* Ronda 3 adversarial (fix defensivo del MAJOR-1): `accountId`
              falsy (auth-context no pudo resolver la membresía) deja
              `useMembers` deshabilitado -- isLoading nunca es true y
              `members` cae en `[]`, así que sin esta rama la pantalla
              mostraba "Sin miembros." (estado vacío legítimo) para un caso
              que en realidad es un fallo de resolución de cuenta. */}
          {accountUnresolved ? (
            <div className="px-4 py-8 text-center">
              <p className="text-sm text-foreground">No se pudo resolver tu cuenta.</p>
              <p className="mt-1 text-xs text-muted-foreground">
                Recargá la página o cerrá sesión y volvé a entrar. Si el problema persiste, contactá a soporte.
              </p>
            </div>
          ) : (
            <>
              {(isLoading || catalogLoading) && (
                <div className="flex items-center justify-center py-10 text-muted-foreground">
                  <Loader2 className="h-5 w-5 animate-spin" />
                </div>
              )}

              {!isLoading && !catalogLoading && members.length === 0 && (
                <p className="px-4 py-8 text-center text-sm text-muted-foreground">Sin miembros.</p>
              )}

              <div className="divide-y divide-border">
                {members.map((member) => (
                  <MemberRow
                    key={member.member_id}
                    member={member}
                    isSelf={member.user_id === user?.id}
                    canManage={canManage}
                    canTransferOwnership={canTransferOwnership}
                    catalog={catalog}
                    assignableRoles={assignableRoles}
                    onAssign={async (role, expiresAt) => {
                      try {
                        await assignRole({ userId: member.user_id, role, expiresAt })
                        toast.success("Rol asignado")
                      } catch (err) {
                        toast.error(friendlyMessage(err))
                        throw err
                      }
                    }}
                    onRevoke={async (role) => {
                      try {
                        await revokeRole({ userId: member.user_id, role })
                        toast.success("Rol revocado")
                      } catch (err) {
                        toast.error(friendlyMessage(err))
                      }
                    }}
                    onRemove={async () => {
                      try {
                        await removeMember(member.user_id)
                        toast.success("Miembro eliminado")
                      } catch (err) {
                        toast.error(friendlyMessage(err))
                      }
                    }}
                    isAssigning={assignRoleMutation.isPending}
                    isRevoking={revokeRoleMutation.isPending}
                    isRemoving={removeMemberMutation.isPending}
                  />
                ))}
              </div>
            </>
          )}
        </CardContent>
        {/* Ronda 2 adversarial (finding NIT, corregido): este aviso vivía
            ENTRE el header y la lista de miembros, así que con un solo
            miembro la pantalla mostraba a la vez "Todavía sos el único
            miembro" Y la fila de ese mismo miembro debajo — el mensaje de
            vacío competía con el contenido que decía que no había. Movido a
            un pie de tarjeta, DESPUÉS de la fila: ahora lee como un aviso
            complementario ("acá estás vos — invitá a tu equipo"), no como
            un estado vacío contradicho por lo que sigue. */}
        {!accountUnresolved && !isLoading && !catalogLoading && members.length === 1 && (
          <CardFooter className="border-t border-border px-4 py-3">
            <p className="text-sm text-muted-foreground">
              Sos el único miembro de esta cuenta.{" "}
              {canManage && (
                <Link href="/organizacion/invitar" className="text-primary underline underline-offset-2">
                  Invitá a tu equipo
                </Link>
              )}
            </p>
          </CardFooter>
        )}
      </Card>
    </div>
  )
}

// ── Fila de miembro ──────────────────────────────────────────────────────────

interface MemberRowProps {
  member: MemberRow
  isSelf: boolean
  canManage: boolean
  /** Ronda 2 adversarial (finding NIT): sólo true para el caller-owner
   * cuando la cuenta tiene MÁS de un owner activo — habilita ceder/repartir
   * la propiedad (rpc_revoke_member_role lo acepta, vector V15). */
  canTransferOwnership: boolean
  catalog: { code: OrgRole; label: string; description: string; sort_order: number; is_writer: boolean }[]
  assignableRoles: { code: OrgRole; label: string }[]
  onAssign: (role: OrgRole, expiresAt: string | null) => Promise<void>
  onRevoke: (role: OrgRole) => Promise<void>
  onRemove: () => Promise<void>
  isAssigning: boolean
  isRevoking: boolean
  isRemoving: boolean
}

function MemberRow({
  member, isSelf, canManage, canTransferOwnership, catalog, assignableRoles,
  onAssign, onRevoke, onRemove, isAssigning, isRevoking, isRemoving,
}: MemberRowProps) {
  const name = member.name ?? "—"
  const email = member.email ?? "—"
  const isOwnerMember = member.legacy_role === "owner"
  // No se puede quitar al propio owner ni a uno mismo — mismo criterio que
  // rpc_remove_member (Parte A) ya hace cumplir en la base; se refleja acá
  // para no ofrecer un botón que va a rebotar.
  const canRemoveThis = canManage && !isOwnerMember && !isSelf

  return (
    <div className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="flex flex-col gap-1 min-w-0">
        <span className="text-sm font-medium text-foreground truncate">
          {name} {isSelf && <span className="text-xs text-muted-foreground">(vos)</span>}
        </span>
        <span className="text-xs text-muted-foreground truncate">{email}</span>
        <span className="text-xs text-muted-foreground">Desde {formatDate(member.created_at)}</span>

        <div className="flex flex-wrap gap-1.5 mt-1.5" role="list" aria-label={`Roles de ${name}`}>
          {member.roles.length === 0 && (
            <span className="text-xs text-muted-foreground italic">Sin roles asignados</span>
          )}
          {member.roles.map((assignment) => (
            <RoleAssignmentBadge
              key={assignment.role}
              assignment={assignment}
              label={resolveRoleLabel(catalog, assignment.role)}
              canRevoke={assignment.role === "owner" ? canTransferOwnership : canManage}
              onRevoke={() => onRevoke(assignment.role)}
              isRevoking={isRevoking}
            />
          ))}
        </div>
      </div>

      {canManage && (
        <div className="flex items-center gap-2 shrink-0">
          <AssignRoleDialog
            memberName={name}
            assignableRoles={assignableRoles}
            existingRoles={member.roles.map((r) => r.role)}
            onAssign={onAssign}
            isAssigning={isAssigning}
          />
          {canRemoveThis && (
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="ghost" size="icon"
                  className="h-8 w-8 text-muted-foreground hover:text-destructive"
                  disabled={isRemoving}
                  aria-label={`Quitar a ${name} de la cuenta`}
                >
                  <UserMinus className="h-4 w-4" />
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="bg-card border-border">
                <AlertDialogHeader>
                  <AlertDialogTitle className="text-card-foreground">Quitar miembro</AlertDialogTitle>
                  <AlertDialogDescription>
                    {name} perderá el acceso a esta cuenta de inmediato. Esta acción no se puede deshacer.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="border-border text-foreground">Cancelar</AlertDialogCancel>
                  <AlertDialogAction
                    className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                    onClick={() => onRemove()}
                  >
                    Quitar
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          )}
        </div>
      )}
    </div>
  )
}

// ── Badge de una asignación de rol (vigente vs vencida) ─────────────────────

function RoleAssignmentBadge({
  assignment, label, canRevoke, onRevoke, isRevoking,
}: {
  assignment: MemberRow["roles"][number]
  label: string
  canRevoke: boolean
  onRevoke: () => void
  isRevoking: boolean
}) {
  const isOwnerRole = assignment.role === "owner"
  return (
    <Badge
      role="listitem"
      variant="outline"
      className={`gap-1.5 text-xs pr-1 ${
        !assignment.is_active
          // Ronda 2 adversarial: antes llevaba `opacity-60` además del token.
          // Medido en vivo con el stack local (composición alpha sobre el
          // fondo efectivo de la tarjeta): la etiqueta del rol vencido caía a
          // **2,32:1** en tema claro y 3,36:1 en oscuro — por debajo del
          // 4,5:1 de WCAG AA. El token `text-muted-foreground` SÍ cumple
          // (4,83:1 claro / 7,24:1 oscuro): el que rompía era el multiplicador
          // de opacidad encima del token, exactamente el punto ciego del gate
          // `token-contrast-aa` (que valida los pares de `globals.css` a
          // opacidad plena y no ve una utilidad `opacity-*` aplicada en la
          // pantalla). El estado vencido sigue distinguiéndose por el tachado,
          // por el color apagado frente al `primary`/`warning` del vigente y
          // por el texto "venció {fecha}" — ninguno de los tres depende de
          // atenuar el contraste.
          ? "border-border text-muted-foreground line-through decoration-1"
          : isOwnerRole
            // Ronda 1 adversarial: antes `bg-yellow-500/15 text-yellow-600
            // border-yellow-500/30 dark:text-yellow-400` (literal de paleta,
            // heredado del ROLE_COLORS de la pantalla vieja). Medido en vivo:
            // 2,66:1 en tema claro — por debajo del 4,5:1 de WCAG AA, y fuera
            // del alcance del gate `token-contrast-aa`, que sólo cubre los
            // tokens semánticos de globals.css. Pasa al par canónico
            // superficie/texto del rol `warning` (mismo patrón que
            // ClientActivityBadge y ExpenseJournalStatusBadge): `text-warning`
            // resuelve a `--warning-text`, calibrado para AA en ambos temas.
            ? "bg-warning/15 text-warning border-warning/30"
            : "bg-primary/10 text-primary border-primary/30"
      }`}
    >
      {isOwnerRole && <Crown className="h-3 w-3" aria-hidden="true" />}
      <span>{label}</span>
      {/* Ronda 2 adversarial: la fecha va SIN `opacity-80`. Medido en vivo:
          la del rol VIGENTE caía a 3,76:1 en tema claro (el token
          `text-primary` mide 5,6:1 a opacidad plena) y la del VENCIDO a
          1,92:1 (0,6 × 0,8 = 0,48 de opacidad efectiva sobre
          `text-muted-foreground`) — las dos por debajo de AA. La jerarquía
          visual la da el tamaño (10px vs. 12px), no la atenuación. */}
      {assignment.expires_at && (
        <span className="text-[10px]" title={assignment.is_active ? "Vence" : "Venció"}>
          {assignment.is_active ? "hasta" : "venció"} {formatDate(assignment.expires_at)}
        </span>
      )}
      {/* Ronda 2 adversarial (finding NIT, corregido): antes el `!isOwnerRole`
          de acá bloqueaba la X para CUALQUIER badge de owner sin importar
          `canRevoke` — la pantalla no tenía NINGÚN camino para ceder/repartir
          la propiedad, pese a que la base sí lo acepta con más de un owner
          activo (vector V15). El caller decide correctamente en `canRevoke`
          (ver MemberRow: `canTransferOwnership` para el rol owner) — este
          badge ya no vuelve a bloquearlo por su cuenta. */}
      {canRevoke && (
        <button
          type="button"
          onClick={onRevoke}
          disabled={isRevoking}
          aria-label={`Revocar el rol ${label}`}
          className="ml-0.5 rounded-full p-0.5 hover:bg-destructive/20 hover:text-destructive focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring"
        >
          <X className="h-2.5 w-2.5" />
        </button>
      )}
    </Badge>
  )
}

// ── Diálogo: asignar rol (con vencimiento opcional) ─────────────────────────

function AssignRoleDialog({
  memberName, assignableRoles, existingRoles, onAssign, isAssigning,
}: {
  memberName: string
  assignableRoles: { code: OrgRole; label: string }[]
  existingRoles: OrgRole[]
  onAssign: (role: OrgRole, expiresAt: string | null) => Promise<void>
  isAssigning: boolean
}) {
  const [open, setOpen] = useState(false)
  const [role, setRole] = useState<OrgRole | "">("")
  const [expiresAt, setExpiresAt] = useState("")

  function handleOpenChange(v: boolean) {
    if (v) {
      setRole("")
      setExpiresAt("")
    }
    setOpen(v)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!role) return
    try {
      await onAssign(role, expiresAt ? localDateEndOfDayISO(expiresAt) : null)
      setOpen(false)
    } catch {
      // El diálogo queda abierto — el toast de error ya lo muestra el caller.
    }
  }

  if (assignableRoles.length === 0) return null

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" className="h-8 gap-1.5 text-xs border-border text-foreground">
          <Plus className="h-3.5 w-3.5" />
          Asignar rol
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Asignar rol a {memberName}</DialogTitle>
          <DialogDescription>
            El rol se suma al conjunto actual — un miembro puede tener varios roles a la vez.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="assign-role-select">Rol</Label>
            <Select value={role} onValueChange={(v) => setRole(v as OrgRole)}>
              <SelectTrigger id="assign-role-select" className="bg-background border-border text-foreground">
                <SelectValue placeholder="Elegí un rol" />
              </SelectTrigger>
              <SelectContent>
                {assignableRoles.map((r) => (
                  <SelectItem key={r.code} value={r.code}>
                    {r.label}
                    {existingRoles.includes(r.code) ? " (ya asignado — renovar)" : ""}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {role !== "owner" && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="assign-role-expires">
                <span className="inline-flex items-center gap-1.5">
                  <CalendarClock className="h-3.5 w-3.5" />
                  Vencimiento (opcional)
                </span>
              </Label>
              <Input
                id="assign-role-expires"
                type="date"
                // Ronda 1 adversarial: sin `min`, el selector aceptaba una
                // fecha pasada y la asignación nacía VENCIDA en silencio (el
                // badge salía directo como "venció …"), sin ningún aviso. El
                // piso es HOY porque `localDateEndOfDayISO` ancla al final del
                // día local: elegir hoy concede lo que queda de la jornada.
                min={new Date().toLocaleDateString("en-CA")}
                value={expiresAt}
                onChange={(e) => setExpiresAt(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Dejalo vacío para un acceso permanente.
              </p>
            </div>
          )}
          {role === "owner" && (
            <p className="text-xs text-muted-foreground">
              El rol de propietario no admite vencimiento.
            </p>
          )}

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => handleOpenChange(false)} disabled={isAssigning}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isAssigning || !role}>
              {isAssigning && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Asignar
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
