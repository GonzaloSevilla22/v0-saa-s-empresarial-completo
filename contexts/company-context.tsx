"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "./auth-context"
import type { Company } from "@/lib/types"

interface CreateCompanyResult {
  success: boolean
  error?: string
}

interface CompanyContextType {
  company: Company | null
  companyId: string | null
  role: string | null
  loading: boolean
  hasCompany: boolean
  refreshCompany: () => Promise<void>
  createCompany: (name: string) => Promise<CreateCompanyResult>
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
        // PGRST116 = no rows found (user has no company yet)
        setCompany(null)
        setRole(null)
        return
      }

      setRole(cuData.role)

      // Step 2: Fetch the company details separately
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

  const createCompany = useCallback(async (name: string): Promise<CreateCompanyResult> => {
    if (!user) return { success: false, error: "Usuario no autenticado" }

    try {
      // 1. Create the company
      const { data: newCompany, error: companyErr } = await supabase
        .from('companies')
        .insert({ name: name.trim() })
        .select()
        .single()

      if (companyErr || !newCompany) {
        return { success: false, error: companyErr?.message || "Error al crear la empresa" }
      }

      const companyId = newCompany.id

      // 2. Create company_user link with admin role
      const { error: cuErr } = await supabase
        .from('company_users')
        .insert({ company_id: companyId, user_id: user.id, role: 'admin' })

      if (cuErr) {
        return { success: false, error: cuErr.message }
      }

      // 3. Create a default warehouse "Principal"
      const { error: whErr } = await supabase
        .from('warehouses')
        .insert({ company_id: companyId, name: 'Principal' })

      if (whErr) {
        // Non-fatal: company and user are created, warehouse can be added later
        console.warn("Warning: could not create default warehouse:", whErr.message)
      }

      // 4. Refresh the company state
      await refreshCompany()

      return { success: true }
    } catch (e: any) {
      return { success: false, error: e.message || "Error inesperado" }
    }
  }, [user, supabase, refreshCompany])

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
        hasCompany: !!company,
        refreshCompany,
        createCompany,
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
