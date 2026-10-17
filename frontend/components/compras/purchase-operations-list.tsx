"use client"

/**
 * PurchaseOperationsList — paginated version.
 * Mirror of SaleOperationsList — see that file for the data-flow rationale.
 */

import { useState, useMemo, useCallback } from "react"
import { Button }   from "@/components/ui/button"
import { Input }    from "@/components/ui/input"
import { Label }    from "@/components/ui/label"
import { Badge }    from "@/components/ui/badge"
import { PaymentMethodBadge } from "@/components/payment-methods/PaymentMethodBadge"
import { UNASSIGNED_PAYMENT_METHOD_LABEL } from "@/lib/payment-method-meta"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { PaginationBar } from "@/components/ui/pagination-bar"
import { groupPurchasesByOperation, type PurchaseOperation } from "@/lib/group-operations"
import { getDeleteCompensation } from "@/lib/delete-compensation"
import { DeleteOperationDialog } from "@/components/shared/delete-operation-dialog"
import { SourceDocumentBadge } from "@/components/ventas/SourceDocumentBadge"
import { formatDeliveryNoteNumber } from "@/lib/internal-document-number"
import { exportToCSV } from "@/lib/excel"
import { formatMoney, formatUnitPrice, formatDate } from "@/lib/format"
import { formatQuantity } from "@/lib/format-unit"
import { resolveUnit } from "@/lib/unit-utils"
import type { Purchase, UnitOfMeasure } from "@/lib/types"
import type { PaginationMeta, PageSizeOption } from "@/lib/pagination-utils"
import {
  Plus, Pencil, ChevronDown, ChevronRight,
  ShoppingCart, Search, PackageOpen, Download, CalendarDays, X, Loader2,
  Lock,
} from "lucide-react"
import { toast } from "sonner"
import { humanizeOperationError } from "@/lib/operation-errors"
import { CostCenterSelect } from "@/components/cost-centers/CostCenterSelect"
import { PaymentMethodSelect } from "@/components/payment-methods/PaymentMethodSelect"

// pagos-cableados-restantes (D6, task 9.3/12.4): espejo del motivo de
// sale-operations-list.tsx — el guard real vive en el backend (P0423), esto
// sólo evita que el usuario llegue hasta ese error.
// pos-banco-movimientos (D8): is_payment_locked ahora también se dispara por
// un bank_movement posteado (egreso) — mensaje actualizado.
// compras-proveedor-cuenta-corriente (D9/task 13.3): el texto anterior decía
// "Emití una nota de crédito y registrá una compra nueva" — copiado del lado
// venta, donde SÍ existe nota de crédito. Las compras no la tienen (D8 del
// design): el camino de corrección real es borrar la operación
// (rpc_delete_purchase_operation compensa cta cte + banco + stock) y
// recargarla. El motivo ahora también nombra explícitamente que el cargo es
// del PROVEEDOR (antes era genérico y no distinguía de qué cuenta).
// caja-compras-cobranzas (D8, task 12.4): suma la caja al motivo — antes era
// inalcanzable (ninguna compra tenía movimiento de caja), ahora la compra
// con opt-in tildado también puede caer en este bloqueo.
const PAYMENT_LOCKED_REASON =
  "No editable: esta operación ya tiene un cargo de cuenta corriente del proveedor, un movimiento bancario o un movimiento de caja registrado. Para corregirla, borrá esta compra (revierte el cargo, la caja y el banco, y repone el stock) y volvé a cargarla."

// remitos-compra (tanda B, D9): una compra nacida de un remito no se edita — el stock ya
// entró con el remito y el editor, que siempre reemplaza líneas (REVERSE+APPLY), lo restaría
// y lo sumaría de nuevo. El servidor lo rechaza con P0423 `delivery_note_purchase_locked`
// ANTES de los tres P0423 de dinero, así que el motivo va primero (espejo del lado venta). El
// token viene del servidor (`edit_locked_reason`); uno que no conocemos también bloquea
// (fail-closed): la UI no adivina «se puede».
const DELIVERY_NOTE_PURCHASE_LOCKED = "delivery_note_purchase_locked"
const UNKNOWN_EDIT_LOCK_REASON = "No editable: el servidor no permite editar esta operación."

