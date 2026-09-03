"use client"

/**
 * cobranzas-vencimientos (D10, task 9.7) — plazo de pago por defecto de la
 * cuenta, en la pestaña Cobranzas de /configuracion (hogar canónico de los
 * ajustes de cuenta, mismo precedente que Centros de costo y Formas de pago).
 *
 * El vacío significa "sin plazo definido" (los cargos nacen sin vencimiento
 * y nada se marca como vencido) — NUNCA cero. El 0 explícito es contado a la
 * vista. La escritura va por rpc_set_default_payment_terms (guard
 * is_account_writer → 403 para quien no puede escribir en la cuenta).
 */

import { useEffect, useState } from "react"
import { toast } from "sonner"
import { CalendarClock } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  useCollectionSettings,
  useSetCollectionSettings,
} from "@/hooks/data/use-collection-settings"

export function CollectionSettingsForm() {
  const { data, isLoading } = useCollectionSettings()
  const { mutateAsync: saveSettings, isPending } = useSetCollectionSettings()
  const [draft, setDraft] = useState("")
  const [touched, setTouched] = useState(false)

  // Precarga con el valor persistido; el draft del usuario no se pisa.
  useEffect(() => {
    if (!touched) {
      setDraft(data?.defaultPaymentTermsDays != null ? String(data.defaultPaymentTermsDays) : "")
    }
  }, [data, touched])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = draft.trim()
    const parsed = trimmed === "" ? null : Number(trimmed)
    if (parsed !== null && (!Number.isInteger(parsed) || parsed < 0)) {
      toast.error("El plazo de pago debe ser un número de días (0 o más)")
      return
    }
    try {
      await saveSettings(parsed)
      setTouched(false)
      toast.success(
        parsed === null
          ? "Plazo por defecto borrado: los cargos nuevos nacen sin vencimiento"
          : `Plazo por defecto guardado: ${parsed} días`,
      )
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "No se pudo guardar el plazo")
    }
  }

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
          <CalendarClock className="h-4 w-4" />
          Plazo de pago por defecto
        </CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-3 max-w-md">
          <div className="flex flex-col gap-2">
            <Label htmlFor="default-payment-terms" className="text-foreground">
              Días para pagar una venta o compra a cuenta corriente
            </Label>
            <Input
              id="default-payment-terms"
              type="number"
              min={0}
              step={1}
              value={draft}
              disabled={isLoading}
              onChange={(e) => {
                setDraft(e.target.value)
                setTouched(true)
              }}
              placeholder="Sin plazo (los cargos nacen sin vencimiento)"
              className="bg-background border-border text-foreground"
            />
            <p className="text-xs text-muted-foreground">
              {draft.trim() === ""
                ? "Vacío = sin plazo definido: nada se marca como vencido. Cada cliente o proveedor puede tener un plazo propio que gana sobre este."
                : draft.trim() === "0"
                ? "0 = contado a la vista: el cargo vence el mismo día de la operación."
                : `Los cargos nuevos a cuenta corriente vencen a los ${draft.trim()} días — salvo que el cliente o proveedor tenga un plazo propio.`}
            </p>
            <p className="text-xs text-muted-foreground">
              Cambiar el plazo NO reescribe la deuda ya cargada: el vencimiento se pacta el
              día de cada operación y queda congelado.
            </p>
          </div>
          <Button type="submit" disabled={isPending || isLoading} className="w-fit">
            {isPending ? "Guardando…" : "Guardar plazo"}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
