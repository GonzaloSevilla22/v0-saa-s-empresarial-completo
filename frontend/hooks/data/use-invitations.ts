"use client"

/**
 * multiusuario-operativo tanda C (grupo 17) — la invitación de punta a punta, vía FastAPI.
 *
 *   /members/invitations      crear, listar, reenviar y revocar (dueño o administrador de la cuenta activa)
 *   /invitations/{token}      vista previa y aceptación del invitado
 *
 * Por qué FastAPI y no supabase-js: el `P0404` y el `P0409` de la aceptación tienen que llegar
 * como 404 y 409 y no como un 500 de PostgREST (dato medido por v3-rbac-multirole), y crear +
 * enviar quedan en la misma transacción del request (un tope de envío revierte la creación).
 *
 * Reutiliza `pythonClient` (único sitio que arma encabezados: Bearer + `X-Account-Id`) y la caché
 * de React Query; el token NUNCA viaja por la caché del listado (el backend no lo devuelve).
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { OrgRole } from "@/lib/types"

/** Estado derivado en la base: `pending` vigente, `expired` (venció sin aceptarse) o `revoked`. */
export type InvitationState = "pending" | "expired" | "revoked"

/** Una fila del listado de pendientes. NO trae el token. */
export interface InvitationRow {
  id: string
  email: string
  roles: OrgRole[]
  role_labels: string[]
  state: InvitationState
  created_at: string
  expires_at: string
  invited_by: string | null
  invited_by_name: string | null
  last_sent_at: string | null
  send_count: number
}

/** Respuesta de crear o reenviar: lo único que lleva el token es esto (para «Copiar link»). */
export interface InvitationSent {
  id: string
  email: string
  roles: OrgRole[]
  expires_at: string
  token: string
  email_queued: boolean
}

export interface InvitationPreview {
  account_id: string
  account_display_name: string
  inviter_name: string
  roles: OrgRole[]
  role_labels: string[]
  expires_at: string
  already_member: boolean
}

export interface InvitationAccepted {
  account_member_id: string
  account_id: string
  active_account_id: string
  role: string
  roles: OrgRole[]
}

// ── Gestión (dueño o administrador) ──────────────────────────────────────────

export function useInvitations(accountId: string | null, enabled = true) {
  return useQuery({
    queryKey: queryKeys.invitations.list(accountId),
    queryFn: () => pythonClient.get<InvitationRow[]>("/members/invitations"),
    enabled: !!accountId && enabled,
    staleTime: 15_000,
  })
}

/** Qué se refresca cuando cambia el estado de las invitaciones o del equipo. */
function useInvalidateInvitations(accountId: string | null) {
  const queryClient = useQueryClient()
  return () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.invitations.list(accountId) })
    queryClient.invalidateQueries({ queryKey: ["teamMembers", accountId] })
    queryClient.invalidateQueries({ queryKey: queryKeys.members.list(accountId) })
  }
}

export function useInviteMember(accountId: string | null) {
  const invalidate = useInvalidateInvitations(accountId)
  return useMutation({
    mutationFn: ({ email, roles }: { email: string; roles: OrgRole[] }) =>
      pythonClient.post<InvitationSent>("/members/invitations", { email, roles }),
    onSuccess: invalidate,
  })
}

export function useResendInvitation(accountId: string | null) {
  const invalidate = useInvalidateInvitations(accountId)
  return useMutation({
    mutationFn: (invitationId: string) =>
      pythonClient.post<InvitationSent>(`/members/invitations/${invitationId}/resend`, {}),
    onSuccess: invalidate,
  })
}

export function useRevokeInvitation(accountId: string | null) {
  const invalidate = useInvalidateInvitations(accountId)
  return useMutation({
    mutationFn: (invitationId: string) =>
      pythonClient.delete<{ id: string; status: string }>(`/members/invitations/${invitationId}`),
    onSuccess: invalidate,
  })
}

// ── El invitado ──────────────────────────────────────────────────────────────

/**
 * La vista previa, ligada a la identidad autenticada (la valida la base). Sin reintentos: un 404
 * ("no disponible") no se arregla reintentando y cada intento es una consulta más con un token.
 */
export function useInvitationPreview(token: string, enabled: boolean) {
  return useQuery({
    queryKey: queryKeys.invitations.preview(token),
    queryFn: () => pythonClient.get<InvitationPreview>(`/invitations/${encodeURIComponent(token)}`),
    enabled,
    retry: false,
    staleTime: 0,
    gcTime: 0,
  })
}

export function useAcceptInvitation(token: string) {
  return useMutation({
    mutationFn: () => pythonClient.post<InvitationAccepted>(`/invitations/${encodeURIComponent(token)}/accept`, {}),
  })
}
