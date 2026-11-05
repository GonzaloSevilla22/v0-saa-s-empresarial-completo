"use client"

/**
 * v31-ia-ratelimit-budget (task 4.9) — pasada visual del diálogo «Leer factura con IA».
 *
 * Monta el `InvoiceAIButton` REAL (el mismo de `/compras`) sin sesión ni backend. El saldo se
 * siembra en la caché de react-query con las MISMAS claves que usan `useAiUsage`/`usePlanLimits`
 * sin usuario (`["aiUsage", undefined]`, `["planLimits", "gratis"]`), y el rechazo por ráfaga se
 * simula reemplazando `invoiceOcrService.processInvoice`. `?state=`:
 *
 *   saldo  → 12 de 30 lecturas usadas («Te quedan 18 lecturas…») (default)
 *   cero   → 5 de 5 (aviso de límite + fecha de renovación + «Ver planes»)
 *   rafaga → como `saldo`, pero la función responde 429 `rate_limited` (retryAfterSeconds = 40)
 *
 * `?theme=light|dark` escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { useEffect, useState } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { InvoiceAIButton } from "@/components/invoice/InvoiceAIButton"
import { invoiceOcrService } from "@/lib/services/invoiceOcrService"
import { InvoiceOcrError } from "@/lib/invoice-types"
import type { PlanLimits } from "@/lib/types"

type HarnessState = "saldo" | "cero" | "rafaga"

function limitsFor(ocr: number): PlanLimits {
  return {
    plan: "gratis",
    priceMonthly: 0,
    maxUsers: 1,
    maxProducts: 100,
    maxClients: 50,
    maxSuppliers: 20,
    maxOperationsPerMonth: 100,
    historyDays: 30,
    maxExportsPerMonth: 0,
    maxAiQueriesPerMonth: 5,
    maxAiAdvicePerMonth: 3,
    maxAiOcrPerMonth: ocr,
    maxBranches: 1,
    hasProductProfitability: false,
    hasComparativeReports: false,
    hasPriceSuggestion: false,
    hasBranchesModule: false,
    hasMonthlyAnalysis: false,
    internalRoles: "none",
  }
}

export function OcrCuotaHarness() {
  const queryClient = useQueryClient()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const state = (params.get("state") as HarnessState | null) ?? "saldo"
    document.documentElement.classList.toggle("dark", params.get("theme") === "dark")

    const [used, limit] = state === "cero" ? [5, 5] : [12, 30]
    queryClient.setQueryData(["planLimits", "gratis"], limitsFor(limit))
    queryClient.setQueryData(["aiUsage", undefined], {
      ai_queries_used: 0,
      ai_advice_used: 0,
      ai_ocr_used: used,
      usage_reset_at: null,
    })

    if (state === "rafaga") {
      invoiceOcrService.processInvoice = async () => {
        throw new InvoiceOcrError("rate_limited", "Demasiadas lecturas seguidas", { retryAfterSeconds: 40 })
      }
    }
    setReady(true)
  }, [queryClient])

  return (
    <main className="mx-auto flex min-h-screen max-w-xl flex-col gap-4 p-6">
      <h1 className="text-xl font-semibold text-foreground">Arnés — cupo de lecturas de factura</h1>
      <p className="text-sm text-muted-foreground">
        Abrí «Subir factura IA» para ver el diálogo real de /compras.
      </p>
      <div>{ready && <InvoiceAIButton />}</div>
    </main>
  )
}
