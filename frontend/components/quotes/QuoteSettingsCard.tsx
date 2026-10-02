"use client"

/**
 * presupuestos-modulo (D7, tarea 5.11) — validez por defecto de los
 * presupuestos, en la pestaña Cobranzas de /configuracion.
 *
 * Va junto al plazo de pago porque las dos son condiciones comerciales hacia el
 * cliente (una 12ª pestaña para un solo número sería desproporcionada). Sólo
 * owner/admin la editan (`CAN_CONFIGURE`, la misma capacidad que exige la RPC
 * `rpc_set_default_quote_validity`); el resto la ve en sólo lectura. El rango
 * 1..365 se valida acá antes de llamar y el servidor lo vuelve a validar.
 */
import { useEffect, useState } from "react"
import { FileText } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useQuoteSettings, useUpdateQuoteSettings } from "@/hooks/data/use-quotes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { humanizeOperationError } from "@/lib/operation-errors"
import { CAN_CONFIGURE, hasCapability } from "@/lib/rbac-capabilities"

const MIN_DAYS = 1
const MAX_DAYS = 365

function daysLabel(days: number): string {
  return `${days} ${days === 1 ? "día" : "días"}`
}

export function QuoteSettingsCard() {
  const { data, isLoading } = useQuoteSettings()
  const { mutateAsync: saveSettings, isPending } = useUpdateQuoteSettings()
  const { roles, rolesResolved } = useOrgRole()
  const canConfigure = hasCapability(roles, CAN_CONFIGURE, rolesResolved)

  const [draft, setDraft] = useState("")
  const [touched, setTouched] = useState(false)

  // Precarga con el valor persistido; lo que el usuario tipeó no se pisa.
  useEffect(() => {
    if (!touched) setDraft(data ? String(data.defaultQuoteValidityDays) : "")
  }, [data, touched])

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault()
    const trimmed = draft.trim()
    const parsed = trimmed === "" ? Number.NaN : Number(trimmed)
    if (!Number.isInteger(parsed) || parsed < MIN_DAYS || parsed > MAX_DAYS) {
      toast.error(`La validez tiene que ser un número entero de días entre ${MIN_DAYS} y ${MAX_DAYS}.`)
      return
    }
    try {
      await saveSettings(parsed)
      setTouched(false)
      toast.success(`Validez por defecto guardada: ${daysLabel(parsed)}`)
    } catch (err: unknown) {
      toast.error(humanizeOperationError(err instanceof Error ? err.message : "").message)
    }
  }

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
          <FileText className="h-4 w-4" aria-hidden="true" />
          Presupuestos — validez por defecto
        </CardTitle>
      </CardHeader>
      <CardContent>
        {canConfigure ? (
          <form onSubmit={handleSubmit} noValidate className="flex max-w-md flex-col gap-3">
            <div className="flex flex-col gap-2">
              <Label htmlFor="default-quote-validity" className="text-foreground">
                Días de validez de un presupuesto
              </Label>
              <Input
                id="default-quote-validity"
                type="number"
                min={MIN_DAYS}
                max={MAX_DAYS}
                step={1}
                value={draft}
                disabled={isLoading}
                onChange={(e) => {
                  setDraft(e.target.value)
                  setTouched(true)
                }}
                className="bg-background border-border text-foreground"
              />
              <p className="text-xs text-muted-foreground">
                Cada presupuesto nuevo nace válido por esta cantidad de días (entre {MIN_DAYS} y {MAX_DAYS}); se puede
                cambiar presupuesto por presupuesto. Cambiarlo no cambia los presupuestos ya creados.
              </p>
            </div>
            <Button type="submit" disabled={isPending || isLoading} className="w-fit">
              {isPending ? "Guardando…" : "Guardar validez"}
            </Button>
          </form>
        ) : (
          <div className="flex max-w-md flex-col gap-1">
            <p data-testid="quote-validity-readonly" className="text-sm text-foreground">
              Los presupuestos nuevos son válidos por {data ? daysLabel(data.defaultQuoteValidityDays) : "—"}.
            </p>
            <p className="text-xs text-muted-foreground">Sólo el dueño o un administrador puede cambiarlo.</p>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
