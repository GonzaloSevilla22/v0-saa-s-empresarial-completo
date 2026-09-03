"use client"

/**
 * /cobranzas — panel de deudores (cobranzas-panel, Etapa A del módulo).
 *
 * Superficie de LECTURA: responde "quién me debe y cuánto" de forma agregada.
 * El único botón que escribe (Cobrar) abre el RegisterPaymentForm existente
 * sin modificarlo (D8) — la invalidación de claves vive en los hooks de
 * mutación, no acá. El orden es del SERVIDOR (D3): con paginación server-side,
 * ordenar la página visible mentiría sobre quién debe más.
 *
 * D14: estructura de cabecera de CustomerAccountBalance, pero con tokens
 * semánticos (text-warning / bg-warning/10) — nada de text-yellow-400.
 * "El panel no promete mora": los rótulos dicen lo que el dato ES (días desde
 * el último cargo), y el pie declara que aún no hay vencimientos por cargo.
 */

import { useState } from "react"
import { useRouter } from "next/navigation"
import {
  ArrowDown,
  ArrowUp,
  ArrowUpDown,
  ChevronLeft,
  ChevronRight,
  HandCoins,
  Landmark,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { RegisterPaymentForm } from "@/components/customer-accounts/RegisterPaymentForm"
import {
  useReceivables,
  useReceivablesSummary,
  type ReceivablesSort,
  type ReceivablesSortDir,
} from "@/hooks/data/use-receivables"
import { formatMoney } from "@/lib/format"
import type { ReceivableRow } from "@/lib/types"

const PAGE_SIZE = 25

/** Dirección por defecto al activar cada criterio por primera vez. */
const DEFAULT_DIR: Record<ReceivablesSort, ReceivablesSortDir> = {
  balance: "desc",
  days_since_last_charge: "desc",
  days_since_last_payment: "desc",
  client_name: "asc",
}

const COLUMNS: { key: ReceivablesSort; label: string }[] = [
  { key: "client_name", label: "Cliente" },
  { key: "balance", label: "Saldo" },
  // Requirement "El panel no promete mora": el rótulo nombra lo que el dato
  // realmente es — nunca atraso ni antigüedad exigible.
  { key: "days_since_last_charge", label: "Último cargo" },
  { key: "days_since_last_payment", label: "Último cobro" },
]

function formatDays(days: number | null): string {
  if (days === null) return "—"
  if (days === 0) return "Hoy"
  return days === 1 ? "1 día" : `${days} días`
}

export default function CobranzasPage() {
  const router = useRouter()
  const [page, setPage] = useState(0)
  const [sort, setSort] = useState<ReceivablesSort>("balance")
  const [sortDir, setSortDir] = useState<ReceivablesSortDir>("desc")
  const [collecting, setCollecting] = useState<ReceivableRow | null>(null)

  const { data, isLoading, isError } = useReceivables({
    page,
    size: PAGE_SIZE,
    sort,
    sortDir,
  })
  const { data: summary, isLoading: loadingSummary } = useReceivablesSummary()

  const rows = data?.items ?? []
  const pages = data?.pages ?? 0
  const hasDebt = (summary?.totalReceivable ?? 0) > 0
  const debtorCount = summary?.debtorCount ?? 0

  function toggleSort(column: ReceivablesSort) {
    if (sort === column) {
      setSortDir(sortDir === "desc" ? "asc" : "desc")
    } else {
      setSort(column)
      setSortDir(DEFAULT_DIR[column])
    }
    setPage(0)
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Header ── */}
      <div className="min-w-0">
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Cobranzas</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Quién te debe, cuánto y desde cuándo — la deuda viva de tus cuentas corrientes.
        </p>
      </div>

      {/* ── Total por cobrar (estructura de CustomerAccountBalance, tokens D14) ── */}
      <div className="rounded-lg border border-border bg-card p-6">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <p className="text-sm text-muted-foreground">Total por cobrar</p>
            <p
              className={`text-3xl font-bold mt-2 tabular-nums ${
                hasDebt ? "text-warning" : "text-foreground"
              }`}
            >
              {loadingSummary ? "—" : formatMoney(summary?.totalReceivable ?? 0)}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              {loadingSummary
                ? "Cargando…"
                : hasDebt
                ? debtorCount === 1
                  ? "1 cliente le debe al negocio"
                  : `${debtorCount} clientes le deben al negocio`
                : "Sin deuda pendiente"}
            </p>
          </div>
          <div className={`rounded-full p-3 ${hasDebt ? "bg-warning/10" : "bg-accent"}`}>
            <HandCoins
              className={`h-5 w-5 ${hasDebt ? "text-warning" : "text-muted-foreground"}`}
            />
          </div>
        </div>
      </div>

      {/* ── Tabla de deudores ── */}
      <Card className="border-border bg-card min-w-0">
        <CardContent className="p-0">
          {isLoading ? (
            <div className="px-4 py-10 text-center text-sm text-muted-foreground">
              Cargando deudores…
            </div>
          ) : isError ? (
            <div className="px-4 py-10 text-center text-sm text-destructive">
              No se pudo cargar el panel de cobranzas. Probá de nuevo en un momento.
            </div>
          ) : rows.length === 0 ? (
            <div
              data-testid="receivables-empty"
              className="flex flex-col items-center gap-3 px-4 py-14 text-center text-muted-foreground"
            >
              <HandCoins className="h-10 w-10 opacity-30" />
              <p className="text-sm font-medium text-foreground">No hay deudas por cobrar</p>
              <p className="text-xs max-w-sm">
                Cuando registres una venta a cuenta corriente, el cliente y su saldo van a
                aparecer acá para que puedas seguir la cobranza.
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[640px] text-sm">
                <thead>
                  <tr className="border-b border-border text-left">
                    {COLUMNS.map((col) => (
                      <th key={col.key} className="px-4 py-3 font-medium text-muted-foreground">
                        <button
                          type="button"
                          onClick={() => toggleSort(col.key)}
                          className="inline-flex items-center gap-1 hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring rounded-sm"
                          aria-label={`Ordenar por ${col.label.toLowerCase()}`}
                        >
                          {col.label}
                          {sort === col.key ? (
                            sortDir === "desc" ? (
                              <ArrowDown className="h-3.5 w-3.5" />
                            ) : (
                              <ArrowUp className="h-3.5 w-3.5" />
                            )
                          ) : (
                            <ArrowUpDown className="h-3.5 w-3.5 opacity-40" />
                          )}
                        </button>
                      </th>
                    ))}
                    <th className="px-4 py-3">
                      <span className="sr-only">Acciones</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr
                      key={row.clientId}
                      data-testid={`receivable-row-${row.clientId}`}
                      className="border-b border-border/50 last:border-b-0 hover:bg-accent/20 transition-colors"
                    >
                      <td className="px-4 py-3 font-medium text-foreground max-w-[220px] truncate">
                        {row.clientName}
                      </td>
                      <td className="px-4 py-3 tabular-nums font-semibold text-foreground whitespace-nowrap">
                        {formatMoney(row.balance)}
                      </td>
                      <td className="px-4 py-3 tabular-nums text-muted-foreground whitespace-nowrap">
                        {formatDays(row.daysSinceLastCharge)}
                      </td>
                      <td
                        className="px-4 py-3 tabular-nums text-muted-foreground whitespace-nowrap"
                        title={row.lastPaymentDate ?? undefined}
                      >
                        {formatDays(row.daysSinceLastPayment)}
                      </td>
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-1 justify-end">
                          <Button
                            variant="outline"
                            size="sm"
                            className="h-7"
                            data-testid={`receivable-collect-${row.clientId}`}
                            onClick={() => setCollecting(row)}
                          >
                            Cobrar
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            className="h-7 w-7 text-muted-foreground hover:text-primary"
                            data-testid={`receivable-account-${row.clientId}`}
                            aria-label={`Cuenta corriente de ${row.clientName}`}
                            onClick={(e) => {
                              e.stopPropagation()
                              router.push(`/clientes/${row.clientId}/cuenta`)
                            }}
                          >
                            <Landmark className="h-3.5 w-3.5" />
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      {/* ── Paginación estándar ── */}
      {pages > 1 && (
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs text-muted-foreground tabular-nums">
            Página {page + 1} de {pages} · {data?.total ?? 0} deudores
          </span>
          <div className="flex items-center gap-1">
            <Button
              variant="outline"
              size="sm"
              disabled={page === 0}
              onClick={() => setPage(page - 1)}
              aria-label="Página anterior"
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={page + 1 >= pages}
              onClick={() => setPage(page + 1)}
              aria-label="Página siguiente"
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      )}

      {/* ── Requirement "El panel no promete mora" ── */}
      <p data-testid="receivables-disclaimer" className="text-xs text-muted-foreground">
        El sistema aún no registra vencimientos por cargo: “Último cargo” y “Último cobro”
        cuentan los días desde el movimiento más reciente de cada cuenta, no indican deuda
        exigible. Un “—” significa que ese tipo de movimiento nunca se registró.
      </p>

      {/* ── Cobrar: el formulario EXISTENTE, sin props nuevas (D8) ── */}
      <Dialog open={collecting !== null} onOpenChange={(open) => !open && setCollecting(null)}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              Registrar cobro{collecting ? ` — ${collecting.clientName}` : ""}
            </DialogTitle>
          </DialogHeader>
          {collecting && (
            <RegisterPaymentForm
              clientId={collecting.clientId}
              onSuccess={() => setCollecting(null)}
            />
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}
