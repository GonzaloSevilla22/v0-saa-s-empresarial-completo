"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Client, IvaCondition } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface ClientApiRow {
  id: string
  account_id: string
  user_id?: string
  name: string
  email: string | null
  phone: string | null
  tax_id?: string | null
  iva_condition?: IvaCondition | null
  legal_name?: string | null
  created_at: string
}

// deudas-menores-agosto (G2): `status` legacy dejó de mapearse — el backend
// Python ya no lo persiste y la UI ya no lo lee ni lo edita.
function mapClient(c: ClientApiRow): Client {
  return {
    id:           c.id,
    name:         c.name,
    email:        c.email        || "",
    phone:        c.phone        || "",
    lastPurchase: "-",
    totalSpent:   0,
    category:     undefined,
    taxId:        c.tax_id       || undefined,
    ivaCondition: c.iva_condition || undefined,
    legalName:    c.legal_name   || undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * clientes-frecuentes-historial — fetch de un único cliente por id
 * (`GET /clients/{id}`, endpoint ya existente). Usado por el layout de
 * `/clientes/[id]` para la cabecera (design.md §6).
 */
export function useClient(clientId: string | null) {
  return useQuery({
    queryKey: [...queryKeys.clients.all(), "detail", clientId ?? ""],
    queryFn: async (): Promise<Client> => {
      const data = await pythonClient.get<ClientApiRow>(`/clients/${clientId}`)
      return mapClient(data)
    },
    enabled: !!clientId,
    staleTime: 60 * 1000,
  })
}

/**
 * Returns clients list + mutations (add, update, delete) via Python API.
 */
export function useClients() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.clients.lists(),
    queryFn: async (): Promise<Client[]> => {
      const data = await pythonClient.get<ClientApiRow[]>("/clients")
      return data.map(mapClient)
    },
    staleTime: 2 * 60 * 1000, // 2 min
  })

  const addClientMutation = useMutation({
    mutationFn: async (client: Omit<Client, "id">) => {
      return pythonClient.post<ClientApiRow>("/clients", {
        name:          client.name,
        email:         client.email        || null,
        phone:         client.phone        || null,
        tax_id:        client.taxId        || null,
        iva_condition: client.ivaCondition || null,
        legal_name:    client.legalName    || null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.clients.all() })
    },
  })

  const updateClientMutation = useMutation({
    mutationFn: async (client: Client) => {
      return pythonClient.put<ClientApiRow>(`/clients/${client.id}`, {
        name:          client.name,
        email:         client.email        || null,
        phone:         client.phone        || null,
        tax_id:        client.taxId        || null,
        iva_condition: client.ivaCondition || null,
        legal_name:    client.legalName    || null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.clients.all() })
    },
  })

  const deleteClientMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/clients/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.clients.all() })
    },
  })

  return {
    clients:      query.data ?? [],
    isLoading:    query.isLoading,
    isError:      query.isError,
    error:        query.error,
    addClient:    addClientMutation.mutateAsync,
    updateClient: updateClientMutation.mutateAsync,
    deleteClient: deleteClientMutation.mutateAsync,
    addClientMutation,
    updateClientMutation,
    deleteClientMutation,
  }
}
