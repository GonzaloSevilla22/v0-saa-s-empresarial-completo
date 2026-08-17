/**
 * Layout compartido del detalle del cliente — cabecera + pestañas
 * (client-purchase-history §"Superficie de detalle del cliente con
 * pestañas"). Server Component: resuelve `params` (Next.js 15+ los entrega
 * como Promise) y delega la parte interactiva (usePathname, fetch del
 * nombre) a `ClientDetailHeader` (Client Component).
 */
import type { ReactNode } from "react"
import { ClientDetailHeader } from "@/components/clientes/ClientDetailHeader"

interface ClienteDetailLayoutProps {
  params:   Promise<{ id: string }>
  children: ReactNode
}

export default async function ClienteDetailLayout({ params, children }: ClienteDetailLayoutProps) {
  const { id } = await params

  return (
    <div className="flex flex-col gap-6">
      <ClientDetailHeader clientId={id} />
      {children}
    </div>
  )
}
