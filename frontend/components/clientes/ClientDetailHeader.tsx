"use client"

/**
 * Cabecera + navegación por pestañas del detalle del cliente
 * (client-purchase-history §"Superficie de detalle del cliente con
 * pestañas"). Client Component porque necesita `usePathname()` para resaltar
 * la pestaña activa — el layout (Server Component) sólo resuelve `params` y
 * le pasa `clientId`.
 */

import Link from "next/link"
import { usePathname } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useClient } from "@/hooks/data/use-clients"
import { cn } from "@/lib/utils"

interface ClientDetailHeaderProps {
  clientId: string
}

export function ClientDetailHeader({ clientId }: ClientDetailHeaderProps) {
  const pathname = usePathname()
  const { data: client, isLoading } = useClient(clientId)

  const historialHref = `/clientes/${clientId}`
  const cuentaHref = `/clientes/${clientId}/cuenta`
  const isCuentaActive = pathname === cuentaHref
  const isHistorialActive = !isCuentaActive

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/clientes">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div className="flex-1 min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight truncate">
            {isLoading ? "Cargando…" : client?.name ?? "Cliente"}
          </h1>
          <p className="text-sm text-muted-foreground mt-0.5 truncate">
            {client?.email || client?.phone || "—"}
          </p>
        </div>
      </div>

      {/* Pestañas — enlaces reales (no un widget ARIA tab controlado por JS):
          cada una es enlazable/compartible de forma independiente y el back
          del navegador funciona, tal como pide client-purchase-history
          §"Superficie de detalle del cliente con pestañas". `aria-current`
          marca la activa sin apropiarse del rol semántico de link. */}
      <nav aria-label="Secciones del cliente" className="flex items-center gap-1 border-b border-border">
        <Link
          href={historialHref}
          aria-current={isHistorialActive ? "page" : undefined}
          className={cn(
            "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            isHistorialActive
              ? "border-primary text-foreground"
              : "border-transparent text-muted-foreground hover:text-foreground",
          )}
        >
          Historial de compras
        </Link>
        <Link
          href={cuentaHref}
          aria-current={isCuentaActive ? "page" : undefined}
          className={cn(
            "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            isCuentaActive
              ? "border-primary text-foreground"
              : "border-transparent text-muted-foreground hover:text-foreground",
          )}
        >
          Cuenta corriente
        </Link>
      </nav>
    </div>
  )
}
