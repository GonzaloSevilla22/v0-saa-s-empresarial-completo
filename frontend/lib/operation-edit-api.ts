/**
 * edicion-operaciones-con-dinero (tanda C, D13/D14) — los dos endpoints que la edición con dinero agrega a cada documento:
 * la VISTA PREVIA del plan (`POST .../edit-preview`, la misma RPC que la edición real pero en seco) y el HISTORIAL de cambios
 * (`GET .../edits`). Las rutas difieren por documento (la venta y la compra se identifican por `operation_id`, el gasto por
 * su id), así que viven acá, en una sola definición que consumen los hooks de cada dominio y el historial.
 */

import { pythonClient } from "@/lib/api/python-client"
import type { EditPreview, MoneyPlan, VoidedFiscalDocument } from "@/lib/money-plan"

export type EditableDocumentKind = "sale" | "purchase" | "expense"

/** Una entrada del historial de ediciones (`OperationEditOut`). */
export interface OperationEditEntry {
  id: string
  created_at: string
  user_id: string | null
  user_name: string | null
  action: string
  entity_type: string | null
  entity_id: string | null
  before: Record<string, unknown> | null
  after: Record<string, unknown> | null
  money: MoneyPlan | null
  voided_fiscal_document: VoidedFiscalDocument | null
  reason: string | null
}

export function operationEditsPath(kind: EditableDocumentKind, entityId: string): string {
  switch (kind) {
    case "sale":
      return `/sales/operation/${entityId}/edits`
    case "purchase":
      return `/purchases/operation/${entityId}/edits`
    case "expense":
      return `/expenses/${entityId}/edits`
  }
}

export function editPreviewPath(kind: EditableDocumentKind, entityId?: string): string {
  switch (kind) {
    case "sale":
      return "/sales/operation/edit-preview"
    case "purchase":
      return "/purchases/operation/edit-preview"
    case "expense":
      return `/expenses/${entityId}/edit-preview`
  }
}

/** Pide al servidor el plan de la edición con el MISMO payload que el PUT. No escribe nada. */
export function fetchEditPreview(
  kind: EditableDocumentKind,
  payload: Record<string, unknown>,
  entityId?: string,
): Promise<EditPreview> {
  return pythonClient.post<EditPreview>(editPreviewPath(kind, entityId), payload)
}

export function fetchOperationEdits(kind: EditableDocumentKind, entityId: string): Promise<OperationEditEntry[]> {
  return pythonClient.get<OperationEditEntry[]>(operationEditsPath(kind, entityId))
}
