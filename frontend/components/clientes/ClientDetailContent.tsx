"use client"

/**
 * Contenido de la pestaña "Historial de compras" del detalle del cliente —
 * compone ClientSummaryCards + ClientPurchaseHistory sobre useClientPurchases.
 * Client Component: el layout (Server Component) sólo resuelve `params`.
 */

import { useClientPurchases } from "@/hooks/data/use-client-activity"
import { ClientSummaryCards } from "@/components/clientes/ClientSummaryCards"
import { ClientPurchaseHistory } from "@/components/clientes/ClientPurchaseHistory"

interface ClientDetailContentProps {
  clientId: string
}

export function ClientDetailContent({ clientId }: ClientDetailContentProps) {
  const {
    purchases, summary, meta, isLoading, error, setPage, setPageSize,
  } = useClientPurchases(clientId)

  return (
    <div className="flex flex-col gap-6">
      <ClientSummaryCards clientId={clientId} summary={summary} isLoading={isLoading} />

      <ClientPurchaseHistory
        purchases={purchases}
        meta={meta}
        isLoading={isLoading}
        error={error}
        onPageChange={setPage}
        onSizeChange={setPageSize}
      />
    </div>
  )
}
