"use client"

/**
 * importador-gastos-transaccional (task 9.6): arnés de navegador real para la
 * pasada visual obligatoria (regla PO 2026-08-02) del diálogo de importación.
 *
 * Monta el diálogo REAL (`ExpenseImportDialog`, sin mocks de componente) y
 * sólo intercepta `window.fetch` hacia el backend con datos sintéticos
 * realistas — el mismo espíritu que los demás arneses de esta carpeta (sin
 * auth ni datos sembrados), adaptado a un componente que sí llama a hooks de
 * datos (usePaymentMethods/useCostCenters/useBankAccounts vía pythonClient,
 * useImportExpenses vía POST /expenses/import).
 *
 * `rpc_import_expenses` NO se reimplementa acá: el intercept de
 * `/expenses/import` aplica una heurística mínima (fila con
 * payment_method_name "Forma Inexistente" → error; kind cash → aviso
 * cash_not_posted) sólo para poder EJERCITAR los tres estados visuales
 * (ok/aviso/error) del paso 2 y llegar al paso 3 — el comportamiento real ya
 * está fijado por el gate SQL y por `test_expense_import.py`, no por este
 * arnés.
 */

import { useEffect, useState } from "react"
import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

const PAYMENT_METHODS = [
  { id: "pm-cash",     account_id: "acc-harness", name: "Efectivo",               kind: "cash",     is_active: true, sort_order: 1, created_at: "2026-01-01T00:00:00Z", bank_account_id: null },
  { id: "pm-transfer", account_id: "acc-harness", name: "Transferencia bancaria", kind: "transfer", is_active: true, sort_order: 2, created_at: "2026-01-01T00:00:00Z", bank_account_id: "ba-1" },
  { id: "pm-card",     account_id: "acc-harness", name: "Tarjeta",                kind: "card",     is_active: true, sort_order: 3, created_at: "2026-01-01T00:00:00Z", bank_account_id: null },
]
const COST_CENTERS = [
  { id: "cc-1", account_id: "acc-harness", name: "Administración", code: "ADM", is_active: true },
  { id: "cc-2", account_id: "acc-harness", name: "Depósito",       code: "DEP", is_active: true },
]
const BANK_ACCOUNTS = [
  { id: "ba-1", account_id: "acc-harness", name: "Banco Nación", bank_name: "Banco Nación", currency: "ARS", account_kind: "bank", is_active: true },
]

interface ImportRow {
  row_no: number
  description: string
  category: string
  amount: number
  date: string
  payment_method_name?: string | null
  branch_name?: string | null
  cost_center_name?: string | null
}

function simulateImport(rows: ImportRow[], dryRun: boolean) {
  const errors: Array<{ row: number; code: string; message: string }> = []
  const notices: Array<{ row: number; code: string; message: string }> = []

  for (const row of rows) {
    if (row.payment_method_name && row.payment_method_name.toLowerCase() === "forma inexistente") {
      errors.push({
        row: row.row_no, code: "P0404",
        message: `payment_method_name_not_found: la forma de pago "${row.payment_method_name}" no existe en el catálogo de la cuenta`,
      })
      continue
    }
    if (row.amount < 0) {
      errors.push({ row: row.row_no, code: "P0400", message: "amount_must_be_positive: el monto debe ser mayor a cero" })
      continue
    }
    const kind = !row.payment_method_name ? null
      : row.payment_method_name.toLowerCase().includes("efectivo") ? "cash"
      : "transfer"
    if (kind === "cash") {
      notices.push({ row: row.row_no, code: "cash_not_posted", message: "Este gasto en efectivo no impacta la caja — imputalo desde el formulario si querés que mueva el arqueo." })
    }
  }

  const committed = !dryRun && errors.length === 0
  return {
    committed,
    import_id: committed ? "import-harness-1" : null,
    imported: errors.length === 0 ? rows.length : 0,
    errors,
    notices,
    replayed: false,
    dry_run: dryRun,
  }
}

function installFetchIntercept() {
  const original = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url

    if (url.includes("/payment-methods")) {
      return new Response(JSON.stringify(PAYMENT_METHODS), { status: 200, headers: { "Content-Type": "application/json" } })
    }
    if (url.includes("/cost-centers")) {
      return new Response(JSON.stringify(COST_CENTERS), { status: 200, headers: { "Content-Type": "application/json" } })
    }
    if (url.includes("/bank-accounts")) {
      return new Response(JSON.stringify(BANK_ACCOUNTS), { status: 200, headers: { "Content-Type": "application/json" } })
    }
    if (url.includes("/expenses/import")) {
      const body = init?.body ? JSON.parse(String(init.body)) : {}
      const result = simulateImport(body.rows ?? [], Boolean(body.dry_run))
      return new Response(JSON.stringify(result), { status: 200, headers: { "Content-Type": "application/json" } })
    }
    // Cualquier otra cosa (auth de Supabase, telemetría, etc.): dejarla pasar.
    return original(input, init)
  }
  return () => { window.fetch = original }
}

export function ExpenseImportHarness() {
  const [open, setOpen] = useState(true)
  const [installed, setInstalled] = useState(false)

  useEffect(() => {
    const uninstall = installFetchIntercept()
    setInstalled(true)
    return uninstall
  }, [])

  return (
    <div className="min-h-svh bg-background p-6 flex flex-col gap-4">
      <h1 className="text-lg font-semibold text-foreground">
        Arnés — ExpenseImportDialog (importador-gastos-transaccional, task 9.6)
      </h1>
      <p className="text-sm text-muted-foreground max-w-xl">
        Catálogos sintéticos (3 formas de pago, 2 centros de costo, 1 cuenta
        bancaria) + intercept de <code>/expenses/import</code>. Subí un CSV con
        una fila &quot;Forma inexistente&quot; para ver el estado de error, una
        con &quot;Efectivo&quot; para el aviso <code>cash_not_posted</code>.
      </p>
      {!open && (
        <button
          className="self-start rounded-md bg-primary text-primary-foreground px-4 py-2 text-sm"
          onClick={() => setOpen(true)}
        >
          Reabrir diálogo
        </button>
      )}
      {installed && (
        <ExpenseImportDialog open={open} onOpenChange={setOpen} onSuccess={() => {}} />
      )}
    </div>
  )
}
