"use client"

import React, { createContext, useContext, useState, useEffect, useCallback } from "react"
import { createClient } from "@/lib/supabase/client"
import { useRouter } from "next/navigation"
import type { User, Plan, UserRole } from "@/lib/types"

interface AuthContextType {
  user: User | null
  isAuthenticated: boolean
  isAdmin: boolean
  login: (email: string, password: string) => Promise<void>
  loginAsAdmin: () => Promise<void>
  register: (name: string, email: string, password: string) => Promise<void>
  logout: () => Promise<void>
  upgradePlan: () => Promise<void>
  downgradePlan: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | null>(null)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)
  const supabase = createClient()
  const router = useRouter()

  const refreshSession = useCallback(async () => {
    try {
      const { data: { session }, error } = await supabase.auth.getSession()
      if (error || !session) {
        setUser(null)
        return
      }

      // Fetch profile data for plan and role
      const { data: profile } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', session.user.id)
        .single()

      if (profile) {
        setUser({
          id: session.user.id,
          name: session.user.user_metadata?.name || session.user.email?.split("@")[0] || "Emprendedor",
          email: session.user.email || "",
          plan: 'pro', // MVP: Force PRO plan
          role: profile.role as UserRole,
        })
      } else {
        setUser({
          id: session.user.id,
          name: session.user.user_metadata?.name || session.user.email?.split("@")[0] || "Emprendedor",
          email: session.user.email || "",
          plan: 'pro', // MVP: Force PRO plan
          role: 'user',
        })
      }
    } catch (e) {
      console.error(e)
    } finally {
      setLoading(false)
    }
  }, [supabase])

  useEffect(() => {
    refreshSession()

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      refreshSession()
    })

    return () => {
      subscription.unsubscribe()
    }
  }, [refreshSession, supabase.auth])

  const login = useCallback(async (email: string, password: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    })
    if (error) throw error
    await refreshSession()
    router.push("/dashboard")
  }, [supabase, router, refreshSession])

  const loginAsAdmin = useCallback(async () => {
    const { error } = await supabase.auth.signInWithPassword({
      email: "admin@eie.com",
      password: "password1234",
    })
    if (error) throw error
    await refreshSession()
    router.push("/dashboard")
  }, [supabase, router, refreshSession])

  const register = useCallback(async (name: string, email: string, password: string) => {
    if (password.length < 6) throw new Error("La contraseña debe tener al menos 6 caracteres")
    const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ||
      (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3000')
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { name },
        emailRedirectTo: `${siteUrl}/auth/callback`,
      }
    })
    if (error) throw error
    // Introduce a tiny delay so the postgres trigger can complete the profile insert
    await new Promise((resolve) => setTimeout(resolve, 500))
    await refreshSession()
    router.push("/dashboard")
  }, [supabase, router, refreshSession])

  const logout = useCallback(async () => {
    const { error } = await supabase.auth.signOut()
    if (error) throw error
    router.push("/login")
  }, [supabase, router])

  const upgradePlan = useCallback(async () => {
    if (!user) return
    const { error } = await supabase.from('profiles').update({ plan: 'pro' }).eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  const downgradePlan = useCallback(async () => {
    if (!user) return
    const { error } = await supabase.from('profiles').update({ plan: 'free' }).eq('id', user.id)
    if (error) throw error
    await refreshSession()
  }, [supabase, user, refreshSession])

  // Don't render children until initial session check is complete to prevent auth flashes
  if (loading) {
    return <div className="min-h-screen flex items-center justify-center">Loading...</div>
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        isAuthenticated: !!user,
        isAdmin: user?.role === "admin",
        login,
        loginAsAdmin,
        register,
        logout,
        upgradePlan,
        downgradePlan,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider")
  }
  return context
}
