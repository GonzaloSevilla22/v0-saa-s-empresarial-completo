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

      // Step 1: Get the user's role and company_id from the junction table
      const { data: cuData, error: cuError } = await supabase
        .from('company_users')
        .select('role, company_id')
        .eq('user_id', user.id)
        .limit(1)
        .single()

      if (cuError || !cuData) {
        console.error("Error fetching company_user:", cuError)
        setCompany(null)
        setRole(null)
        return
      }

      setRole(cuData.role)

      // Step 2: Fetch the company details separately (avoids PostgREST join ambiguity)
      const { data: companyData, error: companyError } = await supabase
        .from('companies')
        .select('*')
        .eq('id', cuData.company_id)
        .single()

      if (companyError) {
        console.error("Error fetching company:", companyError)
        setCompany(null)
      } else {
        setCompany(companyData as Company)
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