function editLockedReasonText(token: string | null | undefined, remitoLabel: string | null): string | null {
  if (!token) return null
  if (token !== DELIVERY_NOTE_PURCHASE_LOCKED) return UNKNOWN_EDIT_LOCK_REASON
  const origen = remitoLabel ? `del remito ${remitoLabel}` : "de un remito"
  return `No editable: la compra nació ${origen}. Para corregirla, eliminá la compra, editá el remito y volvé a convertirlo.`
}

// remitos-compra (D9): borrar la compra de un remito reabre el remito y lo deja anulable, así que
// exige el mismo rol que anularlo (administrador o dueño) y una sucursal de remito viva. El
// servidor lo decide (P0403 delivery_note_purchase_delete_forbidden / P0422 delivery_note_branch_
// inactive); el listado lo anticipa para no llegar al error. Rol primero, igual que la RPC.
function sourceNoteDeleteBlockedReason(
  op: { sourceDeliveryNoteId?: string | null; sourceDeliveryNoteBranchActive?: boolean | null },
  remitoLabel: string | null,
  canVoidDeliveryNote: boolean,
): string | null {
  if (!op.sourceDeliveryNoteId) return null
  const remito = remitoLabel ? `el remito ${remitoLabel}` : "el remito"
  if (!canVoidDeliveryNote) {
    return `Borrar esta compra reabre ${remito}: requiere administrador o dueño.`
  }
  if (op.sourceDeliveryNoteBranchActive === false) {
    return "La sucursal del remito está desactivada o cerrada — reactivala antes de eliminar la compra."
  }
  return null
}

interface PurchaseOperationsListProps {
  purchases:       Purchase[]
  meta:            PaginationMeta
  loading:         boolean
  error:           string | null
  dateFrom:        string
  setDateFrom:     (v: string) => void
  dateTo:          string
  setDateTo:       (v: string) => void
  /** cost-center-surface: filtro por centro de costo de la operación. */
  costCenterId:    string | null
  setCostCenterId: (v: string | null) => void
  /** metodos-pago-operaciones: filtro por forma de pago de la operación. */
  paymentMethodId:    string | null
  setPaymentMethodId: (v: string | null) => void
  clearFilters:    () => void
  onPageChange:    (page: number) => void
  onPageSizeChange:(size: PageSizeOption) => void
  onAdd?:          () => void
  onDeleteOperation:(op: PurchaseOperation) => Promise<void>
  onEditOperation?: (op: PurchaseOperation) => void
  onRefetch:       () => void
  /**
   * remitos-compra (D9): el usuario puede anular un remito de compra (`CAN_VOID_DELIVERY_NOTE`).
   * Borrar la compra de un remito lo reabre y lo deja anulable, así que sin este rol el borrado de
   * esas compras queda deshabilitado con su motivo. Default `true`: sin la prop el listado no bloquea
   * por rol —el servidor sigue siendo la autoridad— y las compras directas no dependen de ella.
   */
  canVoidDeliveryNote?: boolean
  /**
   * multiusuario-operativo tanda B (D9, OQ-4 b): ¿se ofrece «Editar» y «Eliminar» sobre esta operación? La
   * página lo decide con la capacidad del dominio y la regla de autor (`canModifyDocument`): sin la
   * capacidad, o sobre lo de otro miembro sin ser dueño ni administrador, las dos acciones NO se ofrecen
   * (no quedan deshabilitadas: no hay nada que explicar, el usuario no puede hacerlas). Es sólo informativo
   * —la autoridad es la RPC (P0403)—. Default: todas, para que sin la prop nada cambie.
   */
  canModifyOperation?: (op: PurchaseOperation) => boolean
  /**
   * ventas-unidades-conversion (cuarta revisión, D-F′): unidades de medida por
   * id, para mostrar la cantidad con el símbolo de SU línea ("450 g") y
   * exportarlo en el CSV. La página lo pasa desde useUnitsOfMeasure (el
   * listado no hace fetch propio); sin él la cantidad sale sin símbolo — nunca
   * se inventa una unidad.
   */
  unitsById?:      Map<string, UnitOfMeasure>
}

