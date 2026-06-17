"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Loader2, Vault } from "lucide-react"

interface OpenSessionFormProps {
  onOpen: (openingBalance: number) => Promise<void>
  isLoading: boolean
}

export function OpenSessionForm({ onOpen, isLoading }: OpenSessionFormProps) {
  const [openingBalance, setOpeningBalance] = useState<string>("0")
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    setError(null)

    const value = parseFloat(openingBalance.replace(",", "."))
    if (isNaN(value) || value < 0) {
      setError("Ingresá un saldo inicial válido (mayor o igual a 0).")
      return
    }

    try {
      await onOpen(value)
    } catch (err) {
      setError((err as Error).message)
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Vault className="h-5 w-5" />
          Abrir sesión de caja
        </CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="opening-balance">Saldo inicial ($)</Label>
            <Input
              id="opening-balance"
              type="number"
              min="0"
              step="0.01"
              value={openingBalance}
              onChange={(e) => setOpeningBalance(e.target.value)}
              placeholder="0.00"
              disabled={isLoading}
              aria-describedby={error ? "opening-balance-error" : undefined}
            />
            {error && (
              <p
                id="opening-balance-error"
                className="text-xs text-destructive"
                role="alert"
              >
                {error}
              </p>
            )}
          </div>
          <Button type="submit" disabled={isLoading} className="w-full sm:w-auto">
            {isLoading ? (
              <>
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                Abriendo…
              </>
            ) : (
              "Abrir caja"
            )}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
