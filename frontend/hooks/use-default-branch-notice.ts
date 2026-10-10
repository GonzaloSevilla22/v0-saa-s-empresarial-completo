"use client"

/**
 * useDefaultBranchNotice — avisa al usuario cuando la sucursal por defecto
 * de su cuenta cambió (sucursal-guard-vaciado-auditoria, OQ-6).
 *
 * Contexto: `c26_default_branch(p_account_id)` (SQL STABLE) resuelve la
 * sucursal por defecto de la cuenta como la primera sucursal ACTIVA por
 * `created_at ASC` (con fallback a la más antigua si ninguna quedó activa).
 * Es una función interna llamada sólo desde otras RPCs — ningún frontend la
 * consulta directo. El equivalente en el cliente es `resolveDefaultBranch`
 * (`lib/default-branch.ts`, ventas-sucursal-por-defecto D10) sobre las
 * sucursales activas que devuelve `useBranches()` ordenadas por `created_at`
 * ascendente: la primera OPERATIVA (`status = 'active'`). Hasta ese change se
 * tomaba `branches[0]`, que sólo coincide con el servidor mientras la más
 * antigua no esté cerrada. Es el mismo helper que usa `useCashOptin`.
 *
 * El incidente que originó este aviso (22-08): una sucursal llena se
 * desactivó sin que nadie se enterara de que las operaciones sin sucursal
 * explícita pasaron a caer en OTRA sucursal por defecto. Este hook no evita
 * ese escenario (lo hace el guard de `branch-decommission-guard`) — sólo
 * avisa cuando, comparado con la última vez que esta pestaña lo vio, la
 * sucursal por defecto cambió.
 *
 * Persistencia: sessionStorage (por pestaña), a propósito. El aviso importa
 * cuando el cambio ocurre DENTRO de la sesión activa del usuario; una
 * pestaña nueva no tiene por qué reabrir el aviso de un cambio que no
 * acaba de pasar. Se leen/escriben las claves de sessionStorage directo
 * (try/catch, degradar en silencio en modo privado) — el mismo patrón que
 * ya usa `BranchFilter.tsx` para su propia clave (`eie_branch_filter`), en
 * vez de `usePersistentState`/`useSessionStorage`: acá no hay estado de UI
 * controlado, es una comparación imperativa de una sola vez por cambio.
 */

import { useEffect } from "react"
import { toast } from "sonner"
import { useBranches } from "@/hooks/data/use-branches"
import { resolveDefaultBranch } from "@/lib/default-branch"

const SEEN_KEY = "eie_default_branch_seen"

export function useDefaultBranchNotice(): void {
  const { branches, isLoading } = useBranches()

  useEffect(() => {
    if (isLoading) return
    // Cuenta sin ninguna sucursal activa (todavía no recibió su primer
    // movimiento de stock) — nada que comparar.
    if (branches.length === 0) return

    const defaultBranch = resolveDefaultBranch(branches)
    if (!defaultBranch) return

    let previous: string | null = null
    try {
      previous = sessionStorage.getItem(SEEN_KEY)
    } catch {
      // sessionStorage no disponible (modo privado) — degradar sin romper.
      return
    }

    if (previous !== null && previous !== defaultBranch.id) {
      toast.info(`Tu sucursal por defecto ahora es ${defaultBranch.name}`)
    }

    if (previous !== defaultBranch.id) {
      try {
        sessionStorage.setItem(SEEN_KEY, defaultBranch.id)
      } catch {
        // ignore — degradar sin romper
      }
    }
  }, [branches, isLoading])
}
