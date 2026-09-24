"use client"

/**
 * venta-editable-vs-promocion-legacy — pasada visual de los caminos de ERROR de
 * "Facturar" en /ventas, que el e2e real no puede provocar a demanda.
 *
 * Monta el listado REAL (`SaleOperationsList`) con una venta cargada a mano y
 * sin comprobante, e intercepta `window.fetch` hacia el backend:
 *   GET  /fiscal/profile          → emisor monotributista
 *   GET  /fiscal/points-of-sale   → un punto de venta
 *   POST …/promote-to-order       → orden preparada (o el 409/404 pedido)
 *   POST …/emit-invoice           → pending_cae (o el 409 pedido)
 *
 * `?error=out_of_sync` → la emisión responde 409 sales_order_out_of_sync (la
 * fila tiene que volver a "Facturar"); `?error=inconsistent` → la preparación
 * responde 409 operation_inconsistent; sin `error` → camino feliz (estado 3:
 * "Emitir comprobante"). `?theme=light|dark` escribe la clase `dark` en
 * <html> igual que next-themes. Los toasts los pinta el <Toaster> del layout
 * raíz (el mismo de la app). Sólo existe en desarrollo (ver README).
 */

import { useEffect, useState } from "react"

import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import type { Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

const SALES: Sale[] = [
  {
    id: "s-manual", date: "2026-09-23", productId: "p-manual", productName: "Servicio de instalación",
    clientId: "", clientName: "Consumidor Final", quantity: 2, unitPrice: 1234.5,
    total: 2469, currency: "ARS", operationId: "op-manual",
    isFiscallyLocked: false, fiscal: null,
  },
]

const META: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

function json(body: unknown, status = 200, contentType = "application/json") {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": contentType } })
}

function installFetchIntercept(error: string | null) {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    if (!url.startsWith(backend)) return original(input, init)
    const method = (init?.method ?? "GET").toUpperCase()

    if (url.endsWith("/fiscal/profile")) {
      return json({
        id: "fp-h", account_id: "acc-h", cuit: "20999999991", iva_condition: "monotributista",
        iibb_condition: null, certificado_afip_path: null, ambiente: "homologacion",
        created_at: "2026-09-23T00:00:00Z", delegacion_autorizada: true, platform_representante_cuit: null,
      })
    }
    if (url.endsWith("/fiscal/points-of-sale")) {
      return json([{ id: "pv-h", fiscal_profile_id: "fp-h", account_id: "acc-h", branch_id: null, numero: 1, is_active: true, created_at: "2026-09-23T00:00:00Z" }])
    }
    if (method === "POST" && url.includes("/promote-to-order")) {
      if (error === "inconsistent") {
        return json({ type: "about:blank", title: "Conflicto", status: 409, code: "http_error",
          detail: "Conflicto: operation_inconsistent: las líneas de la operación op-manual tienen distinto cliente — editá la venta para unificarlo antes de facturar" },
          409, "application/problem+json")
      }
      return json({ sales_order_id: "so-h", sale_operation_id: "op-manual", replayed: false })
    }
    if (method === "POST" && url.includes("/emit-invoice")) {
      if (error === "out_of_sync") {
        return json({ type: "about:blank", title: "Conflicto", status: 409, code: "http_error",
          detail: "Conflicto: sales_order_out_of_sync: la orden so-h no coincide con su venta (orden 2469.00, venta 2000.00, líneas 1) — volvé a preparar la venta para facturar" },
          409, "application/problem+json")
      }
      return json({ fiscal_document_id: "fd-h", comprobante_type: "factura_c", status: "pending_cae", punto_de_venta: 1, number: 12, sales_order_id: "so-h" })
    }
    return json([])
  }
  return () => { window.fetch = original }
}

export function FacturarVentaHarness() {
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const uninstall = installFetchIntercept(params.get("error"))
    const t = params.get("theme") === "dark" ? "dark" : "light"
    document.documentElement.classList.toggle("dark", t === "dark")
    document.documentElement.dataset.theme = t
    setReady(true)
    return uninstall
  }, [])

  if (!ready) return null

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground" data-testid="harness-title">
        Arnés — Facturar una venta cargada a mano
      </h1>
      <SaleOperationsList
        sales={SALES}
        meta={META}
        loading={false}
        error={null}
        dateFrom="" setDateFrom={() => {}}
        dateTo="" setDateTo={() => {}}
        paymentMethodId={null} setPaymentMethodId={() => {}}
        clearFilters={() => {}}
        onPageChange={() => {}}
        onPageSizeChange={() => {}}
        clients={[]}
        onDeleteOperation={async () => {}}
        onEditOperation={() => {}}
        onRefetch={() => {}}
      />
    </main>
  )
}
