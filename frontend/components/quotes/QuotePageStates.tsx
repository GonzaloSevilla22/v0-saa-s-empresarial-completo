/**
 * presupuestos-modulo — estados de pantalla compartidos por las páginas del
 * presupuesto (alta, edición y detalle): cargando, error de carga y falta de
 * permiso. Una sola redacción para los tres, con las regiones ARIA correctas
 * (`status` para lo informativo, `alert` para el error).
 */
import Link from "next/link"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"

export function QuoteLoading({ label = "Cargando presupuesto…" }: { label?: string }) {
  return (
    <p className="px-4 py-10 text-center text-sm text-muted-foreground" role="status">
      {label}
    </p>
  )
}

export function QuoteLoadError() {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p role="alert" className="text-sm text-destructive">
        No se pudo cargar el presupuesto. Puede que no exista o que sea de otra cuenta.
      </p>
      <Button asChild variant="outline" size="sm" className="gap-2">
        <Link href="/presupuestos">
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          Volver a presupuestos
        </Link>
      </Button>
    </div>
  )
}

export function QuoteNoPermission({ action }: { action: string }) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p role="status" className="max-w-md text-sm text-muted-foreground">
        Tu rol no permite {action}. Pedile a un administrador del negocio que te habilite como vendedor.
      </p>
      <Button asChild variant="outline" size="sm" className="gap-2">
        <Link href="/presupuestos">
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          Volver a presupuestos
        </Link>
      </Button>
    </div>
  )
}
