"use client"

/**
 * remitos-venta (D11) — direcciones operativas de un cliente.
 *
 * `GET /clients/{id}/addresses` existe en el backend desde `v3-catalog-masters`
 * (V3 §7.3) pero el frontend no tenía ningún hook ni cliente API: sólo el tipo
 * `ClientAddress` de `lib/types.ts`. Nace acá, de sólo lectura, porque el
 * domicilio de entrega del remito se precarga con la dirección principal del
 * cliente (`lib/client-address.ts`).
 *
 * Mismo patrón que el resto de los hooks de datos del backend Python:
 * `pythonClient` + mapper snake_case → camelCase en el borde de lectura.
 */

import { useQuery } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { ClientAddress } from "@/lib/types"

interface ClientAddressApiRow {
  id: string
  account_id: string
  client_id: string
  alias: string | null
  street: string | null
  city: string | null
  province: string | null
  postal_code: string | null
  notes: string | null
  is_primary: boolean
  created_at: string
  updated_at: string | null
}

function mapClientAddress(row: ClientAddressApiRow): ClientAddress {
  return {
    id: row.id,
    accountId: row.account_id,
    clientId: row.client_id,
    alias: row.alias,
    street: row.street,
    city: row.city,
    province: row.province,
    postalCode: row.postal_code,
    notes: row.notes,
    isPrimary: row.is_primary,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

/**
 * Direcciones del cliente (la principal primero la decide quien las usa, con
 * `primaryDeliveryAddress`). Sin cliente elegido no consulta nada.
 */
export function useClientAddresses(clientId: string | null) {
  return useQuery({
    queryKey: queryKeys.clients.addresses(clientId ?? ""),
    queryFn: async (): Promise<ClientAddress[]> => {
      const rows = await pythonClient.get<ClientAddressApiRow[]>(
        `/clients/${encodeURIComponent(clientId as string)}/addresses`,
      )
      return rows.map(mapClientAddress)
    },
    enabled: !!clientId,
    staleTime: 60 * 1000,
  })
}
