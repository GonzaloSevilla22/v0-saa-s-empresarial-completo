"use client"

import { use, useState } from "react"
import Link from "next/link"
import { ArrowLeft, Plus, History } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/components/ui/tabs"
import { useBranches } from "@/hooks/data/use-branches"
import { useCashboxes, useCreateCashbox } from "@/hooks/data/use-cashboxes"
import { useCurrentSession, useOpenSession, useCloseSession, useCashSessions } from "@/hooks/data/use-cash-session"
import { useCashMovements } from "@/hooks/data/use-cash-movements"
import { CashSessionPanel } from "@/components/cash/CashSessionPanel"
import { OpenSessionForm } from "@/components/cash/OpenSessionForm"
import { CashMovementsList } from "@/components/cash/CashMovementsList"
import { CloseSessionDialog } from "@/components/cash/CloseSessionDialog"

interface PageProps {
  params: Promise<{ id: string }>
}

export default function BranchCajaPage({ params }: PageProps) {
  const { id: branchId } = use(params)
  const { branches, isLoading: branchesLoading } = useBranches()
  const branch = branches.find((b) => b.id === branchId)

  // We work with the first cashbox of the branch (MVP: one cashbox per branch)
  const { data: cashboxes, isLoading: cashboxesLoading } = useCashboxes(branchId)
  const firstCashbox = cashboxes?.[0] ?? null

  const createCashbox = useCreateCashbox()

  const { data: currentSession, isLoading: sessionLoading } = useCurrentSession(
    firstCashbox?.id ?? null
  )
  const { data: allSessions, isLoading: allSessionsLoading } = useCashSessions(
    firstCashbox?.id ?? null
  )
  const { data: movements, isLoading: movementsLoading } = useCashMovements(
    currentSession?.id ?? null
  )

  const openSession = useOpenSession(firstCashbox?.id ?? "")
  const closeSession = useCloseSession()

  // Derive running balance from movements
  const runningBalance =
    movements && movements.length > 0
      ? movements[movements.length - 1].balanceAfter
      : currentSession?.openingBalance

  // Expected balance for arqueo = running balance or opening
  const expectedBalance = runningBalance ?? 0

  const isLoading = branchesLoading || cashboxesLoading

  // ── Handlers ──────────────────────────────────────────────────────────────

  async function handleCreateCashbox() {
    await createCashbox.mutateAsync({
      branch_id: branchId,
      name:      "Caja 1",
      currency:  "ARS",
    })
  }

  async function handleOpenSession(openingBalance: number) {
    await openSession.mutateAsync(openingBalance)
  }

  async function handleCloseSession(countedBalance: number) {
    if (!currentSession) return
    await closeSession.mutateAsync({
      sessionId:      currentSession.id,
      countedBalance,
    })
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="flex flex-col gap-6">
      {/* Header */}
      <div className="flex flex-col gap-1">
        <div className="flex items-center gap-3">
          <Button asChild variant="ghost" size="icon" className="h-8 w-8 shrink-0">
            <Link href={`/sucursales`} aria-label="Volver a sucursales">
              <ArrowLeft className="h-4 w-4" />
            </Link>
          </Button>
          <div>
            <h1 className="text-xl font-bold">
              Caja {branch ? `— ${branch.name}` : ""}
            </h1>
            <p className="text-sm text-muted-foreground">
              Apertura, movimientos y cierre con arqueo.
            </p>
          </div>
        </div>
      </div>

      {/* No cashbox yet — create one */}
      {!isLoading && !firstCashbox && (
        <div className="flex flex-col items-center gap-4 py-12 text-center">
          <p className="text-sm text-muted-foreground max-w-sm">
            Esta sucursal todavía no tiene una caja configurada. Creá una para
            empezar a registrar movimientos.
          </p>
          <Button
            onClick={handleCreateCashbox}
            disabled={createCashbox.isPending}
          >
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

      {/* Main cash session UI */}
      {firstCashbox && (
        <div className="flex flex-col gap-4">
          {/* Status panel */}
          <CashSessionPanel
            session={currentSession ?? null}
            isLoading={sessionLoading}
            runningBalance={runningBalance}
          />

          {/* Action bar: open or close */}
          {!sessionLoading && (
            <div className="flex items-center justify-between gap-4 flex-wrap">
              {!currentSession ? (
                <OpenSessionForm
                  onOpen={handleOpenSession}
                  isLoading={openSession.isPending}
                />
              ) : (
                <div className="flex items-center gap-3">
                  <Badge variant="outline" className="text-xs">
                    Sesión activa: {currentSession.id.slice(0, 8)}…
                  </Badge>
                  <CloseSessionDialog
                    expectedBalance={expectedBalance}
                    onClose={handleCloseSession}
                    isLoading={closeSession.isPending}
                  />
                </div>
              )}
            </div>
          )}

          {/* Tabs: current movements / session history */}
          {firstCashbox && (
            <Tabs defaultValue="movements" className="w-full">
              <TabsList>
                <TabsTrigger value="movements">Movimientos</TabsTrigger>
                <TabsTrigger value="history">
                  <History className="mr-1.5 h-3.5 w-3.5" />
                  Historial
                </TabsTrigger>
              </TabsList>

              <TabsContent value="movements" className="mt-3">
                {currentSession ? (
                  <CashMovementsList
                    movements={movements ?? []}
                    isLoading={movementsLoading}
                  />
                ) : (
                  <p className="text-sm text-muted-foreground py-4 text-center">
                    Abrí una sesión para ver los movimientos.
                  </p>
                )}
              </TabsContent>

              <TabsContent value="history" className="mt-3">
                {allSessionsLoading ? (
                  <p className="text-sm text-muted-foreground py-4 text-center">
                    Cargando historial…
                  </p>
                ) : !allSessions || allSessions.length === 0 ? (
                  <p className="text-sm text-muted-foreground py-4 text-center">
                    Sin sesiones previas.
                  </p>
                ) : (
                  <div className="divide-y rounded-md border overflow-hidden">
                    {allSessions.map((s) => (
                      <div
                        key={s.id}
                        className="flex items-center justify-between px-4 py-3 text-sm"
                      >
                        <div className="flex flex-col gap-0.5">
                          <span className="font-medium">
                            {new Date(s.openedAt).toLocaleDateString("es-AR", {
                              dateStyle: "short",
                            })}
                            {" — "}
                            {new Date(s.openedAt).toLocaleTimeString("es-AR", {
                              timeStyle: "short",
                            })}
                          </span>
                          <span className="text-xs text-muted-foreground">
                            Inicial: $
                            {s.openingBalance.toLocaleString("es-AR", {
                              minimumFractionDigits: 2,
                            })}
                          </span>
                        </div>
                        <div className="flex flex-col items-end gap-0.5">
                          <Badge
                            variant={s.status === "open" ? "default" : "secondary"}
                          >
                            {s.status === "open" ? "Abierta" : "Cerrada"}
                          </Badge>
                          {s.status === "closed" && s.difference != null && (
                            <span
                              className={`text-xs font-medium ${
                                s.difference === 0
                                  ? "text-green-600 dark:text-green-400"
                                  : "text-yellow-600 dark:text-yellow-400"
                              }`}
                            >
                              Dif:{" "}
                              {s.difference >= 0 ? "+" : ""}$
                              {s.difference.toLocaleString("es-AR", {
                                minimumFractionDigits: 2,
                              })}
                            </span>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </TabsContent>
            </Tabs>
          )}
        </div>
      )}
    </div>
  )
}
