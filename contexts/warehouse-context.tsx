"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { createClient } from "@/lib/supabase/client"
import { useCompany } from "./company-context"
import type { Warehouse } from "@/lib/types"

interface WarehouseContextType {
  warehouses: Warehouse[]
  activeWarehouse: Warehouse | null
  activeWarehouseId: string | null
  loading: boolean
  setActiveWarehouse: (warehouse: Warehouse | null) => void
  refreshWarehouses: () => Promise<void>
}

const WarehouseContext = createContext<WarehouseContextType | null>(null)

export function WarehouseProvider({ children }: { children: React.ReactNode }) {
  const { companyId } = useCompany()
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [activeWarehouse, setActiveWarehouseState] = useState<Warehouse | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  const refreshWarehouses = useCallback(async () => {
    if (!companyId) {
      setWarehouses([])
      setActiveWarehouseState(null)
      setLoading(false)
      return
    }

    try {
      setLoading(true)
      const { data, error } = await supabase
        .from('warehouses')
        .select('*')
        .eq('company_id', companyId)
        .order('name')

      if (error) {
        console.error("Error fetching warehouses:", error)
        setWarehouses([])
      } else if (data) {
        setWarehouses(data as Warehouse[])
        
        // Restore from localStorage or pick the first one
        const savedId = localStorage.getItem(`active_warehouse_${companyId}`)
        const found = data.find(w => w.id === savedId)
        setActiveWarehouseState(found || data[0] || null)
      }
    } catch (e) {
      console.error("Unexpected error in WarehouseProvider:", e)
    } finally {
      setLoading(false)
    }
  }, [companyId, supabase])

  useEffect(() => {
    refreshWarehouses()
  }, [refreshWarehouses])

  const setActiveWarehouse = (warehouse: Warehouse | null) => {
    setActiveWarehouseState(warehouse)
    if (warehouse && companyId) {
      localStorage.setItem(`active_warehouse_${companyId}`, warehouse.id)
    }
  }

  return (
    <WarehouseContext.Provider
      value={{
        warehouses,
        activeWarehouse,
        activeWarehouseId: activeWarehouse?.id || null,
        loading,
        setActiveWarehouse,
        refreshWarehouses
      }}
    >
      {children}
    </WarehouseContext.Provider>
  )
}

export function useWarehouse() {
  const context = useContext(WarehouseContext)
  if (!context) {
    throw new Error("useWarehouse must be used within a WarehouseProvider")
  }
  return context
}
