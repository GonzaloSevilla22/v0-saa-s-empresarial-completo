"use client"

/**
 * AccountSwitcher — selector de la cuenta activa, en el encabezado del menú lateral.
 *
 * multiusuario-operativo (tanda A, D5). Un usuario puede pertenecer a más de una cuenta:
 * su cuenta personal (que crea `handle_new_user` al registrarse) y el negocio al que lo
 * invitaron. Opera siempre sobre UNA — la activa —, y este selector la cambia.
 *
 * - Se muestra SÓLO con dos o más cuentas: quien tiene una sola no ve nada nuevo.
 * - Muestra el nombre visible de cada negocio (la cascada de los documentos comerciales,
 *   resuelta en `lib/accounts.ts`) y el rol del usuario en cada uno (etiquetas del
 *   catálogo `account_role_catalog`, nunca un objeto hardcodeado).
 * - Al elegir, delega en `switchAccount` del contexto: persiste, renueva el token, limpia
 *   la caché, avisa a las otras pestañas y lleva al Tablero.
 * - Es el mismo componente en el riel de escritorio, en el menú expandido y en el drawer
 *   móvil. Sólo tokens semánticos (claro y oscuro) y alto táctil de 44 px (`min-h-11`).
 */
import { useState } from "react"
import { Building2, ChevronsUpDown } from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { resolveRoleLabel, useRoleCatalog } from "@/hooks/data/use-role-catalog"
import type { AccountSummary } from "@/lib/accounts"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { cn } from "@/lib/utils"

export function AccountSwitcher() {
  const { accounts } = useAuth()
  // Quien tiene UNA sola cuenta no ve nada nuevo — y tampoco paga nada: el catálogo de roles
  // (una lectura a Supabase) vive en el cuerpo, que sólo se monta con dos o más cuentas.
  if (accounts.length < 2) return null
  return <AccountSwitcherMenu />
}

function AccountSwitcherMenu() {
  const { accounts, switchAccount } = useAuth()
  const { data: catalog } = useRoleCatalog()
  const [pending, setPending] = useState(false)

  const active = accounts.find((account) => account.isActive) ?? null

  /** "Vendedor, Cajero" — los roles ACTIVOS del usuario en esa cuenta. */
  const roleText = (account: AccountSummary): string => {
    const codes = account.roles.length > 0 ? account.roles : [account.memberRole]
    return codes.map((code) => resolveRoleLabel(catalog, code)).join(", ")
  }

  async function handleChange(accountId: string) {
    if (pending || accountId === active?.accountId) return
    setPending(true)
    try {
      await switchAccount(accountId)
    } catch {
      // El contexto ya avisó del error y recargó la lista: acá sólo se rehabilita el selector.
    } finally {
      setPending(false)
    }
  }

  const label = active ? `Cuenta activa: ${active.displayName}` : "Elegir cuenta activa"

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          aria-label={label}
          title={active?.displayName}
          disabled={pending}
          className={cn(
            "flex min-h-11 w-full items-center gap-2 rounded-md border border-sidebar-border bg-sidebar-accent px-2 text-left text-sidebar-accent-foreground",
            "outline-none transition-colors hover:bg-sidebar-accent/80 focus-visible:ring-2 focus-visible:ring-sidebar-ring disabled:pointer-events-none disabled:opacity-60",
            "group-data-[collapsible=icon]:justify-center group-data-[collapsible=icon]:px-0",
          )}
        >
          <Building2 className="h-4 w-4 shrink-0" aria-hidden="true" />
          <span className="flex min-w-0 flex-1 flex-col group-data-[collapsible=icon]:hidden">
            <span className="truncate text-sm font-medium leading-tight">{active?.displayName ?? "Elegí una cuenta"}</span>
            {active && <span className="truncate text-[11px] leading-tight text-sidebar-foreground/70">{roleText(active)}</span>}
          </span>
          <ChevronsUpDown className="h-4 w-4 shrink-0 opacity-60 group-data-[collapsible=icon]:hidden" aria-hidden="true" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64 max-w-[calc(100vw-2rem)]">
        <DropdownMenuLabel>Tus cuentas</DropdownMenuLabel>
        <DropdownMenuRadioGroup value={active?.accountId ?? ""} onValueChange={(value) => void handleChange(value)}>
          {accounts.map((account) => (
            <DropdownMenuRadioItem
              key={account.accountId}
              value={account.accountId}
              className="min-h-11 flex-col items-start justify-center gap-0"
            >
              <span className="w-full truncate text-sm font-medium">{account.displayName}</span>
              <span className="w-full truncate text-xs text-muted-foreground">{roleText(account)}</span>
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