export function PurchaseOperationsList({
  purchases, meta, loading, error,
  dateFrom, setDateFrom, dateTo, setDateTo,
  costCenterId, setCostCenterId,
  paymentMethodId, setPaymentMethodId, clearFilters,
  onPageChange, onPageSizeChange,
  onAdd, onDeleteOperation, onEditOperation, onRefetch,
  canVoidDeliveryNote = true,
  canModifyOperation,
  unitsById,
}: PurchaseOperationsListProps) {
  const unitSymbolFor = useCallback(
    (unitId?: string | null) => (unitsById ? resolveUnit(unitId, unitsById)?.symbol : undefined),
    [unitsById],
  )
  const [search,      setSearch]      = useState("")
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [deletingKey, setDeletingKey] = useState<string | null>(null)

  const isDateFilterActive = !!(dateFrom || dateTo)

  const operations = useMemo(() => groupPurchasesByOperation(purchases), [purchases])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return operations
    return operations.filter((op) =>
      op.items.some((i) => i.productName.toLowerCase().includes(q)),
    )
  }, [operations, search])

  const grandTotal = useMemo(
    () => filtered.reduce((sum, op) => sum + op.total, 0),
    [filtered],
  )

  function handleExport() {
    // G15 (H24): forma de pago y proveedor son los dos badges con los que el
    // usuario filtra en pantalla — sin ellos, quien exporta para conciliar en
    // una planilla los pierde. Mismos literales de fallback que los badges.
    const rows = filtered.flatMap((op) =>
      op.items.map((item) => ({
        date: item.date, productName: item.productName,
        quantity: item.quantity, unit: unitSymbolFor(item.unitId) ?? "",
        unitCost: item.unitCost,
        total: item.total, description: item.description ?? "",
        paymentMethodName:
          op.items[0]?.paymentMethodName ?? UNASSIGNED_PAYMENT_METHOD_LABEL,
        supplierName: op.supplierName ?? "Sin proveedor",
        operationId: op.operationId ?? "",
      })),
    )
    exportToCSV(rows, [
      { key: "date",              header: "Fecha"         },
      { key: "productName",       header: "Producto"      },
      { key: "quantity",          header: "Cantidad"      },
      { key: "unit",              header: "Unidad"        },
      { key: "unitCost",          header: "Costo unit."   },
      { key: "total",             header: "Total"         },
      { key: "paymentMethodName", header: "Forma de pago" },
      { key: "supplierName",      header: "Proveedor"     },
      { key: "description",       header: "Descripción"   },
      { key: "operationId",       header: "ID Operación"  },
    ], "compras")
    toast.success(`Exportadas ${rows.length} filas`)
  }

  const handleDelete = useCallback(
    async (op: PurchaseOperation) => {
      setDeletingKey(op.key)
      try {
        await onDeleteOperation(op)
        toast.success(op.isGrouped ? `${op.items.length} registros eliminados` : "Compra eliminada")
        onRefetch()
      } catch (err: any) {
        // multiusuario-operativo tanda B (D9): el rechazo de rol / autor de la base (P0401, P0403) se traduce a lo que el
        // usuario puede hacer, no se muestra el token crudo. Lo que el mapa no reconoce pasa tal cual.
        toast.error(humanizeOperationError(err.message || "Error al eliminar").message)
      } finally {
        setDeletingKey(null)
      }
    },
    [onDeleteOperation, onRefetch],
  )

  const toggleExpand = useCallback((key: string) => {
    setExpandedKey((prev) => (prev === key ? null : key))
  }, [])

  return (
    <div className="flex flex-col gap-4">
      {/* Controls Bar */}
      {/* tablet-filtros-cta: lg:flex-wrap en el contenedor + flex-wrap en el
          grupo de filtros — a 1024px con el riel del sidebar expandido, los
          4 filtros no entran en una sola fila y empujaban el CTA fuera del
          viewport (la barra de ACCIONES ya wrappeaba desde qa-integral-modulos
          G2, la de FILTROS no). */}
      <div className="flex flex-col gap-3 lg:flex-row lg:flex-wrap lg:items-center lg:justify-between" data-testid="filters-bar">
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3" data-testid="filters-group">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar en esta página..."
              className="pl-9 bg-background border-border text-foreground"
            />
          </div>

          <Popover>
            <PopoverTrigger asChild>
              <Button
                variant="outline" size="sm"
                className={`shrink-0 border-border text-foreground ${isDateFilterActive ? "border-primary text-primary" : ""}`}
              >
                <CalendarDays className="h-4 w-4 mr-1" />
                Filtrar fechas
                {isDateFilterActive && (
                  <span className="ml-1.5 flex h-4 w-4 items-center justify-center rounded-full bg-primary text-[10px] text-primary-foreground">1</span>
                )}
              </Button>
            </PopoverTrigger>
            <PopoverContent className="w-72 bg-popover border-border" align="start">
              <div className="flex flex-col gap-3">
                <p className="text-sm font-medium text-foreground">Rango de fechas</p>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Desde</Label>
                  <Input type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                <div className="flex flex-col gap-2">
                  <Label className="text-xs text-muted-foreground">Hasta</Label>
                  <Input type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)}
                    className="bg-background border-border text-foreground" />
                </div>
                {isDateFilterActive && (
                  <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={clearFilters}>
                    <X className="h-3 w-3 mr-1" />Limpiar filtro
                  </Button>
                )}
              </div>
            </PopoverContent>
          </Popover>

          {/* cost-center-surface: filtro por centro de costo (server-side) */}
          <div className="w-full sm:w-56">
            <CostCenterSelect
              value={costCenterId}
              onChange={setCostCenterId}
              placeholder="Todos los centros"
              showLabel={false}
              includeInactive
              className={`bg-background border-border text-foreground ${costCenterId ? "border-primary text-primary" : ""}`}
            />
          </div>

          {/* metodos-pago-operaciones: filtro por forma de pago (server-side) */}
          <div className="w-full sm:w-56">
            <PaymentMethodSelect
              value={paymentMethodId}
              onChange={setPaymentMethodId}
              placeholder="Todas las formas de pago"
              showLabel={false}
              includeInactive
              context="purchase"
              showSupportText={false}
              className={`bg-background border-border text-foreground ${paymentMethodId ? "border-primary text-primary" : ""}`}
            />
          </div>
        </div>

        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-muted-foreground tabular-nums mr-auto lg:mr-0">
            {loading
              ? <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Cargando...</span>
              : filtered.length === 1 ? "1 operación" : `${filtered.length} operaciones`
            }
          </span>
          <Button variant="outline" size="sm" className="border-border text-foreground" onClick={handleExport}>
            <Download className="h-4 w-4 mr-1" />Exportar
          </Button>
          {onAdd && (
            <Button onClick={onAdd} size="sm" className="gap-2">
              <Plus className="h-4 w-4" />Nueva compra
            </Button>
          )}
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Table */}
      <div className="rounded-xl border border-border overflow-hidden">
        <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 px-4 py-2.5 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
          <span>Fecha</span><span>Productos</span>
          <span className="text-center">Ítems</span>
          <span className="text-right">Total</span>
          <span /><span />
        </div>

        {/* Skeleton */}
        {loading && purchases.length === 0 && (
          <div className="flex flex-col">
            {Array.from({ length: 5 }).map((_, i) => (
              <div key={i} className="border-t border-border/50 first:border-t-0 px-4 py-3">
                <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 items-center">
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-40 rounded bg-accent animate-pulse" />
                  <div className="h-3.5 w-8 rounded bg-accent animate-pulse mx-auto" />
                  <div className="h-3.5 w-20 rounded bg-accent animate-pulse ml-auto" />
                </div>
                <div className="sm:hidden h-14 rounded bg-accent animate-pulse" />
              </div>
            ))}
          </div>
        )}

        {!loading && filtered.length === 0 && (
          <div className="flex flex-col items-center gap-3 py-16 text-center text-muted-foreground">
            <PackageOpen className="h-10 w-10 opacity-30" />
            <p className="text-sm">
              {search || isDateFilterActive || costCenterId || paymentMethodId
                ? "Sin resultados para esos filtros"
                : "No hay compras registradas"}
            </p>
            {!search && !isDateFilterActive && !costCenterId && !paymentMethodId && onAdd && (
              <Button variant="outline" size="sm" onClick={onAdd} className="gap-2">
                <Plus className="h-4 w-4" />Registrar primera compra
              </Button>
            )}
          </div>
        )}

        {filtered.map((op) => {
          const isExpanded = expandedKey === op.key
          // remitos-compra (D9/D11): el remito de origen, el motivo de no edición (primero: es el
          // primer guard de la RPC de edición) y lo que bloquea el borrado.
          const remitoLabel =
            op.sourceDeliveryNoteNumber === null || op.sourceDeliveryNoteNumber === undefined
              ? null
              : formatDeliveryNoteNumber("purchase", op.sourceDeliveryNoteNumber)
          const editBlockedReason =
            editLockedReasonText(op.editLockedReason, remitoLabel) ??
            (op.isPaymentLocked ? PAYMENT_LOCKED_REASON : null)
          // multiusuario-operativo tanda B (D9): sin la capacidad de compra, o sobre lo ajeno sin ser dueño ni administrador, no se ofrece ni Editar ni Eliminar.
          const canModify = canModifyOperation ? canModifyOperation(op) : true
          const deleteInfo = getDeleteCompensation(
            {
              ...op,
              // La compra nacida de un remito no devuelve stock al borrarse (D9): la nota lo dice.
              reversesStock: !op.sourceDeliveryNoteId,
              sourceDeliveryNoteLabel: remitoLabel,
              sourceDeliveryNoteDeleteBlockedReason: sourceNoteDeleteBlockedReason(op, remitoLabel, canVoidDeliveryNote),
            },
            "proveedor",
            "compra",
          )
          const sourceBadge = op.sourceDeliveryNoteId ? (
            <SourceDocumentBadge
              kind="purchase_delivery_note"
              documentId={op.sourceDeliveryNoteId}
              documentNumber={op.sourceDeliveryNoteNumber ?? null}
            />
          ) : null
          return (
            <div key={op.key} className="border-t border-border/50 first:border-t-0">
              <div
                role="button" tabIndex={0}
                onClick={() => toggleExpand(op.key)}
                onKeyDown={(e) => e.key === "Enter" && toggleExpand(op.key)}
                className="cursor-pointer hover:bg-accent/20 transition-colors group"
                aria-expanded={isExpanded}
              >
                {/* Mobile */}
                <div className="sm:hidden flex flex-col gap-1.5 px-4 py-3">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs text-muted-foreground tabular-nums">{formatDate(op.date)}</span>
                    <div className="flex items-center gap-1.5">
                      {op.isGrouped && (
                        <Badge variant="secondary" className="text-[10px] bg-cyan-500/15 text-cyan-400 border-cyan-500/25 border font-semibold">
                          <ShoppingCart className="h-2.5 w-2.5 mr-1" />{op.items.length}
                        </Badge>
                      )}
                      {onEditOperation && canModify && (
                        editBlockedReason ? (
                          <Button type="button" variant="ghost" size="icon" disabled
                            title={editBlockedReason} aria-label={editBlockedReason}
                            className="h-8 w-8 text-muted-foreground/50">
                            <Lock className="h-3.5 w-3.5" />
                          </Button>
                        ) : (
                          <Button type="button" variant="ghost" size="icon"
                            onClick={(e) => { e.stopPropagation(); onEditOperation(op) }}
                            className="h-8 w-8 text-muted-foreground hover:text-primary hover:bg-primary/10">
                            <Pencil className="h-3.5 w-3.5" />
                          </Button>
                        )
                      )}
                      {canModify && (
                        <DeleteOperationDialog
                          label={op.isGrouped ? `esta operación (${op.items.length} ítems)` : "esta compra"}
                          info={deleteInfo}
                          onConfirm={() => handleDelete(op)}
                          isDeleting={deletingKey === op.key}
                          onTriggerClick={(e) => e.stopPropagation()}
                        />
                      )}
                    </div>
                  </div>
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                        : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                      {/* qa-integral-modulos G2 (H2/2.6): primer producto +
                          "+N más" — el join de TODOS los nombres crecía hasta
                          518 px sin que el truncate se active (el espejo de
                          ventas, sale-operations-list.tsx, ya lo hacía bien). */}
                      <span className="text-sm font-medium text-foreground truncate">
                        {op.items[0]?.productName}
                        {op.items.length > 1 && (
                          <span className="text-muted-foreground font-normal"> · +{op.items.length - 1} más</span>
                        )}
                      </span>
                    </div>
                    <span className="text-sm font-bold text-cyan-400 tabular-nums shrink-0">{formatMoney(op.total)}</span>
                  </div>
                  <div className="flex items-center gap-1.5 flex-wrap">
                    {op.items[0]?.costCenterName && (
                      <Badge variant="outline" className="text-[10px] w-fit text-muted-foreground">
                        {op.items[0].costCenterName}
                      </Badge>
                    )}
                    <PaymentMethodBadge name={op.items[0]?.paymentMethodName} />
                    {/* compras-proveedor-cuenta-corriente (D9): badge de
                        proveedor, junto a centro de costo y forma de pago. */}
                    <Badge variant="outline" className="text-[10px] w-fit text-muted-foreground">
                      {op.supplierName ?? "Sin proveedor"}
                    </Badge>
                  </div>
                  {sourceBadge}
                </div>

                {/* Desktop */}
                <div className="hidden sm:grid grid-cols-[120px_1fr_80px_120px_48px_48px] gap-3 px-4 py-3 items-center">
                  <span className="text-sm text-muted-foreground tabular-nums">{formatDate(op.date)}</span>
                  <div className="flex items-center gap-2 min-w-0">
                    {isExpanded ? <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                      : <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0 group-hover:text-foreground" />}
                    {/* qa-integral-modulos G2 (H2/2.6): mismo patrón que el
                        espejo de ventas también en desktop. */}
                    <span className="text-sm font-medium text-foreground truncate">
                      {op.items[0]?.productName}
                      {op.items.length > 1 && (
                        <span className="text-muted-foreground font-normal"> · +{op.items.length - 1} más</span>
                      )}
                    </span>
                    {op.items[0]?.costCenterName && (
                      <Badge variant="outline" className="text-[10px] shrink-0 text-muted-foreground">
                        {op.items[0].costCenterName}
                      </Badge>
                    )}
                    <PaymentMethodBadge name={op.items[0]?.paymentMethodName} layout="inline" />
                    {/* compras-proveedor-cuenta-corriente (D9): badge de
                        proveedor, junto a centro de costo y forma de pago. */}
                    <Badge variant="outline" className="text-[10px] shrink-0 text-muted-foreground">
                      {op.supplierName ?? "Sin proveedor"}
                    </Badge>
                  </div>
                  <div className="flex justify-center">
                    {op.isGrouped
                      ? <Badge variant="secondary" className="text-[10px] bg-cyan-500/15 text-cyan-400 border-cyan-500/25 border font-semibold">
                          <ShoppingCart className="h-2.5 w-2.5 mr-1" />{op.items.length}
                        </Badge>
                      : <span className="text-sm text-muted-foreground">1</span>
                    }
                  </div>
                  <span className="text-right text-sm font-bold text-cyan-400 tabular-nums">{formatMoney(op.total)}</span>
                  {onEditOperation && canModify
                    ? editBlockedReason
                      ? <Button type="button" variant="ghost" size="icon" disabled
                          title={editBlockedReason} aria-label={editBlockedReason}
                          className="h-8 w-8 text-muted-foreground/50">
                          <Lock className="h-3.5 w-3.5" />
                        </Button>
                      : <Button type="button" variant="ghost" size="icon"
                          onClick={(e) => { e.stopPropagation(); onEditOperation(op) }}
                          className="h-8 w-8 text-muted-foreground hover:text-primary hover:bg-primary/10">
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                    : <span />
                  }
                  {canModify ? (
                    <DeleteOperationDialog
                      label={op.isGrouped ? `esta operación (${op.items.length} ítems)` : "esta compra"}
                      info={deleteInfo}
                      onConfirm={() => handleDelete(op)}
                      isDeleting={deletingKey === op.key}
                      onTriggerClick={(e) => e.stopPropagation()}
                    />
                  ) : <span />}
                  {sourceBadge && <div className="col-span-6 pl-[132px]">{sourceBadge}</div>}
                </div>
              </div>

              {isExpanded && (
                <div className="px-4 pb-4 pt-1 bg-accent/10 border-t border-dashed border-border/50">
                  <div className="rounded-lg border border-border/60 overflow-x-auto mt-2">
                    <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2 bg-accent/30 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold min-w-[320px]">
                      <span>Producto</span>
                      <span className="text-center">Cant.</span>
                      <span className="text-right">Costo unit.</span>
                      <span className="text-right">Subtotal</span>
                    </div>
                    {op.items.map((item) => (
                      <div key={item.id} className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border/30 text-sm items-center hover:bg-accent/10 min-w-[320px]">
                        <span className="font-medium text-foreground">{item.productName}</span>
                        <span className="text-center text-muted-foreground tabular-nums">{formatQuantity(item.quantity, unitSymbolFor(item.unitId))}</span>
                        <span className="text-right text-muted-foreground tabular-nums">{formatUnitPrice(item.unitCost)}</span>
                        <span className="text-right font-semibold text-cyan-400 tabular-nums">{formatMoney(item.total)}</span>
                      </div>
                    ))}
                    {op.description && (
                      <div className="px-3 py-2 border-t border-border/30 text-xs text-muted-foreground italic min-w-[320px]">
                        📝 {op.description}
                      </div>
                    )}
                    {op.isGrouped && (
                      <div className="grid grid-cols-[1fr_72px_110px_110px] gap-2 px-3 py-2.5 border-t border-border bg-accent/20 text-sm min-w-[320px]">
                        <span className="col-span-3 text-right font-medium text-muted-foreground pr-2">Total operación</span>
                        <span className="text-right font-bold text-base text-primary tabular-nums">{formatMoney(op.total)}</span>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          )
        })}

        {!loading && filtered.length > 0 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-border bg-accent/40">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Total ({filtered.length} op. en esta página)
            </span>
            <span className="text-base font-bold text-primary tabular-nums">{formatMoney(grandTotal)}</span>
          </div>
        )}
      </div>

      <PaginationBar
        meta={meta}
        onPageChange={onPageChange}
        onSizeChange={onPageSizeChange}
        loading={loading}
        label="compras"
      />
    </div>
  )
}
