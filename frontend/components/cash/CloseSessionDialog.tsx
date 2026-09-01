"use client"

import { useState } from "react"
import { Loader2, AlertCircle, CheckCircle2 } from "lucide-react"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"

// G10 (H26): formato canónico de la app — "-$ 37.200,00", nunca "$-37.200,00"
// (el mismo que usa el "Historial de sesiones" de la misma pantalla).
const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

interface CloseSessionDialogProps {
  /**
   * Controlado desde la página (G6/H6): el diálogo vive FUERA del ternario
   * de sesión para que el panel de arqueo sobreviva al refetch de
   * current-session (mismo patrón que LedgerAdjustmentDialog).
   */
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Expected balance = opening + Σ movements (shown read-only to the cashier) */
  expectedBalance: number
  onClose: (countedBalance: number) => Promise<void>
  isLoading: boolean
}

export function CloseSessionDialog({
  open,
  onOpenChange,
  expectedBalance,
  onClose,
  isLoading,
}: CloseSessionDialogProps) {
  const [counted, setCounted] = useState<string>("")
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<{
    expected: number
    counted: number
    difference: number
  } | null>(null)

  function reset() {
    setCounted("")
    setError(null)
    setResult(null)
  }

  function handleOpenChange(v: boolean) {
    if (!v) reset()
    onOpenChange(v)
  }

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    setError(null)

    const value = parseFloat(counted.replace(",", "."))
    if (isNaN(value) || value < 0) {
      setError("Ingresá el efectivo contado (mayor o igual a 0).")
      return
    }

    try {
      await onClose(value)
      const diff = value - expectedBalance
      setResult({ expected: expectedBalance, counted: value, difference: diff })
    } catch (err) {
      setError((err as Error).message)
    }
  }

  const previewDiff =
    counted !== "" && !isNaN(parseFloat(counted))
      ? parseFloat(counted.replace(",", ".")) - expectedBalance
      : null

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Cierre de sesión de caja</DialogTitle>
          <DialogDescription>
            Contá el efectivo físico e ingresá el total. El sistema calculará la
            diferencia con el saldo esperado.
          </DialogDescription>
        </DialogHeader>

        {!result ? (
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="rounded-md bg-muted/60 px-4 py-3 text-sm">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Saldo esperado</span>
                <span className="font-semibold">{fmtMoney(expectedBalance)}</span>
              </div>
              {previewDiff != null && (
                <div className="flex justify-between mt-1">
                  <span className="text-muted-foreground">Diferencia (previa)</span>
                  <span
                    className={`font-semibold ${
                      previewDiff === 0
                        ? "text-green-600 dark:text-green-400"
                        : "text-yellow-600 dark:text-yellow-400"
                    }`}
                  >
                    {previewDiff >= 0 ? "+" : ""}
                    {fmtMoney(previewDiff)}
                  </span>
                </div>
              )}
            </div>

            <div className="flex flex-col gap-1.5">
              <Label htmlFor="counted-balance">Efectivo contado ($)</Label>
              <Input
                id="counted-balance"
                type="number"
                min="0"
                step="0.01"
                placeholder={expectedBalance.toFixed(2)}
                value={counted}
                onChange={(e) => setCounted(e.target.value)}
                disabled={isLoading}
                autoFocus
                aria-describedby={error ? "counted-error" : undefined}
              />
              {error && (
                <p
                  id="counted-error"
                  className="text-xs text-destructive flex items-center gap-1"
                  role="alert"
                >
                  <AlertCircle className="h-3.5 w-3.5 shrink-0" />
                  {error}
                </p>
              )}
            </div>

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => handleOpenChange(false)}
                disabled={isLoading}
              >
                Cancelar
              </Button>
              <Button type="submit" variant="destructive" disabled={isLoading}>
                {isLoading ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    Cerrando…
                  </>
                ) : (
                  "Confirmar cierre"
                )}
              </Button>
            </DialogFooter>
          </form>
        ) : (
          /* ── Resultado del arqueo ── */
          <div className="flex flex-col gap-4">
            <div
              className={`rounded-md px-4 py-3 text-sm flex flex-col gap-1 ${
                result.difference === 0
                  ? "bg-green-500/10 text-green-700 dark:text-green-400"
                  : "bg-yellow-500/10 text-yellow-700 dark:text-yellow-400"
              }`}
            >
              {result.difference === 0 ? (
                <div className="flex items-center gap-1.5 font-semibold">
                  <CheckCircle2 className="h-4 w-4" />
                  Arqueo exacto — sin diferencia
                </div>
              ) : (
                <div className="flex items-center gap-1.5 font-semibold">
                  <AlertCircle className="h-4 w-4" />
                  {result.difference > 0 ? "Sobrante en caja" : "Faltante en caja"}:{" "}
                  {result.difference >= 0 ? "+" : ""}
                  {fmtMoney(result.difference)}
                </div>
              )}
              <div className="flex justify-between text-xs">
                <span>Esperado</span>
                <span>{fmtMoney(result.expected)}</span>
              </div>
              <div className="flex justify-between text-xs">
                <span>Contado</span>
                <span>{fmtMoney(result.counted)}</span>
              </div>
            </div>
            <DialogFooter>
              <Button onClick={() => handleOpenChange(false)}>Listo</Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
