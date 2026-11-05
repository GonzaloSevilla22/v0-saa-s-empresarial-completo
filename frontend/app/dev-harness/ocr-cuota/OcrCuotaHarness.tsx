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
 *
 * `window.fetch` hacia el backend se intercepta (mismo patrón que EdicionDineroHarness): el botón
 * real monta `useProducts`/`usePurchases`, que llaman a FastAPI sin sesión; en CI el backend está
 * levantado y responde 401, y el transporte navega a /auth/login?reason=expired. Sin backend (local)
 * el fetch falla por red y no redirige — por eso el spec pasaba acá y fallaba en la CI.
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

/** Backend simulado: catálogo y compras vacíos para que el botón real monte sin sesión ni backend. */
function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    if (!(url.startsWith(backend) || url.startsWith("/api/"))) return original(input, init)
    const path = url.slice(backend.length).split("?")[0]
    const json = (body: unknown) =>
      new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } })
    if (path === "/purchases") return json({ items: [], total: 0, page: 1, pages: 0 })
    return json([])
  }
  return () => { window.fetch = original }
}

export function OcrCuotaHarness() {
  const queryClient = useQueryClient()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
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
    return uninstall
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
