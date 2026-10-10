"use client"

import { useId, type ReactNode } from "react"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { useBranches } from "@/hooks/data/use-branches"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import { resolveDefaultBranch } from "@/lib/default-branch"

interface BranchSelectProps {
  value: string | null
  onChange: (value: string | null) => void
  placeholder?: string
  className?: string
  /**
   * remitos-venta (D11): la sucursal es obligatoria. Sin la opción "Sin
   * sucursal" (`onChange` nunca recibe `null`) y sin las sucursales CERRADAS
   * (`status = 'closed'`, que el servidor rechaza con `branch_closed`). El
   * placeholder por defecto pasa a "Elegí la sucursal". Default `false`: los
   * usos actuales no cambian.
   */
  required?: boolean
  /**
   * remitos-venta (D11): se muestra aunque el plan no tenga módulo de
   * sucursales (3 de los 4 planes) — el remito sale siempre de una sucursal
   * concreta. Default `false`: los usos actuales no cambian.
   */
  alwaysVisible?: boolean
  /**
   * ventas-sucursal-por-defecto (D9): con `false` desaparece la opción «Sin
   * sucursal (general)» y el selector muestra la sucursal PRINCIPAL ya elegida
   * (`resolveDefaultBranch`, espejo de `c26_default_branch`), rotulada «Nombre
   * (principal)». El estado del formulario NO cambia: sigue en `null` hasta que el
   * usuario elige otra sucursal; con `null` viaja `null` y el SERVIDOR resuelve la
   * principal con datos vivos. Elegir la principal que ya se muestra no emite
   * `onChange` (Radix sólo emite cuando el valor cambia). Default `true`: compra,
   * gasto e importador de gastos conservan su opción sin sucursal.
   */
  allowUnassigned?: boolean
  /**
   * ventas-sucursal-por-defecto (D9): rótulo propio del campo. Vive DENTRO del
   * componente —con `useId`, `<Label htmlFor>` e `id` en el disparador, el patrón
   * de `PaymentMethodSelect`— para que desaparezca junto con el control en las
   * cuentas sin módulo de sucursales (donde el componente no renderiza nada).
   */
  label?: string
  /**
   * ventas-sucursal-por-defecto (D9): la sucursal que el SERVIDOR va a usar si el
   * usuario no elige otra, cuando no es la principal (por ejemplo, la del
   * documento de origen). Sólo cambia el valor MOSTRADO con el estado en `null`
   * (`value ?? fallbackBranchId ?? principal`); no se emite por `onChange`. Sólo
   * aplica con `allowUnassigned={false}`.
   */
  fallbackBranchId?: string | null
}

/**
 * Dropdown to select a branch for an operation.
 * Renders nothing if the account plan has no branches module (non-PRO), salvo
 * con `alwaysVisible`.
 */
export function BranchSelect({
  value,
  onChange,
  placeholder,
  className,
  required = false,
  alwaysVisible = false,
  allowUnassigned = true,
  label,
  fallbackBranchId = null,
}: BranchSelectProps) {
  const { limits } = usePlanLimits()
  const { branches, isLoading } = useBranches()
  const selectId = `branch-select-${useId()}`

  if (!alwaysVisible && !limits?.hasBranchesModule) return null

  // El rótulo (y su `id`) sólo existen si se pidió `label`: sin él, el DOM es el de siempre.
  const triggerId = label ? selectId : undefined
  const withLabel = (control: ReactNode) =>
    label ? (
      <div className="flex flex-col gap-2">
        <Label htmlFor={selectId} className="text-foreground text-sm">
          {label}
        </Label>
        {control}
      </div>
    ) : (
      control
    )

  const effectivePlaceholder = placeholder ?? (required ? "Elegí la sucursal" : "Sin sucursal (general)")

  if (required) {
    return withLabel(
      <Select value={value ?? ""} onValueChange={(v) => onChange(v)}>
        <SelectTrigger id={triggerId} className={className}>
          <SelectValue placeholder={effectivePlaceholder} />
        </SelectTrigger>
        <SelectContent>
          {branches
            .filter((branch) => branch.status !== "closed")
            .map((branch) => (
              <SelectItem key={branch.id} value={branch.id}>
                {branch.name}
              </SelectItem>
            ))}
        </SelectContent>
      </Select>,
    )
  }

  if (!allowUnassigned) {
    const principal = resolveDefaultBranch(branches)
    const displayedId = value ?? fallbackBranchId ?? principal?.id ?? null
    // Nunca dice «Sin sucursal»: mientras cargan, «Cargando sucursales…»; ya cargadas y
    // sin ninguna a la vista, el servidor rechazará con no_branch_found.
    const placeholderText = isLoading ? "Cargando sucursales…" : (placeholder ?? "Sin sucursal disponible")
    return withLabel(
      <Select value={displayedId ?? ""} onValueChange={(v) => onChange(v)}>
        <SelectTrigger id={triggerId} className={className}>
          <SelectValue placeholder={placeholderText} />
        </SelectTrigger>
        <SelectContent>
          {branches.map((branch) => (
            <SelectItem key={branch.id} value={branch.id}>
              {branch.id === principal?.id ? `${branch.name} (principal)` : branch.name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>,
    )
  }

  return withLabel(
    <Select
      value={value ?? "__none__"}
      onValueChange={(v) => onChange(v === "__none__" ? null : v)}
    >
      <SelectTrigger id={triggerId} className={className}>
        <SelectValue placeholder={effectivePlaceholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="__none__">{effectivePlaceholder}</SelectItem>
        {branches.map((branch) => (
          <SelectItem key={branch.id} value={branch.id}>
            {branch.name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>,
  )
}
