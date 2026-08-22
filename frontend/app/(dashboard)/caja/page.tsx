"use client"

/**
 * /caja — módulo de Caja como primer nivel (D8 del design,
 * cash-book-module). Resuelve sucursal y caja ADENTRO de la pantalla en vez
 * de exigir navegar por Sucursales: selector de sucursal (auto si hay una
 * sola) → selector de caja (oculto si hay una sola, caso de las 37 cajas de
 * prod). `/sucursales/[id]/caja` redirige acá con `?branch=<id>`.
 */

import { useMemo, useState } from "react"
import { useSearchParams } from "next/navigation"
import { Plus, Scale, History } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { useBranches } from "@/hooks/data/use-branches"
import { useCashboxes, useCreateCashbox } from "@/hooks/data/use-cashboxes"
import {
  useCurrentSession, useOpenSession, useCloseSession, useCashSessions,
} from "@/hooks/data/use-cash-session"
import {
  fetchCashMovementsByCashboxPage, useCashMovements, useRegisterMovement,
} from "@/hooks/data/use-cash-movements"
import { CashSessionPanel } from "@/components/cash/CashSessionPanel"
import { OpenSessionForm } from "@/components/cash/OpenSessionForm"
import { CloseSessionDialog } from "@/components/cash/CloseSessionDialog"
import { LedgerMovementsPanel } from "@/components/ledger/LedgerMovementsPanel"
import { LedgerAdjustmentDialog } from "@/components/ledger/LedgerAdjustmentDialog"
import { CASH_MOVEMENT_FAMILIES, CASH_MOVEMENT_META } from "@/lib/ledger/cash-movement-meta"
import type { LedgerBookConfig } from "@/lib/ledger/types"
import type { CashMovementHistoryRow } from "@/lib/types"

const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

