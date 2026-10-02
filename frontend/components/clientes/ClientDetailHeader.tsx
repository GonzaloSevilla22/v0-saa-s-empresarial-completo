"use client"

/**
 * Cabecera + navegación por pestañas del detalle del cliente
 * (client-purchase-history §"Superficie de detalle del cliente con
 * pestañas"). Client Component porque necesita `usePathname()` para resaltar
 * la pestaña activa — el layout (Server Component) sólo resuelve `params` y
 * le pasa `clientId`.
 *
 * presupuestos-modulo (D10, OQ-P7): suma la pestaña "Presupuestos" y el botón
 * "Nuevo presupuesto" (visible en todas las pestañas, sólo con `CAN_QUOTE`). Con
 * tres pestañas la activa se decide comparando la RUTA de cada una: la regla
 * anterior (`historial = !cuenta`) habría marcado "Historial" también sobre
 * "Presupuestos".
 */

import Link from "next/link"
import { usePathname } from "next/navigation"
import { ArrowLeft, Plus } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useClient } from "@/hooks/data/use-clients"
import { useOrgRole } from "@/hooks/useOrgRole"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"
import { cn } from "@/lib/utils"

interface ClientDetailHeaderProps {
  clientId: string
}

export function ClientDetailHeader({ clientId }: ClientDetailHeaderProps) {
  const pathname = usePathname()
  const { data: client, isLoading } = useClient(clientId)
  const { roles, rolesResolved } = useOrgRole()
  const canQuote = hasCapability(roles, CAN_QUOTE, rolesResolved)

  const tabs = [
    { label: "Historial de compras", href: `/clientes/${clientId}` },
    { label: "Cuenta corriente", href: `/clientes/${clientId}/cuenta` },
    { label: "Presupuestos", href: `/clientes/${clientId}/presupuestos` },
  ]

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/clientes" aria-label="Volver a clientes">
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
        {canQuote && (
          <Button asChild size="sm" className="shrink-0 gap-1.5">
            <Link
              href={`/presupuestos/nuevo?cliente=${encodeURIComponent(clientId)}`}
              aria-label="Nuevo presupuesto"
            >
              <Plus className="h-4 w-4" aria-hidden="true" />
              <span className="hidden sm:inline" aria-hidden="true">Nuevo presupuesto</span>
            </Link>
          </Button>
        )}
      </div>

      {/* Pestañas — enlaces reales (no un widget ARIA tab controlado por JS):
          cada una es enlazable/compartible de forma independiente y el back
          del navegador funciona, tal como pide client-purchase-history
          §"Superficie de detalle del cliente con pestañas". `aria-current`
          marca la activa sin apropiarse del rol semántico de link. */}
      <nav aria-label="Secciones del cliente" className="flex items-center gap-1 overflow-x-auto border-b border-border">
        {tabs.map((tab) => {
          const active = pathname === tab.href
          return (
            <Link
              key={tab.href}
              href={tab.href}
              aria-current={active ? "page" : undefined}
              className={cn(
                "px-3 py-2 text-sm font-medium whitespace-nowrap border-b-2 -mb-px transition-colors",
                active
                  ? "border-primary text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground",
              )}
            >
              {tab.label}
            </Link>
          )
        })}
      </nav>
    </div>
  )
}
