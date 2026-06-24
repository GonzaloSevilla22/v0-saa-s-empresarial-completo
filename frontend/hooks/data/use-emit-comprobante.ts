"use client"

/**
 * v22-afip-delegation-billing — useEmitComprobante
 *
 * Mutation hook para POST /fiscal/documents/emit.
 * Crea un comprobante fiscal en estado pending_cae y dispara el relay async
 * que obtiene el CAE de ARCA.
 *
 * Design ref: OQ-3 (endpoint de emisión directa), D6 (relay idempotente),
 * D11 (PV resolver), v22 (delegación → plataforma cert).
 *
 * Reglas duras:
 *   - NUNCA usar `any`
 *   - NUNCA emitir automáticamente — caller debe invocar explícitamente
 *   - translateFiscalError traduce DELEGATION_NOT_AUTHORIZED con mensaje
 *     accionable + link a /configuracion/fiscal
 */

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── Types ─────────────────────────────────────────────────────────────────────

export type ComprobanteType = "factura_a" | "factura_b" | "factura_c"

export interface EmitComprobanteInput {
  comprobante_type: ComprobanteType
  total: number
  client_id?: string | null
  point_of_sale_id?: string | null
}

export interface EmitComprobanteResult {
  id: string
  status: "pending_cae" | "authorized" | "rejected"
  comprobante_type: ComprobanteType
  total: number | string
  cae?: string | null
  cae_due_date?: string | null
  error_code?: string | null
  error_detail?: string | null
}

// ── Error translation ─────────────────────────────────────────────────────────

export function translateEmitError(message: string): string {
  if (
    message.includes("DELEGATION_NOT_AUTHORIZED") ||
    message.includes("Administrador de Relaciones") ||
    message.includes("representante") ||
    message.includes("aún no autorizó")
  ) {
    return "DELEGATION_NOT_AUTHORIZED: Aliadata aún no está autorizado como representante en tu cuenta ARCA. Configurá la delegación en Ajustes → Datos fiscales."
  }
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Seleccioná cuál usar."
  if (message.includes("no_active_point_of_sale"))
    return "La cuenta no tiene puntos de venta activos. Configurá uno en Datos fiscales."
  if (message.includes("fiscal_profile_not_found"))
    return "La cuenta no tiene perfil fiscal configurado. Completá los datos en Ajustes → Datos fiscales."
  if (message.includes("point_of_sale_not_found_or_inactive"))
    return "El punto de venta seleccionado no existe o está inactivo."
  return message || "Ocurrió un error inesperado al emitir el comprobante."
}

/** Returns true when the error is the delegation-not-authorized sentinel. */
export function isDelegationError(message: string): boolean {
  return message.startsWith("DELEGATION_NOT_AUTHORIZED:")
}

// ── Hook ──────────────────────────────────────────────────────────────────────

/**
 * Emite un comprobante fiscal ante ARCA/AFIP (POST /fiscal/documents/emit).
 * El backend persiste en pending_cae y dispara el relay async de inmediato.
 * El FiscalDocumentBadge suscripto por Realtime actualizará el estado cuando
 * el CAE llegue.
 */
export function useEmitComprobante() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (
      input: EmitComprobanteInput,
    ): Promise<EmitComprobanteResult> => {
      try {
        return await pythonClient.post<EmitComprobanteResult>(
          "/fiscal/documents/emit",
          input,
        )
      } catch (err: unknown) {
        throw new Error(translateEmitError((err as Error).message ?? ""))
      }
    },
    onSuccess: () => {
      // Invalidate fiscal documents list so any future badge list refreshes
      queryClient.invalidateQueries({ queryKey: queryKeys.fiscalDocuments.all() })
    },
  })
}