export default function CajaPage() {
  const searchParams = useSearchParams()
  const branchParam = searchParams.get("branch")

  const { branches, isLoading: branchesLoading } = useBranches()
  const [branchId, setBranchId] = useState<string | null>(branchParam)

  // Preselección automática: única sucursal → se elige sola (D8).
  const effectiveBranchId = useMemo(() => {
    if (branchId) return branchId
    if (!branchesLoading && branches.length === 1) return branches[0].id
    return null
  }, [branchId, branches, branchesLoading])

  const { data: cashboxes, isLoading: cashboxesLoading } = useCashboxes(effectiveBranchId)
  const [cashboxIdOverride, setCashboxIdOverride] = useState<string | null>(null)
  const cashboxId = cashboxIdOverride ?? cashboxes?.[0]?.id ?? null
  const createCashbox = useCreateCashbox()

  const { data: currentSession, isLoading: sessionLoading } = useCurrentSession(cashboxId)
  const { data: allSessions, isLoading: sessionsLoading } = useCashSessions(cashboxId)
  const { data: activeSessionMovements } = useCashMovements(currentSession?.id ?? null)
  const openSession = useOpenSession(cashboxId ?? "")
  const closeSession = useCloseSession()
  const registerMovement = useRegisterMovement(currentSession?.id ?? "")

  const [adjustDialogOpen, setAdjustDialogOpen] = useState(false)
  const [historyRefreshToken, setHistoryRefreshToken] = useState(0)

  const bookConfig: LedgerBookConfig<CashMovementHistoryRow> = useMemo(
    () => ({
      book: "cash",
      meta: CASH_MOVEMENT_META,
      families: CASH_MOVEMENT_FAMILIES,
      extraColumn: {
        header: "Sesión",
        render: (row) => (
          <span className="flex items-center gap-1">
            {new Date(row.sessionOpenedAt).toLocaleDateString("es-AR", { dateStyle: "short" })}
            <Badge variant={row.sessionStatus === "open" ? "default" : "secondary"} className="text-[10px]">
              {row.sessionStatus === "open" ? "Abierta" : "Cerrada"}
            </Badge>
          </span>
        ),
      },
      fetchPage: (params) =>
        cashboxId
          ? fetchCashMovementsByCashboxPage(cashboxId, params)
          : Promise.resolve({ items: [], total: 0, page: 0, pages: 0 }),
      csvName: "movimientos_caja",
      csvHeader: ["Fecha", "Tipo", "Motivo", "Sesión", "Importe", "Saldo"],
      csvRow: (row) => [
        new Date(row.createdAt).toLocaleString("es-AR"),
        CASH_MOVEMENT_META[row.movementType]?.label ?? row.movementType,
        row.description ?? "",
        row.sessionStatus,
        row.amount,
        row.balanceAfter,
      ],
    }),
    [cashboxId]
  )

  // Saldo corriente derivado de los movimientos de la sesión ACTIVA (no del
  // historial por caja, que mezcla sesiones cerradas) — mismo cálculo que
  // la pantalla que reemplaza (sucursales/[id]/caja).
  const runningBalance =
    activeSessionMovements && activeSessionMovements.length > 0
      ? activeSessionMovements[activeSessionMovements.length - 1].balanceAfter
      : currentSession?.openingBalance

  const isLoading = branchesLoading || cashboxesLoading

  async function handleCreateCashbox() {
    if (!effectiveBranchId) return
    await createCashbox.mutateAsync({ branch_id: effectiveBranchId, name: "Caja 1", currency: "ARS" })
  }

  async function handleOpenSession(openingBalance: number) {
    await openSession.mutateAsync(openingBalance)
  }

  async function handleCloseSession(countedBalance: number) {
    if (!currentSession) return
    await closeSession.mutateAsync({ sessionId: currentSession.id, countedBalance })
  }

  async function handleAdjustment(values: { amount: number; description: string }) {
    await registerMovement.mutateAsync({
      amount: values.amount,
      movement_type: "adjustment",
      description: values.description,
    })
    setHistoryRefreshToken((t) => t + 1)
  }

  return (
    <div className="space-y-6 p-6">
      <div>
        <h1 className="text-2xl font-bold flex items-center gap-2">
          <Scale className="h-6 w-6" />
          Caja
        </h1>
        <p className="text-sm text-muted-foreground">
          Apertura, movimientos, ajustes y cierre con arqueo — historial completo, no solo la sesión abierta.
        </p>
      </div>

      {/* Selector de sucursal — oculto si hay una sola (D8) */}
      {!branchesLoading && branches.length > 1 && (
        <div className="max-w-xs">
          <Select value={effectiveBranchId ?? undefined} onValueChange={setBranchId}>
            <SelectTrigger>
              <SelectValue placeholder="Elegí la sucursal" />
            </SelectTrigger>
            <SelectContent>
              {branches.map((b) => (
                <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      {effectiveBranchId && (
        <>
          {/* Selector de caja — oculto si hay una sola (D8, 37 cajas / 40 sucursales ≈ 1:1) */}
          {!cashboxesLoading && (cashboxes?.length ?? 0) > 1 && (
            <div className="max-w-xs">
              <Select value={cashboxId ?? undefined} onValueChange={setCashboxIdOverride}>
                <SelectTrigger>
                  <SelectValue placeholder="Elegí la caja" />
                </SelectTrigger>
                <SelectContent>
                  {cashboxes?.map((c) => (
                    <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          {/* Sin caja configurada — ofrecer crearla (comportamiento preservado, task 8.7) */}
          {!isLoading && !cashboxId && (
            <div className="flex flex-col items-center gap-4 py-12 text-center">
              <p className="text-sm text-muted-foreground max-w-sm">
                Esta sucursal todavía no tiene una caja configurada. Creá una para empezar a registrar movimientos.
              </p>
              <Button onClick={handleCreateCashbox} disabled={createCashbox.isPending}>
                <Plus className="mr-2 h-4 w-4" />
                Crear caja
              </Button>
              {createCashbox.isError && (
                <p className="text-xs text-destructive" role="alert">
                  {(createCashbox.error as Error).message}
                </p>
              )}
            </div>
          )}

          {cashboxId && (
            <div className="flex flex-col gap-4">
              <CashSessionPanel session={currentSession ?? null} isLoading={sessionLoading} runningBalance={runningBalance} />

              {!sessionLoading && (
                <div className="flex items-center justify-between gap-4 flex-wrap">
                  {!currentSession ? (
                    <OpenSessionForm onOpen={handleOpenSession} isLoading={openSession.isPending} />
                  ) : (
                    <div className="flex items-center gap-3 flex-wrap">
                      <Badge variant="outline" className="text-xs">
                        Sesión activa: {currentSession.id.slice(0, 8)}…
                      </Badge>
                      <Button variant="outline" size="sm" onClick={() => setAdjustDialogOpen(true)}>
                        <Scale className="mr-1.5 h-3.5 w-3.5" />
                        Registrar ajuste
                      </Button>
                      <CloseSessionDialog
                        expectedBalance={runningBalance ?? 0}
                        onClose={handleCloseSession}
                        isLoading={closeSession.isPending}
                      />
                    </div>
                  )}
                  {!currentSession && (
                    <Button variant="outline" size="sm" disabled title="Abrí una sesión para poder ajustar">
                      <Scale className="mr-1.5 h-3.5 w-3.5" />
                      Registrar ajuste
                    </Button>
                  )}
                </div>
              )}

              <LedgerMovementsPanel config={bookConfig} scopeKey={cashboxId} refreshToken={historyRefreshToken} />

              {/* Historial de sesiones — con ajustes visibles (task 8.3) */}
              <div className="rounded-xl border border-border bg-card">
                <div className="flex items-center gap-2 px-4 py-3 border-b border-border">
                  <History className="h-4 w-4 text-muted-foreground" />
                  <span className="text-sm font-medium">Historial de sesiones</span>
                </div>
                <div className="divide-y">
                  {sessionsLoading ? (
                    <p className="text-sm text-muted-foreground py-4 text-center">Cargando…</p>
                  ) : !allSessions || allSessions.length === 0 ? (
                    <p className="text-sm text-muted-foreground py-4 text-center">Sin sesiones previas.</p>
                  ) : (
                    allSessions.map((s) => {
                      const hasAdjustments = s.adjustmentsTotal !== 0
                      const diffBeforeAdjustments =
                        s.difference != null ? s.difference + s.adjustmentsTotal : null
                      return (
                        <div key={s.id} className="flex items-center justify-between px-4 py-3 text-sm">
                          <div className="flex flex-col gap-0.5">
                            <span className="font-medium">
                              {new Date(s.openedAt).toLocaleString("es-AR", { dateStyle: "short", timeStyle: "short" })}
                            </span>
                            <span className="text-xs text-muted-foreground">
                              Inicial: {fmtMoney(s.openingBalance)}
                            </span>
                          </div>
                          <div className="flex flex-col items-end gap-0.5">
                            <Badge variant={s.status === "open" ? "default" : "secondary"}>
                              {s.status === "open" ? "Abierta" : "Cerrada"}
                            </Badge>
                            {s.status === "closed" && s.difference != null && (
                              <span
                                className={`text-xs font-medium ${
                                  s.difference === 0 ? "text-success" : "text-warning"
                                }`}
                              >
                                Dif: {s.difference >= 0 ? "+" : ""}
                                {fmtMoney(s.difference)}
                                {hasAdjustments && diffBeforeAdjustments != null && (
                                  <> · {Math.abs(s.adjustmentsTotal) > 0 ? `${s.adjustmentsTotal >= 0 ? "+" : ""}${fmtMoney(s.adjustmentsTotal)} ajuste` : ""} (sin ajustes: {diffBeforeAdjustments >= 0 ? "+" : ""}{fmtMoney(diffBeforeAdjustments)})</>
                                )}
                              </span>
                            )}
                          </div>
                        </div>
                      )
                    })
                  )}
                </div>
              </div>
            </div>
          )}

          <LedgerAdjustmentDialog
            open={adjustDialogOpen}
            onOpenChange={setAdjustDialogOpen}
            mode="cash"
            canSubmit={!!currentSession}
            disabledReason={!currentSession ? "No hay sesión de caja abierta. Abrí una sesión primero." : undefined}
            isSubmitting={registerMovement.isPending}
            onConfirm={handleAdjustment}
          />
        </>
      )}
    </div>
  )
}
