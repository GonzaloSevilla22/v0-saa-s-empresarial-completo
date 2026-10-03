/**
 * presupuestos-modulo — estados de pantalla compartidos por las páginas del
 * presupuesto (alta, edición y detalle): cargando, error de carga y falta de
 * permiso. Una sola redacción para los tres, con las regiones ARIA correctas
 * (`status` para lo informativo, `alert` para el error).
 *
 * remitos-venta (D11, tarea 4.9): la implementación vive ahora en
 * `components/shared/DocumentPageStates.tsx`, parametrizada por documento; estos
 * tres nombres se conservan (los usan las páginas del presupuesto) y muestran
 * exactamente lo mismo que antes.
 */
import {
  DocumentLoadError,
  DocumentLoading,
  DocumentNoPermission,
  type DocumentPageTexts,
} from "@/components/shared/DocumentPageStates"

const QUOTE_TEXTS: DocumentPageTexts = {
  singular: "presupuesto",
  loadingLabel: "Cargando presupuesto…",
  backHref: "/presupuestos",
  backLabel: "Volver a presupuestos",
  permissionHint: "Pedile a un administrador del negocio que te habilite como vendedor.",
}

export function QuoteLoading({ label = QUOTE_TEXTS.loadingLabel }: { label?: string }) {
  return <DocumentLoading label={label} />
}

export function QuoteLoadError() {
  return <DocumentLoadError texts={QUOTE_TEXTS} />
}

export function QuoteNoPermission({ action }: { action: string }) {
  return <DocumentNoPermission texts={QUOTE_TEXTS} action={action} />
}
