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

function mapClient(c: ClientApiRow): Client {
  return {
    id:           c.id,
    name:         c.name,
    email:        c.email        || "",
    phone:        c.phone        || "",
    status:       "activo",
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
