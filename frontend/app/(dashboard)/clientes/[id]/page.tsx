/**
 * Detalle del cliente — pestaña "Historial de compras"
 * (client-purchase-history §"Historial de compras del cliente"). Server
 * Component: resuelve `params` y delega el fetch/estado a
 * ClientDetailContent (Client Component, vía useClientPurchases).
 */
import { ClientDetailContent } from "@/components/clientes/ClientDetailContent"

interface ClienteDetailPageProps {
  params: Promise<{ id: string }>
}

export default async function ClienteDetailPage({ params }: ClienteDetailPageProps) {
  const { id } = await params

  return <ClientDetailContent clientId={id} />
}
