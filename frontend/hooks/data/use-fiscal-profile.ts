"use client"

/**
 * C-27 v21-fiscal-profile — Hook `useFiscalProfile`.
 *
 * Select + upsert del perfil fiscal de la cuenta activa vía Python backend.
 * Reusa `isValidCuit` (módulo-11, C-22) para validar el CUIT del emisor (OQ-4).
 *
 * Design ref: D1 (1:1 accounts), D2 (ambiente por cuenta), D7 (cert path solo)
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { isValidCuit } from "@/lib/cuit-utils"
import { queryKeys } from "@/lib/query-keys"

// ── Types ────────────────────────────────────────────────────────────────────

export type IvaCondition =
  | "responsable_inscripto"
  | "monotributista"
  | "exento"
  | "consumidor_final"

export type Ambiente = "homologacion" | "produccion"

export interface FiscalProfile {
  id: string
  accountId: string
  cuit: string
  ivaCondition: IvaCondition
  iibbCondition: string | null
  certificadoAfipPath: string | null
  ambiente: Ambiente
  createdAt: string
}

interface FiscalProfileApiRow {
  id: string
  account_id: string
  cuit: string
  iva_condition: IvaCondition
  iibb_condition: string | null
  certificado_afip_path: string | null
  ambiente: Ambiente
  created_at: string
}

interface FiscalProfileInput {
  cuit: string
  iva_condition: IvaCondition
  iibb_condition?: string | null
  ambiente?: Ambiente
  certificado_afip_path?: string | null
}

function mapRow(r: FiscalProfileApiRow): FiscalProfile {
  return {
    id:                  r.id,
    accountId:           r.account_id,
    cuit:                r.cuit,
    ivaCondition:        r.iva_condition,
    iibbCondition:       r.iibb_condition,
    certificadoAfipPath: r.certificado_afip_path,
    ambiente:            r.ambiente,
    createdAt:           r.created_at,
  }
}

function translateFiscalError(message: string): string {
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Especificá cuál usar para emitir."
  if (message.includes("fiscal_profile_not_found"))
    return "La cuenta no tiene perfil fiscal configurado."
  if (message.includes("point_of_sale_not_found_or_inactive"))
    return "El punto de venta no existe o está inactivo."
  if (message.includes("no_active_point_of_sale"))
    return "La cuenta no tiene puntos de venta activos."
  if (message.includes("unauthorized"))
    return "No tenés permisos para realizar esta acción."
  return message || "Ocurrió un error inesperado."
}

// Re-export para uso desde la página
export { isValidCuit, translateFiscalError }

// ── Hooks ────────────────────────────────────────────────────────────────────

/**
 * Lee el perfil fiscal de la cuenta activa.
 * Returns `profile: null` si la cuenta no tiene perfil (404 → null, no error).
 */
export function useFiscalProfile() {
  const query = useQuery({
    queryKey: queryKeys.fiscalProfile.detail(),
    queryFn: async (): Promise<FiscalProfile | null> => {
      try {
        const data = await pythonClient.get<FiscalProfileApiRow>("/fiscal/profile")
        return mapRow(data)
      } catch (err: unknown) {
        // 404 = perfil no configurado aún → retornar null en lugar de error
        const message = err instanceof Error ? err.message : String(err)
        if (message.includes("404") || message.toLowerCase().includes("no encontrado")) {
          return null
        }
        throw err
      }
    },
    staleTime: 5 * 60 * 1000, // 5 min
    retry: (failureCount, error: unknown) => {
      const message = error instanceof Error ? error.message : String(error)
      if (message.includes("404")) return false
      return failureCount < 2
    },
  })

  return {
    profile:   query.data ?? null,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error,
  }
}

/**
 * Upsert del perfil fiscal.
 * Valida el CUIT con módulo-11 (isValidCuit de C-22) antes de enviarlo al backend.
 */
export function useUpsertFiscalProfile() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (input: FiscalProfileInput): Promise<FiscalProfile> => {
      // OQ-4: validar CUIT del emisor con módulo-11 (reusar isValidCuit de C-22)
      if (!isValidCuit(input.cuit)) {
        throw new Error("CUIT inválido: verificá el formato y el dígito verificador (módulo 11).")
      }
      const data = await pythonClient.post<FiscalProfileApiRow>("/fiscal/profile", input)
      return mapRow(data)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.fiscalProfile.all() })
    },
    onError: (err: unknown) => {
      const message = err instanceof Error ? err.message : String(err)
      throw new Error(translateFiscalError(message))
    },
  })
}
