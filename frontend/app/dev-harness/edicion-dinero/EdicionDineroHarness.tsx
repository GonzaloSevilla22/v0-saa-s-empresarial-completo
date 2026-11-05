"use client"

/**
 * edicion-operaciones-con-dinero (tanda C) — pasada visual.
 *
 * Monta los componentes REALES de la edición con dinero —`SaleForm`, `PurchaseForm`, `ExpenseForm` y el listado con su
 * «Historial de cambios»— contra un backend simulado (intercept de `window.fetch`): ni sesión ni backend ni datos sembrados,
 * que es todo el punto del arnés (ver README). El plan que devuelve el "servidor" se elige con `?plan=`:
 *
 *   plan=cuenta  → venta a crédito que sube: revierte el cargo viejo y registra el nuevo (default)
 *   plan=caja    → venta en efectivo que sube: sale lo que había entrado y entra lo nuevo
 *   plan=bloqueo → el plan con DOS bloqueos (caja cerrada y saldo que quedaría negativo)
 *
 * Vistas (`?view=`): `venta` (default), `venta-caja`, `compra`, `gasto`, `lista` (listado de ventas con el historial).
 * `?theme=light|dark` escribe la clase `dark` en `<html>` igual que next-themes.
 */

import { useEffect, useState } from "react"

import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { SaleForm } from "@/components/forms/sale-form"
import { PurchaseForm } from "@/components/forms/purchase-form"
import { ExpenseForm } from "@/components/forms/expense-form-v2"
import { groupPurchasesByOperation, groupSalesByOperation } from "@/lib/group-operations"
import type { Expense, Purchase, Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

const NOW = "2026-11-04T15:30:00Z"
const TODAY = new Date().toLocaleDateString("en-CA", { timeZone: "America/Argentina/Mendoza" })

const PAYMENT_METHODS = [
  { id: "pm-credit", account_id: "acc", name: "Cuenta corriente", kind: "credit", is_active: true, sort_order: 1, created_at: NOW },
  { id: "pm-cash", account_id: "acc", name: "Efectivo", kind: "cash", is_active: true, sort_order: 2, created_at: NOW },
  { id: "pm-transfer", account_id: "acc", name: "Transferencia", kind: "transfer", is_active: true, sort_order: 3, created_at: NOW },
]

const EMPTY_BOOKS = {
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}

const PLAN_CUENTA = {
  writes_money: true,
  blocks: [],
  account: {
    action: "both",
    party_kind: "customer",
    register: { party_id: "c1", amount: "31000.00", due_date: "2026-12-15", reference_id: "r2" },
    reverse: [{ ledger_id: "l1", net: "25000.00", reference_id: "r1" }],
    current_balance: "25000.00",
    projected_balance: "31000.00",
    current_due_date: "2026-12-01",
  },
  ...EMPTY_BOOKS,
}

const PLAN_CAJA = {
  writes_money: true,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: {
    action: "both",
    register: { session_id: "ses-hoy", cashbox_id: "cb1", amount: "31000.00", reference_id: "r2", movement_type: "sale" },
    reverse: [{ cashbox_id: "cb1", session_id: "ses-hoy", net: "25000.00", reference_id: "r1", movement_type: "sale_reversal" }],
  },
  bank: { action: "none", register: null, reverse: [] },
}

const PLAN_BLOQUEO = {
  ...PLAN_CUENTA,
  blocks: [
    { book: "cash", code: "P0426", token: "no_open_session_for_reversal", message: "no_open_session_for_reversal: abrí la caja…" },
    { book: "account", code: "P0425", token: "reversal_would_go_negative", message: "reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -6000.00: ya se registraron cobros" },
  ],
}

function planFor(name: string | null) {
  if (name === "caja") return PLAN_CAJA
  if (name === "bloqueo") return PLAN_BLOQUEO
  return PLAN_CUENTA
}

const HISTORY = [
  {
    id: "e3", created_at: "2026-11-04T15:30:00Z", user_id: "u1", user_name: "Laura Gómez", action: "sale_operation.edited",
    entity_type: "sale_operation", entity_id: "op-credito",
    before: { total: "25000.00", date: "2026-11-01" }, after: { total: "31000.00", date: "2026-11-01" },
    money: PLAN_CUENTA, voided_fiscal_document: null, reason: "El cliente llevó dos unidades más",
  },
  {
    id: "e2", created_at: "2026-11-02T13:05:00Z", user_id: "u2", user_name: "Martín Ruiz", action: "sale_operation.edited",
    entity_type: "sale_operation", entity_id: "op-credito",
    before: { total: "25000.00", date: "2026-10-31" }, after: { total: "25000.00", date: "2026-11-01" },
    money: null, voided_fiscal_document: null, reason: null,
  },
]

const SALE_CREDIT: Sale = {
  id: "s-credito", date: "2026-11-01", productId: "p1", productName: "Remera algodón", clientId: "c1", clientName: "Cliente Test",
  quantity: 2, unitPrice: 12500, total: 25000, currency: "ARS", operationId: "op-credito", branchId: "branch-1",
  paymentMethodId: "pm-credit", paymentMethodName: "Cuenta corriente", paymentMethodKind: "credit",
  hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "c1",
}
const SALE_CASH: Sale = {
  id: "s-caja", date: TODAY, productId: "p1", productName: "Remera algodón", clientId: "c1", clientName: "Cliente Test",
  quantity: 2, unitPrice: 12500, total: 25000, currency: "ARS", operationId: "op-caja", branchId: "branch-1",
  paymentMethodId: "pm-cash", paymentMethodName: "Efectivo", paymentMethodKind: "cash",
  hasCashMovement: true, cashCashboxId: "cb1", cashOpenSessionId: "ses-hoy",
}
const PURCHASE_CREDIT: Purchase = {
  id: "pu-credito", date: "2026-11-01", productId: "p1", productName: "Insumo de limpieza", quantity: 4, unitCost: 3000, total: 12000,
  operationId: "op-compra", branchId: "branch-1", paymentMethodId: "pm-credit", paymentMethodName: "Cuenta corriente",
  paymentMethodKind: "credit", supplierId: "sup-1", supplierName: "Distribuidora Mendoza",
  hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "sup-1",
}
const EXPENSE_CASH: Expense = {
  id: "exp-1", date: TODAY, category: "Servicios", description: "Luz de noviembre", amount: 18000, branchId: "branch-1",
  paymentMethodId: "pm-cash", paymentMethodName: "Efectivo", paymentMethodKind: "cash",
  hasCashMovement: true, cashCashboxId: "cb1", cashOpenSessionId: "ses-hoy",
}

const META: PaginationMeta = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }

