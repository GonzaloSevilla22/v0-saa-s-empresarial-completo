"use client"

import { useQuery } from "@tanstack/react-query"
import { queryKeys } from "@/lib/query-keys"
import { fetchOperationEdits, type EditableDocumentKind } from "@/lib/operation-edit-api"

/**
 * edicion-operaciones-con-dinero (tanda C, 14.2) — el historial de ediciones de una venta, una compra o un gasto
 * (`audit_logs`, D14), más reciente primero. Carga DIFERIDA: con `enabled = false` no consulta nada; el detalle expandido
 * lo enciende cuando el usuario abre el historial.
 */
export function useOperationEditHistory(kind: EditableDocumentKind, entityId: string | null | undefined, enabled: boolean) {
  return useQuery({
    queryKey: queryKeys.operationEdits.detail(kind, entityId ?? ""),
    queryFn: () => fetchOperationEdits(kind, entityId as string),
    enabled: enabled && !!entityId,
    staleTime: 30 * 1000,
  })
}
