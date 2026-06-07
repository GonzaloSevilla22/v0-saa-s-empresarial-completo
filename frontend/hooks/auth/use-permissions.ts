"use client"

import { useMemo } from "react"
import { useAuth } from "@/contexts/auth-context"

// Permission definitions — extend as new modules are added
export type Permission =
  // Products
  | "products.view"
  | "products.create"
  | "products.edit"
  | "products.delete"
  | "products.import"
  | "products.export"
  // Stock
  | "stock.view"
  | "stock.adjust"
  | "stock.movements"
  // Sales
  | "sales.view"
  | "sales.create"
  | "sales.edit"
  | "sales.delete"
  | "sales.export"
  // Purchases
  | "purchases.view"
  | "purchases.create"
  | "purchases.edit"
  | "purchases.delete"
  // Clients
  | "clients.view"
  | "clients.create"
  | "clients.edit"
  | "clients.delete"
  // Expenses
  | "expenses.view"
  | "expenses.create"
  | "expenses.edit"
  | "expenses.delete"
  // Admin
  | "admin.dashboard"
  | "admin.users"
  | "admin.billing"
  | "admin.settings"

type Role = "admin" | "manager" | "operator" | "viewer"

// Role → permissions map. This is the single source of truth.
const ROLE_PERMISSIONS: Record<Role, Permission[]> = {
  admin: [
    "products.view", "products.create", "products.edit", "products.delete",
    "products.import", "products.export",
    "stock.view", "stock.adjust", "stock.movements",
    "sales.view", "sales.create", "sales.edit", "sales.delete", "sales.export",
    "purchases.view", "purchases.create", "purchases.edit", "purchases.delete",
    "clients.view", "clients.create", "clients.edit", "clients.delete",
    "expenses.view", "expenses.create", "expenses.edit", "expenses.delete",
    "admin.dashboard", "admin.users", "admin.billing", "admin.settings",
  ],
  manager: [
    "products.view", "products.create", "products.edit", "products.import", "products.export",
    "stock.view", "stock.adjust", "stock.movements",
    "sales.view", "sales.create", "sales.edit", "sales.export",
    "purchases.view", "purchases.create", "purchases.edit",
    "clients.view", "clients.create", "clients.edit",
    "expenses.view", "expenses.create", "expenses.edit",
    "admin.dashboard",
  ],
  operator: [
    "products.view", "products.create", "products.edit",
    "stock.view", "stock.adjust",
    "sales.view", "sales.create",
    "purchases.view", "purchases.create",
    "clients.view", "clients.create",
    "expenses.view", "expenses.create",
  ],
  viewer: [
    "products.view", "stock.view", "sales.view",
    "purchases.view", "clients.view", "expenses.view",
  ],
}

interface UsePermissionsReturn {
  can: (permission: Permission) => boolean
  canAll: (permissions: Permission[]) => boolean
  canAny: (permissions: Permission[]) => boolean
  role: Role
  isAdmin: boolean
}

/**
 * Permission check hook. Uses the user's role to derive capabilities.
 *
 * @example
 * const { can } = usePermissions()
 *
 * {can("stock.adjust") && <AdjustStockButton />}
 * {can("admin.dashboard") && <AdminLink />}
 */
export function usePermissions(): UsePermissionsReturn {
  const { user, isAdmin } = useAuth()

  const role = useMemo((): Role => {
    if (isAdmin) return "admin"
    // Extend: read role from user.profile.role when multi-role is implemented
    return "operator"
  }, [isAdmin])

  const permissionSet = useMemo(
    () => new Set(ROLE_PERMISSIONS[role]),
    [role],
  )

  const can = useMemo(
    () => (permission: Permission) => permissionSet.has(permission),
    [permissionSet],
  )

  const canAll = useMemo(
    () => (permissions: Permission[]) => permissions.every((p) => permissionSet.has(p)),
    [permissionSet],
  )

  const canAny = useMemo(
    () => (permissions: Permission[]) => permissions.some((p) => permissionSet.has(p)),
    [permissionSet],
  )

  return { can, canAll, canAny, role, isAdmin }
}
