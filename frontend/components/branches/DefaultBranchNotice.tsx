"use client"

/**
 * DefaultBranchNotice — envoltorio sin UI para `useDefaultBranchNotice`
 * (sucursal-guard-vaciado-auditoria, OQ-6). Mismo molde que
 * `IdleTimeoutProvider` (components/auth/IdleTimeoutProvider.tsx): un
 * componente cliente dedicado, montado una sola vez en el shell del
 * dashboard, que no renderiza nada — sólo dispara el efecto del hook.
 *
 * Por qué en el shell y no dentro de `BranchFilter.tsx`: `BranchFilter`
 * retorna `null` cuando el plan no tiene módulo de sucursales
 * (`!limits?.hasBranchesModule`, L32) y hoy sólo se monta en dos pantallas
 * (`/dashboard`, `/estadisticas`). `useBranches()` en cambio no depende del
 * plan — toda cuenta tiene al menos su sucursal por defecto creada
 * perezosamente (ver spec `branches`) — así que este componente necesita
 * un punto de montaje que SIEMPRE esté presente para cualquier cuenta
 * autenticada, en cualquier pantalla operativa. El shell del dashboard
 * (`app/(dashboard)/layout.tsx`) es ese punto.
 */

import { useDefaultBranchNotice } from "@/hooks/use-default-branch-notice"

export function DefaultBranchNotice() {
  useDefaultBranchNotice()
  return null
}
