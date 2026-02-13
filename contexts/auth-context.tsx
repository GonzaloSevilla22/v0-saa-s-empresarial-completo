"use client"

import React, { createContext, useContext, useState, useCallback } from "react"
import type { User, Plan, UserRole } from "@/lib/types"

interface AuthContextType {
  user: User | null
  isAuthenticated: boolean
  isAdmin: boolean
  login: (email: string, password: string) => void
  loginAsAdmin: () => void
  register: (name: string, email: string, password: string) => void
  logout: () => void
  upgradePlan: () => void
  downgradePlan: () => void
}

const AuthContext = createContext<AuthContextType | null>(null)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>({
    id: "u1",
    name: "Emprendedor",
    email: "demo@eie.com",
    plan: "pro",
    role: "user",
  })

  const login = useCallback((email: string, _password: string) => {
    setUser({
      id: "u1",
      name: email.split("@")[0] || "Emprendedor",
      email,
      plan: "free",
      role: "user",
    })
  }, [])

  const loginAsAdmin = useCallback(() => {
    setUser({
      id: "admin1",
      name: "Administrador",
      email: "admin@eie.com",
      plan: "pro",
      role: "admin",
    })
  }, [])

  const register = useCallback((name: string, email: string, _password: string) => {
    setUser({
      id: "u1",
      name,
      email,
      plan: "free",
      role: "user",
    })
  }, [])

  const logout = useCallback(() => {
    setUser(null)
  }, [])

  const upgradePlan = useCallback(() => {
    setUser((prev) => (prev ? { ...prev, plan: "pro" as Plan } : null))
  }, [])

  const downgradePlan = useCallback(() => {
    setUser((prev) => (prev ? { ...prev, plan: "free" as Plan } : null))
  }, [])

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