/** Backend simulado: catálogos mínimos para que los formularios reales rendericen sus bloques de dinero. */
function installFetchIntercept(plan: string | null) {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url
    const backend = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8000"
    if (!(url.startsWith(backend) || url.startsWith("/api/"))) return original(input, init)
    const path = url.slice(backend.length).split("?")[0]
    const json = (body: unknown) =>
      new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } })
    if (path.endsWith("/edit-preview")) return json({ dry_run: true, plan: planFor(plan), voided_fiscal_document: null })
    if (path.endsWith("/edits")) return json(HISTORY)
    if (path === "/payment-methods") return json(PAYMENT_METHODS)
    if (path === "/clients") return json([{ id: "c1", account_id: "acc", name: "Cliente Test", email: null, phone: null, created_at: NOW }])
    if (path === "/suppliers") return json([{ id: "sup-1", account_id: "acc", name: "Distribuidora Mendoza", created_at: NOW }])
    if (path === "/clientes/c1/cuenta")
      return json({ id: "ca1", account_id: "acc", client_id: "c1", balance: "25000.00", created_at: NOW, movements: [] })
    if (path === "/proveedores/sup-1/cuenta" || path.includes("/sup-1/"))
      return json({ id: "sa1", account_id: "acc", supplier_id: "sup-1", balance: "12000.00", created_at: NOW, movements: [] })
    if (path === "/branches/branch-1/cashboxes") return json([{ id: "cb1", branch_id: "branch-1", name: "Caja 1", currency: "ARS", created_at: NOW }])
    if (path === "/cashboxes/cb1/current-session")
      return json({
        id: "ses-hoy-1234", cashbox_id: "cb1", status: "open", opening_balance: "0", closing_balance: null, counted_balance: null,
        expected_balance: null, difference: null, opened_by: "u1", closed_by: null, opened_at: NOW, closed_at: null, adjustments_total: "0",
      })
    if (path === "/bank-accounts") return json([])
    return json([])
  }
  return () => { window.fetch = original }
}

export function EdicionDineroHarness() {
  const [ready, setReady] = useState(false)
  const [view, setView] = useState("venta")

  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const uninstall = installFetchIntercept(params.get("plan"))
    const theme = params.get("theme")
    document.documentElement.classList.toggle("dark", theme === "dark")
    document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light"
    setView(params.get("view") ?? "venta")
    setReady(true)
    return uninstall
  }, [])

  if (!ready) return null

  const saleOp = groupSalesByOperation([view === "venta-caja" ? SALE_CASH : SALE_CREDIT])[0]
  const purchaseOp = groupPurchasesByOperation([PURCHASE_CREDIT])[0]

  return (
    <main className="min-h-screen bg-background p-4">
      <h1 className="mb-4 text-lg font-semibold text-foreground" data-testid="harness-title">
        Arnés — Edición con dinero ({view})
      </h1>

      {view === "lista" ? (
        <div data-testid="harness-list">
          <SaleOperationsList
            sales={[SALE_CREDIT, { ...SALE_CASH, id: "s-caja-2" }]}
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
        <div data-testid="harness-form" className="max-w-3xl rounded-lg border border-border bg-card p-4">
          {view === "compra" ? (
            <PurchaseForm onSuccess={() => {}} editingOperation={purchaseOp} />
          ) : view === "gasto" ? (
            <ExpenseForm onSuccess={() => {}} initialData={EXPENSE_CASH} />
          ) : (
            <SaleForm onSuccess={() => {}} editingOperation={saleOp} />
          )}
        </div>
      )}
    </main>
  )
}
