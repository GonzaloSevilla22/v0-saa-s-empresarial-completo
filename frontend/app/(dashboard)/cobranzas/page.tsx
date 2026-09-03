"use client"

/**
 * /cobranzas — panel de deudores y acreedores (cobranzas-panel Etapa A +
 * cobranzas-vencimientos Etapa B).
 *
 * Etapa B: la palabra "vencido" pasó a estar respaldada por un dato —
 * columna de importe vencido y estado EN TEXTO por fila (D15: nunca sólo
 * color), filtro por tramo resuelto en el SERVIDOR (nunca sobre la página
 * visible), pestaña espejo "Por pagar" (OQ-6: misma pantalla, no ruta
 * propia), recordatorio de deuda por WhatsApp (D12, deep-link con mensaje
 * puro de lib/debt-reminder) y el aviso de "sin plazos configurados" con
 * acceso a Configuración — en reemplazo de la nota vieja de la Etapa A
 * (requirement REMOVED: el sistema ahora SÍ registra vencimientos).
 *
 * El deudor sin vencimiento se presenta como tal — jamás como al día (D5).
 */

import { useState } from "react"
import Link from "next/link"
import { useRouter } from "next/navigation"
import {
  ArrowDown,
  ArrowUp,
  ArrowUpDown,
  ChevronLeft,
  ChevronRight,
  HandCoins,
  Landmark,
  MessageCircle,
  Settings2,
  Truck,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { RegisterPaymentForm } from "@/components/customer-accounts/RegisterPaymentForm"
import { RegisterPaymentMadeForm } from "@/components/supplier-accounts/RegisterPaymentMadeForm"
import {
  useReceivables,
  useReceivablesSummary,
  type ReceivablesSort,
  type ReceivablesSortDir,
} from "@/hooks/data/use-receivables"
import {
  usePayables,
  usePayablesSummary,
  type PayablesSort,
} from "@/hooks/data/use-payables"
import { useCollectionSettings } from "@/hooks/data/use-collection-settings"
import {
  AGING_FILTER_LABELS,
  formatDueStatus,
  type AgingBucketFilter,
} from "@/lib/receivables-aging"
import { buildDebtReminderUrl } from "@/lib/debt-reminder"
import { formatMoney } from "@/lib/format"
import type { PayableRow, ReceivableRow } from "@/lib/types"

const PAGE_SIZE = 25

/** Dirección por defecto al activar cada criterio por primera vez. */
const DEFAULT_DIR: Record<ReceivablesSort, ReceivablesSortDir> = {
  balance: "desc",
  days_since_last_charge: "desc",
  days_since_last_payment: "desc",
  client_name: "asc",
}

const RECEIVABLE_COLUMNS: { key: ReceivablesSort; label: string }[] = [
  { key: "client_name", label: "Cliente" },
  { key: "balance", label: "Saldo" },
  { key: "days_since_last_charge", label: "Último cargo" },
  { key: "days_since_last_payment", label: "Último cobro" },
]

const PAYABLE_COLUMNS: { key: PayablesSort; label: string }[] = [
  { key: "supplier_name", label: "Proveedor" },
  { key: "balance", label: "Saldo" },
  { key: "days_since_last_charge", label: "Último cargo" },
  { key: "days_since_last_payment", label: "Último pago" },
]

/** Orden de los filtros en la barra — "Todos" es la ausencia de filtro. */
const FILTERS: (AgingBucketFilter | null)[] = [
  null,
  "overdue",
  "current",
  "overdue_1_30",
  "overdue_31_60",
  "overdue_60_plus",
  "no_due_date",
]

function formatDays(days: number | null): string {
  if (days === null) return "—"
  if (days === 0) return "Hoy"
  return days === 1 ? "1 día" : `${days} días`
}

/** Clase del estado por severidad — el TEXTO es el canal principal (D15). */
function dueStatusClass(row: { overdueTotal: number; amountCurrent: number }): string {
  if (row.overdueTotal > 0) return "text-destructive"
  if (row.amountCurrent > 0) return "text-foreground"
  return "text-muted-foreground"
}

export default function CobranzasPage() {
  const router = useRouter()
  const [tab, setTab] = useState<"receivables" | "payables">("receivables")
  const [bucket, setBucket] = useState<AgingBucketFilter | null>(null)

  // ── Por cobrar ──────────────────────────────────────────────────────────
  const [page, setPage] = useState(0)
  const [sort, setSort] = useState<ReceivablesSort>("balance")
  const [sortDir, setSortDir] = useState<ReceivablesSortDir>("desc")
  const [collecting, setCollecting] = useState<ReceivableRow | null>(null)

  const { data, isLoading, isError } = useReceivables({
    page,
    size: PAGE_SIZE,
    sort,
    sortDir,
    bucket,
  })
  const { data: summary, isLoading: loadingSummary } = useReceivablesSummary()

  // ── Por pagar (espejo, misma pantalla — OQ-6) ───────────────────────────
  const [payPage, setPayPage] = useState(0)
  const [paying, setPaying] = useState<PayableRow | null>(null)
  const { data: payData, isLoading: loadingPay, isError: errorPay } = usePayables({
    page: payPage,
    size: PAGE_SIZE,
    bucket,
  })
  const { data: paySummary } = usePayablesSummary()

  const { data: settings } = useCollectionSettings()
  const noTermsConfigured = settings !== undefined && settings.defaultPaymentTermsDays === null

  const rows = data?.items ?? []
  const pages = data?.pages ?? 0
  const hasDebt = (summary?.totalReceivable ?? 0) > 0
  const debtorCount = summary?.debtorCount ?? 0
  const payRows = payData?.items ?? []
  const payPages = payData?.pages ?? 0

  function toggleSort(column: ReceivablesSort) {
    if (sort === column) {
      setSortDir(sortDir === "desc" ? "asc" : "desc")
    } else {
      setSort(column)
      setSortDir(DEFAULT_DIR[column])
    }
    setPage(0)
  }

  function selectBucket(next: AgingBucketFilter | null) {
    setBucket(next)
    setPage(0)
    setPayPage(0)
  }

  function remind(row: ReceivableRow) {
    // D12: deep-link consciente — el usuario ve el texto antes de enviar.
    // Sin teléfono utilizable, buildWhatsAppUrl cae al selector de contactos.
    window.open(buildDebtReminderUrl(row), "_blank", "noopener,noreferrer")
  }

  const summaryCards = (
    <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div className="rounded-lg border border-border bg-card p-6">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <p className="text-sm text-muted-foreground">
              {tab === "receivables" ? "Total por cobrar" : "Total por pagar"}
            </p>
            <p
              className={`text-3xl font-bold mt-2 tabular-nums ${
                (tab === "receivables" ? hasDebt : (paySummary?.totalPayable ?? 0) > 0)
                  ? "text-warning"
                  : "text-foreground"
              }`}
            >
              {tab === "receivables"
                ? loadingSummary
                  ? "—"
                  : formatMoney(summary?.totalReceivable ?? 0)
                : formatMoney(paySummary?.totalPayable ?? 0)}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              {tab === "receivables"
                ? loadingSummary
                  ? "Cargando…"
                  : hasDebt
                  ? debtorCount === 1
                    ? "1 cliente le debe al negocio"
                    : `${debtorCount} clientes le deben al negocio`
                  : "Sin deuda pendiente"
                : (paySummary?.creditorCount ?? 0) === 1
                ? "1 proveedor por pagar"
                : `${paySummary?.creditorCount ?? 0} proveedores por pagar`}
            </p>
          </div>
          <div
            className={`rounded-full p-3 ${
              (tab === "receivables" ? hasDebt : (paySummary?.totalPayable ?? 0) > 0)
                ? "bg-warning/10"
                : "bg-accent"
            }`}
          >
            <HandCoins
              className={`h-5 w-5 ${
                (tab === "receivables" ? hasDebt : (paySummary?.totalPayable ?? 0) > 0)
                  ? "text-warning"
                  : "text-muted-foreground"
              }`}
            />
          </div>
        </div>
      </div>

      {/* Total vencido — la primera lectura distingue la deuda que reclama
          acción de la que sólo está pendiente. */}
      <div className="rounded-lg border border-border bg-card p-6">
        <div className="flex items-start justify-between gap-4">
          <div className="min-w-0">
            <p className="text-sm text-muted-foreground">Total vencido</p>
            <p
              className={`text-3xl font-bold mt-2 tabular-nums ${
                (tab === "receivables"
                  ? summary?.overdueTotal ?? 0
                  : paySummary?.overdueTotal ?? 0) > 0
                  ? "text-destructive"
                  : "text-foreground"
              }`}
            >
              {formatMoney(
                tab === "receivables"
                  ? summary?.overdueTotal ?? 0
                  : paySummary?.overdueTotal ?? 0,
              )}
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              {(tab === "receivables"
                ? summary?.overdueTotal ?? 0
                : paySummary?.overdueTotal ?? 0) > 0
                ? "Deuda con vencimiento cumplido"
                : "Nada vencido por ahora"}
            </p>
          </div>
        </div>
      </div>
    </div>
  )

  const filterBar = (
    <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filtrar por estado de vencimiento">
      {FILTERS.map((f) => (
        <Button
          key={f ?? "all"}
          type="button"
          variant={bucket === f ? "default" : "outline"}
          size="sm"
          className="h-7 text-xs"
          data-testid={`aging-filter-${f ?? "all"}`}
          aria-pressed={bucket === f}
          onClick={() => selectBucket(f)}
        >
          {f === null ? "Todos" : AGING_FILTER_LABELS[f]}
        </Button>
      ))}
    </div>
  )

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Header ── */}
      <div className="min-w-0">
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Cobranzas</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Quién te debe, cuánto, desde cuándo y qué venció — y la otra cara: a quién le debés.
        </p>
      </div>

      <Tabs
        value={tab}
        onValueChange={(v) => setTab(v as "receivables" | "payables")}
        className="w-full"
      >
        <TabsList className="grid w-full max-w-sm grid-cols-2">
          <TabsTrigger value="receivables" className="flex items-center gap-1.5">
            <HandCoins className="h-3.5 w-3.5" />
            Por cobrar
          </TabsTrigger>
          <TabsTrigger value="payables" className="flex items-center gap-1.5">
            <Truck className="h-3.5 w-3.5" />
            Por pagar
          </TabsTrigger>
        </TabsList>

        <div className="mt-4 flex flex-col gap-4">
          {summaryCards}
          {filterBar}

          {/* ── Aviso "sin plazos configurados" (reemplaza la nota vieja) ── */}
          {noTermsConfigured && (
            <p
              data-testid="no-terms-hint"
              className="text-xs text-muted-foreground rounded-md border border-border bg-accent/20 px-3 py-2"
            >
              Todavía no configuraste un plazo de pago: los cargos nuevos nacen sin
              vencimiento y nada se marca como vencido.{" "}
              <Link
                href="/configuracion?tab=cobranzas"
                className="inline-flex items-center gap-1 text-primary underline-offset-2 hover:underline"
              >
                <Settings2 className="h-3 w-3" />
                Configurar plazo de pago
              </Link>
            </p>
          )}

          {/* ═════════════════ POR COBRAR ═════════════════ */}
          <TabsContent value="receivables" className="m-0 flex flex-col gap-4">
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
                    <p className="text-sm font-medium text-foreground">
                      {bucket ? "Nada en este tramo" : "No hay deudas por cobrar"}
                    </p>
                    <p className="text-xs max-w-sm">
                      {bucket
                        ? "Ningún deudor tiene importe abierto en el tramo elegido."
                        : "Cuando registres una venta a cuenta corriente, el cliente y su saldo van a aparecer acá para que puedas seguir la cobranza."}
                    </p>
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full min-w-[860px] text-sm">
                      <thead>
                        <tr className="border-b border-border text-left">
                          {RECEIVABLE_COLUMNS.slice(0, 2).map((col) => (
                            <th key={col.key} className="px-4 py-3 font-medium text-muted-foreground">
                              <SortButton
                                label={col.label}
                                active={sort === col.key}
                                dir={sortDir}
                                onClick={() => toggleSort(col.key)}
                              />
                            </th>
                          ))}
                          <th className="px-4 py-3 font-medium text-muted-foreground">Vencido</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Estado</th>
                          {RECEIVABLE_COLUMNS.slice(2).map((col) => (
                            <th key={col.key} className="px-4 py-3 font-medium text-muted-foreground">
                              <SortButton
                                label={col.label}
                                active={sort === col.key}
                                dir={sortDir}
                                onClick={() => toggleSort(col.key)}
                              />
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
                            <td
                              className={`px-4 py-3 tabular-nums whitespace-nowrap ${
                                row.overdueTotal > 0
                                  ? "font-semibold text-destructive"
                                  : "text-muted-foreground"
                              }`}
                            >
                              {row.overdueTotal > 0 ? formatMoney(row.overdueTotal) : "—"}
                            </td>
                            <td
                              className={`px-4 py-3 text-xs whitespace-nowrap ${dueStatusClass(row)}`}
                            >
                              {formatDueStatus(row)}
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
                                  data-testid={`receivable-remind-${row.clientId}`}
                                  aria-label={`Recordar deuda a ${row.clientName} por WhatsApp`}
                                  title="Recordar deuda por WhatsApp"
                                  onClick={() => remind(row)}
                                >
                                  <MessageCircle className="h-3.5 w-3.5" />
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

            {pages > 1 && (
              <Pagination
                page={page}
                pages={pages}
                total={data?.total ?? 0}
                noun="deudores"
                onPrev={() => setPage(page - 1)}
                onNext={() => setPage(page + 1)}
              />
            )}
          </TabsContent>

          {/* ═════════════════ POR PAGAR (espejo) ═════════════════ */}
          <TabsContent value="payables" className="m-0 flex flex-col gap-4">
            <Card className="border-border bg-card min-w-0">
              <CardContent className="p-0">
                {loadingPay ? (
                  <div className="px-4 py-10 text-center text-sm text-muted-foreground">
                    Cargando cuentas por pagar…
                  </div>
                ) : errorPay ? (
                  <div className="px-4 py-10 text-center text-sm text-destructive">
                    No se pudo cargar la deuda con proveedores. Probá de nuevo en un momento.
                  </div>
                ) : payRows.length === 0 ? (
                  <div
                    data-testid="payables-empty"
                    className="flex flex-col items-center gap-3 px-4 py-14 text-center text-muted-foreground"
                  >
                    <Truck className="h-10 w-10 opacity-30" />
                    <p className="text-sm font-medium text-foreground">
                      {bucket ? "Nada en este tramo" : "No tenés deudas con proveedores"}
                    </p>
                    <p className="text-xs max-w-sm">
                      {bucket
                        ? "Ningún proveedor tiene importe abierto en el tramo elegido."
                        : "Cuando registres una compra a cuenta corriente, el proveedor y lo que le debés van a aparecer acá."}
                    </p>
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full min-w-[860px] text-sm">
                      <thead>
                        <tr className="border-b border-border text-left">
                          <th className="px-4 py-3 font-medium text-muted-foreground">Proveedor</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Saldo</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Vencido</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Estado</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Último cargo</th>
                          <th className="px-4 py-3 font-medium text-muted-foreground">Último pago</th>
                          <th className="px-4 py-3">
                            <span className="sr-only">Acciones</span>
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {payRows.map((row) => (
                          <tr
                            key={row.supplierId}
                            data-testid={`payable-row-${row.supplierId}`}
                            className="border-b border-border/50 last:border-b-0 hover:bg-accent/20 transition-colors"
                          >
                            <td className="px-4 py-3 font-medium text-foreground max-w-[220px] truncate">
                              {row.supplierName}
                            </td>
                            <td className="px-4 py-3 tabular-nums font-semibold text-foreground whitespace-nowrap">
                              {formatMoney(row.balance)}
                            </td>
                            <td
                              className={`px-4 py-3 tabular-nums whitespace-nowrap ${
                                row.overdueTotal > 0
                                  ? "font-semibold text-destructive"
                                  : "text-muted-foreground"
                              }`}
                            >
                              {row.overdueTotal > 0 ? formatMoney(row.overdueTotal) : "—"}
                            </td>
                            <td
                              className={`px-4 py-3 text-xs whitespace-nowrap ${dueStatusClass(row)}`}
                            >
                              {formatDueStatus(row)}
                            </td>
                            <td className="px-4 py-3 tabular-nums text-muted-foreground whitespace-nowrap">
                              {formatDays(row.daysSinceLastCharge)}
                            </td>
                            <td className="px-4 py-3 tabular-nums text-muted-foreground whitespace-nowrap">
                              {formatDays(row.daysSinceLastPayment)}
                            </td>
                            <td className="px-4 py-3">
                              <div className="flex items-center gap-1 justify-end">
                                <Button
                                  variant="outline"
                                  size="sm"
                                  className="h-7"
                                  data-testid={`payable-pay-${row.supplierId}`}
                                  onClick={() => setPaying(row)}
                                >
                                  Pagar
                                </Button>
                                <Button
                                  variant="ghost"
                                  size="icon"
                                  className="h-7 w-7 text-muted-foreground hover:text-primary"
                                  data-testid={`payable-account-${row.supplierId}`}
                                  aria-label={`Cuenta corriente de ${row.supplierName}`}
                                  onClick={() =>
                                    router.push(`/proveedores/${row.supplierId}/cuenta`)
                                  }
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

            {payPages > 1 && (
              <Pagination
                page={payPage}
                pages={payPages}
                total={payData?.total ?? 0}
                noun="proveedores"
                onPrev={() => setPayPage(payPage - 1)}
                onNext={() => setPayPage(payPage + 1)}
              />
            )}
          </TabsContent>
        </div>
      </Tabs>

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

      {/* ── Pagar: el formulario EXISTENTE del lado proveedor ── */}
      <Dialog open={paying !== null} onOpenChange={(open) => !open && setPaying(null)}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">
              Registrar pago{paying ? ` — ${paying.supplierName}` : ""}
            </DialogTitle>
          </DialogHeader>
          {paying && (
            <RegisterPaymentMadeForm
              supplierId={paying.supplierId}
              onSuccess={() => setPaying(null)}
            />
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}

// ── Piezas compartidas ────────────────────────────────────────────────────────

function SortButton({
  label,
  active,
  dir,
  onClick,
}: {
  label: string
  active: boolean
  dir: ReceivablesSortDir
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="inline-flex items-center gap-1 hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring rounded-sm"
      aria-label={`Ordenar por ${label.toLowerCase()}`}
    >
      {label}
      {active ? (
        dir === "desc" ? (
          <ArrowDown className="h-3.5 w-3.5" />
        ) : (
          <ArrowUp className="h-3.5 w-3.5" />
        )
      ) : (
        <ArrowUpDown className="h-3.5 w-3.5 opacity-40" />
      )}
    </button>
  )
}

function Pagination({
  page,
  pages,
  total,
  noun,
  onPrev,
  onNext,
}: {
  page: number
  pages: number
  total: number
  noun: string
  onPrev: () => void
  onNext: () => void
}) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-xs text-muted-foreground tabular-nums">
        Página {page + 1} de {pages} · {total} {noun}
      </span>
      <div className="flex items-center gap-1">
        <Button
          variant="outline"
          size="sm"
          disabled={page === 0}
          onClick={onPrev}
          aria-label="Página anterior"
        >
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <Button
          variant="outline"
          size="sm"
          disabled={page + 1 >= pages}
          onClick={onNext}
          aria-label="Página siguiente"
        >
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>
    </div>
  )
}
