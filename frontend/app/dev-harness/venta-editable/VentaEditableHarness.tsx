"use client"

/**
 * venta-editable-sin-cae — pasada visual.
 *
 * Monta el listado REAL (`SaleOperationsList`) con las cinco clases de venta que
 * el change distingue, y el diálogo de borrado real de la fila anulable, para la
 * pasada visual de las 4 combinaciones (1366 / 375 × claro / oscuro). Las
 * pantallas reales (`/ventas`) exigen sesión y backend; acá no hace falta
 * ninguno de los dos, que es todo el punto del arnés (ver README).
 *
 * `?view=form` monta en cambio el formulario de edición con el comprobante
 * pendiente ANULABLE, para capturar el banner de aviso y el AlertDialog de
 * confirmación ("Guardar y anular").
 *
 * El toggle de tema escribe la clase `dark` en `<html>` igual que next-themes,
 * para que el spec capture los dos temas sin depender del provider.
 */

import { useEffect, useState } from "react"

import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { SaleForm } from "@/components/forms/sale-form"
import { groupSalesByOperation } from "@/lib/group-operations"
import type { Sale, SaleFiscalState } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

function fiscal(over: Partial<SaleFiscalState> & Pick<SaleFiscalState, "documentId" | "status" | "label">): SaleFiscalState {
  return { submittedToArca: false, frozen: false, voidable: false, ...over }
}

const SALES: Sale[] = [
  {
    id: "s-sin", date: "2026-09-22", productId: "p1", productName: "Remera algodón",
    clientId: "c1", clientName: "Cliente sin comprobante", quantity: 2, unitPrice: 12500,
    total: 25000, currency: "ARS", operationId: "op-sin",
    isFiscallyLocked: false, fiscal: null,
  },
  {
    id: "s-void", date: "2026-09-22", productId: "p2", productName: "Short deportivo",
    clientId: "c2", clientName: "Comprobante pendiente (anulable)", quantity: 1, unitPrice: 18400,
    total: 18400, currency: "ARS", operationId: "op-void",
    isFiscallyLocked: false,
    fiscal: fiscal({ documentId: "fd-void", status: "pending_cae", label: "0003-00000005", voidable: true }),
  },
  {
    id: "s-sent", date: "2026-09-21", productId: "p3", productName: "Campera rompeviento",
    clientId: "c3", clientName: "Comprobante enviado a ARCA", quantity: 1, unitPrice: 64900,
    total: 64900, currency: "ARS", operationId: "op-sent",
    isFiscallyLocked: true,
    fiscal: fiscal({ documentId: "fd-sent", status: "pending_cae", label: "0003-00000006", submittedToArca: true }),
  },
  {
    id: "s-auth", date: "2026-09-20", productId: "p4", productName: "Zapatillas running",
    clientId: "c4", clientName: "Comprobante autorizado", quantity: 1, unitPrice: 132000,
    total: 132000, currency: "ARS", operationId: "op-auth",
    isFiscallyLocked: true,
    fiscal: fiscal({ documentId: "fd-auth", status: "authorized", label: "0003-00000004", submittedToArca: true }),
  },
  {
    id: "s-anulado", date: "2026-09-19", productId: "p5", productName: "Gorra trucker",
    clientId: "c5", clientName: "Comprobante anulado", quantity: 3, unitPrice: 9800,
    total: 29400, currency: "ARS", operationId: "op-anulado",
    isFiscallyLocked: false,
    fiscal: fiscal({ documentId: "fd-anulado", status: "voided", label: "0003-00000005" }),
  },
]

const META: PaginationMeta = {
  page: 0, pageSize: 25, totalCount: SALES.length, pageCount: 1, from: 1, to: SALES.length,
}

/**
 * Los dos componentes reales llaman a hooks de datos (useProducts, useClients,
 * useFiscalProfile, usePaymentMethods, …) que pegan al backend vía
 * `pythonClient`. El arnés no tiene backend ni sesión, así que se intercepta
 * `window.fetch` y se devuelve vacío — mismo espíritu que
 * `app/dev-harness/expense-import`. Lo que se está mirando acá es el ESTADO
 * FISCAL de la venta, que viaja por props, no por esos catálogos.
 */
function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    if (url.startsWith(backend) || url.startsWith("/api/")) {
      const empty = url.includes("/sales")
        ? JSON.stringify({ items: [], total: 0, page: 0, pages: 0 })
        : "[]"
      return new Response(empty, { status: 200, headers: { "Content-Type": "application/json" } })
    }
    return original(input, init)
  }
  return () => { window.fetch = original }
}

export function VentaEditableHarness() {
  const [view, setView] = useState<"list" | "form">("list")
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
    const params = new URLSearchParams(window.location.search)
    const theme = params.get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
    setView(params.get("view") === "form" ? "form" : "list")
    setReady(true)
    return uninstall
  }, [])

  const editingOperation = groupSalesByOperation([SALES[1]])[0]

  if (!ready) return null

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground" data-testid="harness-title">
        Arnés — Venta editable sin CAE ({view === "form" ? "formulario" : "listado"})
      </h1>

      {view === "list" ? (
        <div data-testid="harness-list">
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
        </div>
      ) : (
        <div data-testid="harness-form" className="max-w-3xl">
          <SaleForm onSuccess={() => {}} editingOperation={editingOperation} />
        </div>
      )}
    </main>
  )
}
