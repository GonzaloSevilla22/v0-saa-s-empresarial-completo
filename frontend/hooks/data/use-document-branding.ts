"use client"

/**
 * documentos-marca-empresa (D8/D10) — hooks de la marca de la cuenta para sus papeles.
 *
 *   useDocumentBranding        lee `GET /document-branding` (cualquier miembro). Una
 *                              respuesta inválida —base sin la migración, backend viejo—
 *                              cae a los valores por defecto (Neutro, sin logo): la
 *                              pantalla y los papeles nunca se rompen por esto.
 *   useUpdateDocumentBranding  guarda datos y paleta (owner/admin). Invalida también los
 *                              presupuestos y remitos: su `issuer_name` sigue la cascada.
 *   useUploadDocumentLogo      sube el logo (cuerpo binario; el servidor lo normaliza).
 *   useDeleteDocumentLogo      quita el logo.
 *   useDocumentLogoDataUri     el logo como `data:` URI para el HTML imprimible; sólo si hay
 *                              huella, cacheado por huella (un logo nuevo es otra clave).
 *
 * `documentBrandingQueryOptions` / `documentLogoQueryOptions` se exportan para que el menú
 * "Comprobante" PRECARGUE la marca antes del clic (el gesto del usuario no puede esperar un
 * fetch si se quiere abrir la pestaña de impresión).
 */

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentLogoDataUri, uploadDocumentLogo } from "@/lib/api/document-logo"
import {
  DEFAULT_DOCUMENT_BRANDING,
  parseDocumentBranding,
  type BrandingPayload,
  type DocumentBranding,
} from "@/lib/document-branding"
import { queryKeys } from "@/lib/query-keys"

const FIVE_MINUTES = 5 * 60 * 1000

export function documentBrandingQueryOptions() {
  return queryOptions({
    queryKey: queryKeys.documentBranding.detail(),
    queryFn: async (): Promise<DocumentBranding> => {
      const data = await pythonClient.get<unknown>("/document-branding")
      return parseDocumentBranding(data)
    },
    staleTime: FIVE_MINUTES,
  })
}

export function documentLogoQueryOptions(sha256: string) {
  return queryOptions({
    queryKey: queryKeys.documentBranding.logo(sha256),
    queryFn: async (): Promise<string | null> => fetchDocumentLogoDataUri(sha256),
    // La clave incluye la huella: el contenido de esa clave no cambia nunca.
    staleTime: Infinity,
  })
}

export function useDocumentBranding() {
  const query = useQuery(documentBrandingQueryOptions())
  return {
    branding: query.data ?? DEFAULT_DOCUMENT_BRANDING,
    isLoading: query.isLoading,
    isError: query.isError,
    error: query.error,
    refetch: query.refetch,
  }
}

/** Refresca la marca y todo lo que muestra datos derivados de ella (`issuer_name` de los
 *  presupuestos y remitos sigue la cascada). */
function useInvalidateBranding() {
  const queryClient = useQueryClient()
  return () => {
    queryClient.invalidateQueries({ queryKey: queryKeys.documentBranding.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
    queryClient.invalidateQueries({ queryKey: queryKeys.deliveryNotes.all() })
  }
}

/** Guarda los datos y la paleta (sólo owner/admin — 403 si no). El logo no se toca. */
export function useUpdateDocumentBranding() {
  const invalidate = useInvalidateBranding()
  return useMutation({
    mutationFn: async (payload: BrandingPayload): Promise<DocumentBranding> => {
      const data = await pythonClient.put<unknown>("/document-branding", payload)
      return parseDocumentBranding(data)
    },
    onSuccess: invalidate,
  })
}

/** Sube el logo (sólo owner/admin). Si la sesión venció (`null`), ya se navegó al login. */
export function useUploadDocumentLogo() {
  const invalidate = useInvalidateBranding()
  return useMutation({
    mutationFn: (file: File) => uploadDocumentLogo(file),
    onSuccess: (logo) => {
      if (logo) invalidate()
    },
  })
}

/** Quita el logo (sólo owner/admin). Idempotente. */
export function useDeleteDocumentLogo() {
  const invalidate = useInvalidateBranding()
  return useMutation({
    mutationFn: async (): Promise<void> => {
      await pythonClient.delete<void>("/document-branding/logo")
    },
    onSuccess: invalidate,
  })
}

/** El logo como `data:` URI (sólo si la cuenta tiene uno: `sha256` es su huella). */
export function useDocumentLogoDataUri(sha256: string | null | undefined) {
  const query = useQuery({
    ...documentLogoQueryOptions(sha256 ?? ""),
    enabled: Boolean(sha256),
  })
  return { dataUri: query.data ?? undefined, isLoading: query.isLoading }
}
