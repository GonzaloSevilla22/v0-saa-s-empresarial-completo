"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "./auth-context"
import type { Company, CompanyUser } from "@/lib/types"

interface CompanyContextType {
  company: Company | null
  companyId: string | null
  role: string | null
  loading: boolean
  refreshCompany: () => Promise<void>
}

const CompanyContext = createContext<CompanyContextType | null>(null)

export function CompanyProvider({ children }: { children: React.ReactNode }) {
  const { user, isAuthenticated } = useAuth()
  const [company, setCompany] = useState<Company | null>(null)
  const [role, setRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  const refreshCompany = useCallback(async () => {
    if (!user) {
      setCompany(null)
      setRole(null)
      setLoading(false)
      return
    }

    try {
      setLoading(true)
      // Fetch the primary company for the user
      const { data, error } = await supabase
        .from('company_users')
        .select('role, company:companies(*)')
        .eq('user_id', user.id)
        .limit(1)
        .single()

      if (error) {
        console.error("Error fetching company:", error)
        setCompany(null)
        setRole(null)
      } else if (data) {
        setCompany(data.company as unknown as Company)
        setRole(data.role)
      }
    } catch (e) {
      console.error("Unexpected error in CompanyProvider:", e)
    } finally {
      setLoading(false)
    }
  }, [user, supabase])

  useEffect(() => {
    if (isAuthenticated) {
      refreshCompany()
    } else {
      setCompany(null)
      setRole(null)
      setLoading(false)
    }
  }, [isAuthenticated, refreshCompany])

  return (
    <CompanyContext.Provider
      value={{
        company,
        companyId: company?.id || null,
        role,
        loading,
        refreshCompany
      }}
    >
      {children}
    </CompanyContext.Provider>
  )
}

export function useCompany() {
  const context = useContext(CompanyContext)
  if (!context) {
    throw new Error("useCompany must be used within a CompanyProvider")
  }
  return context
}
