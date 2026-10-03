/**
 * remitos-venta (D11) — estados de pantalla compartidos por las páginas de un
 * documento comercial (alta, edición y detalle): cargando, error de carga o no
 * encontrado, falta de permiso y no editable. Una sola redacción, con los textos
 * parametrizados por documento, y las regiones ARIA correctas (`status` para lo
 * informativo, `alert` para el error).
 *
 * Es `components/quotes/QuotePageStates.tsx` generalizado: el presupuesto pasa a
 * usarlo sin cambiar lo que muestra y el remito lo usa con su redacción.
 */
import type { ReactNode } from "react"
import Link from "next/link"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"

/** Lo que cambia de un documento a otro. */
export interface DocumentPageTexts {
  /** Nombre del documento, en singular y minúscula: "presupuesto", "remito". */
  singular: string
  /** Texto de la región de carga: "Cargando remito…". */
  loadingLabel: string
  /** Listado del documento: a donde vuelven los enlaces. */
  backHref: string
  /** "Volver a remitos". */
  backLabel: string
  /** Cómo se habilita el permiso: "Pedile a un administrador del negocio que …". */
  permissionHint: string
}

function BackLink({ texts }: { texts: DocumentPageTexts }) {
  return (
    <Button asChild variant="outline" size="sm" className="gap-2">
      <Link href={texts.backHref}>
        <ArrowLeft className="h-4 w-4" aria-hidden="true" />
        {texts.backLabel}
      </Link>
    </Button>
  )
}

export function DocumentLoading({ label }: { label: string }) {
  return (
    <p className="px-4 py-10 text-center text-sm text-muted-foreground" role="status">
      {label}
    </p>
  )
}

export function DocumentLoadError({ texts }: { texts: DocumentPageTexts }) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p role="alert" className="text-sm text-destructive">
        No se pudo cargar el {texts.singular}. Puede que no exista o que sea de otra cuenta.
      </p>
      <BackLink texts={texts} />
    </div>
  )
}

export function DocumentNoPermission({ texts, action }: { texts: DocumentPageTexts; action: string }) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p role="status" className="max-w-md text-sm text-muted-foreground">
        Tu rol no permite {action}. {texts.permissionHint}
      </p>
      <BackLink texts={texts} />
    </div>
  )
}

/**
 * El documento existe pero ya no se puede editar (convertido: enlace a la venta
 * y cómo corregirlo; anulado: el motivo como `children`).
 */
export function DocumentNotEditable({
  texts,
  message,
  link,
  children,
}: {
  texts: DocumentPageTexts
  message: string
  /** Enlace al documento que lo reemplazó (la venta de un remito convertido). */
  link?: { href: string; label: string }
  children?: ReactNode
}) {
  return (
    <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
      <p role="status" className="max-w-md text-sm text-muted-foreground">
        {message}
      </p>
      {children}
      <div className="flex flex-wrap items-center justify-center gap-2">
        {link && (
          <Button asChild size="sm">
            <Link href={link.href}>{link.label}</Link>
          </Button>
        )}
        <BackLink texts={texts} />
      </div>
    </div>
  )
}
