"use client"

import { useMemo, useState } from "react"
import { toast } from "sonner"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter,
  DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import {
  useCloseSession,
  useCreateMatch,
  useRegisterManualMovement,
  useSessionMatches,
  useSessionPending,
  useSessionSuggestions,
  useUndoMatch,
  type StatementLine,
} from "@/hooks/data/use-bank-reconciliation"

const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

const MANUAL_TYPES = [
  { value: "fee", label: "Comisión bancaria" },
  { value: "tax_debit", label: "Impuesto / débito fiscal (Ley 25.413)" },
  { value: "interest", label: "Interés" },
  { value: "transfer_in", label: "Transferencia entrante" },
  { value: "transfer_out", label: "Transferencia saliente" },
  { value: "manual_adjustment", label: "Ajuste manual" },
] as const

interface Props {
  sessionId: string
  bankAccountId: string
}

export function ReconciliationBoard({ sessionId, bankAccountId }: Props) {
  const { data, isLoading } = useSessionPending(sessionId)
  const { data: matches } = useSessionMatches(sessionId)
  const [showSuggestions, setShowSuggestions] = useState(false)
  const { data: suggestions } = useSessionSuggestions(sessionId, showSuggestions)

  const createMatch = useCreateMatch(sessionId)
  const undoMatch = useUndoMatch(sessionId)
  const closeSession = useCloseSession(sessionId)
  const registerManual = useRegisterManualMovement(bankAccountId)

  const [selectedLines, setSelectedLines] = useState<Set<string>>(new Set())
  const [selectedMovements, setSelectedMovements] = useState<Set<string>>(new Set())
  const [undoTarget, setUndoTarget] = useState<string | null>(null)
  const [undoReason, setUndoReason] = useState("")
  const [closeOpen, setCloseOpen] = useState(false)
  const [closeReason, setCloseReason] = useState("")
  const [annotateLine, setAnnotateLine] = useState<StatementLine | null>(null)
  const [annotateType, setAnnotateType] = useState<string>("fee")

  const session = data?.session
  const lines = data?.pendingLines ?? []
  const movements = data?.pendingMovements ?? []

  const sumSelectedLines = useMemo(
    () => lines.filter((l) => selectedLines.has(l.id)).reduce((acc, l) => acc + l.amount, 0),
    [lines, selectedLines]
  )
  const sumSelectedMovements = useMemo(
    () => movements.filter((m) => selectedMovements.has(m.id)).reduce((acc, m) => acc + m.amount, 0),
    [movements, selectedMovements]
  )

  const toggle = (set: Set<string>, id: string, apply: (s: Set<string>) => void) => {
    const next = new Set(set)
    next.has(id) ? next.delete(id) : next.add(id)
    apply(next)
  }

  const handleMatch = async (lineIds: string[], movementIds: string[]) => {
    try {
      await createMatch.mutateAsync({ statementLineIds: lineIds, bankMovementIds: movementIds })
      toast.success("Conciliado correctamente")
      setSelectedLines(new Set())
      setSelectedMovements(new Set())
    } catch (err) {
      toast.error((err as Error).message || "No se pudo conciliar la selección")
    }
  }

  const handleUndo = async () => {
    if (!undoTarget || undoReason.trim() === "") return
    try {
      await undoMatch.mutateAsync({ matchGroup: undoTarget, undoReason: undoReason.trim() })
      toast.success("Conciliación deshecha")
      setUndoTarget(null)
      setUndoReason("")
    } catch (err) {
      toast.error((err as Error).message || "No se pudo deshacer")
    }
  }

  const handleClose = async () => {
    try {
      const result = (await closeSession.mutateAsync({
        closeReason: closeReason.trim() || null,
      })) as { difference?: string | number }
      const diff = Number(result?.difference ?? 0)
      toast.success(
        diff === 0
          ? "Sesión cerrada sin diferencia"
          : `Sesión cerrada con diferencia de ${fmtMoney(diff)}`
      )
      setCloseOpen(false)
    } catch (err) {
      toast.error(
        (err as Error).message ||
          "No se pudo cerrar — si hay diferencia, el motivo es obligatorio"
      )
    }
  }

  const handleAnnotate = async () => {
    if (!annotateLine) return
    try {
      await registerManual.mutateAsync({
        idempotencyKey: `annotate-${annotateLine.id}`,
        amount: String(annotateLine.amount),
        movementType: annotateType as Parameters<typeof registerManual.mutateAsync>[0]["movementType"],
        valueDate: annotateLine.valueDate,
        description: annotateLine.description,
      })
      toast.success("Movimiento anotado en el ledger — ya se puede conciliar")
      setAnnotateLine(null)
    } catch (err) {
      toast.error((err as Error).message || "No se pudo anotar el movimiento")
    }
  }

  if (isLoading || !session) {
    return <p className="text-sm text-muted-foreground">Cargando sesión…</p>
  }

  const isClosed = session.status === "closed"

  return (
    <div className="space-y-4">
      {/* ── Cabecera de la sesión ─────────────────────────────────────────── */}
      <Card>
        <CardHeader className="pb-2">
          <div className="flex items-center justify-between">
            <CardTitle className="text-base">
              Conciliación {session.periodFrom} → {session.periodTo}{" "}
              <Badge variant={isClosed ? "secondary" : "default"} className="ml-2">
                {isClosed ? "Cerrada" : "Abierta"}
              </Badge>
            </CardTitle>
            {!isClosed && (
              <div className="flex gap-2">
                <Button variant="outline" size="sm" onClick={() => setShowSuggestions((v) => !v)}>
                  {showSuggestions ? "Ocultar sugerencias" : "Sugerencias"}
                </Button>
                <Button size="sm" onClick={() => setCloseOpen(true)}>
                  Cerrar sesión
                </Button>
              </div>
            )}
          </div>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-2 text-sm md:grid-cols-4">
          <div>
            <p className="text-muted-foreground">Saldo extracto</p>
            <p className="font-medium">{fmtMoney(session.statementClosingBalance)}</p>
          </div>
          {session.ledgerClosingBalance !== null && (
            <div>
              <p className="text-muted-foreground">Saldo sistema</p>
              <p className="font-medium">{fmtMoney(session.ledgerClosingBalance)}</p>
            </div>
          )}
          {session.difference !== null && (
            <div>
              <p className="text-muted-foreground">Diferencia</p>
              <p className={`font-medium ${session.difference !== 0 ? "text-destructive" : ""}`}>
                {fmtMoney(session.difference)}
              </p>
            </div>
          )}
          {session.closeReason && (
            <div className="col-span-2">
              <p className="text-muted-foreground">Motivo</p>
              <p>{session.closeReason}</p>
            </div>
          )}
        </CardContent>
      </Card>

      {/* ── Sugerencias 1:1 ───────────────────────────────────────────────── */}
      {!isClosed && showSuggestions && (
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm">
              Sugerencias 1:1 (monto exacto, fecha ±3 días) — confirmación manual
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {(suggestions ?? []).length === 0 && (
              <p className="text-sm text-muted-foreground">Sin sugerencias para los pendientes.</p>
            )}
            {(suggestions ?? []).map((s) => (
              <div
                key={`${s.statementLineId}-${s.bankMovementId}`}
                className="flex items-center justify-between rounded-md border p-2 text-sm"
              >
                <span>
                  {s.lineValueDate} · {s.lineDescription ?? "(sin descripción)"} ↔{" "}
                  {s.movementDescription ?? "(movimiento)"} · <b>{fmtMoney(s.amount)}</b>
                </span>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={createMatch.isPending}
                  onClick={() => handleMatch([s.statementLineId], [s.bankMovementId])}
                >
                  Conciliar
                </Button>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {/* ── Panel doble ───────────────────────────────────────────────────── */}
      {!isClosed && (
        <div className="grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm">
                Extracto — pendientes ({lines.length}) · Selección: {fmtMoney(sumSelectedLines)}
              </CardTitle>
            </CardHeader>
            <CardContent className="max-h-96 space-y-1 overflow-y-auto">
              {lines.length === 0 && (
                <p className="text-sm text-muted-foreground">
                  Sin líneas pendientes — importá un extracto o ya está todo conciliado.
                </p>
              )}
              {lines.map((l) => (
                <div key={l.id} className="flex items-center gap-2 rounded-md border p-2 text-sm">
                  <Checkbox
                    checked={selectedLines.has(l.id)}
                    onCheckedChange={() => toggle(selectedLines, l.id, setSelectedLines)}
                  />
                  <span className="flex-1">
                    {l.valueDate} · {l.description ?? "(sin descripción)"}
                  </span>
                  <span className={`font-medium ${l.amount < 0 ? "text-destructive" : ""}`}>
                    {fmtMoney(l.amount)}
                  </span>
                  <Button
                    size="sm"
                    variant="ghost"
                    title="Anotar en el ledger (comisión/impuesto/interés sin contraparte)"
                    onClick={() => {
                      setAnnotateLine(l)
                      setAnnotateType(l.amount < 0 ? "fee" : "interest")
                    }}
                  >
                    Anotar
                  </Button>
                </div>
              ))}
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm">
                Sistema — sin conciliar ({movements.length}) · Selección: {fmtMoney(sumSelectedMovements)}
              </CardTitle>
            </CardHeader>
            <CardContent className="max-h-96 space-y-1 overflow-y-auto">
              {movements.length === 0 && (
                <p className="text-sm text-muted-foreground">Sin movimientos pendientes.</p>
              )}
              {movements.map((m) => (
                <div key={m.id} className="flex items-center gap-2 rounded-md border p-2 text-sm">
                  <Checkbox
                    checked={selectedMovements.has(m.id)}
                    onCheckedChange={() => toggle(selectedMovements, m.id, setSelectedMovements)}
                  />
                  <span className="flex-1">
                    {m.valueDate ?? "s/f"} · {m.description ?? m.movementType}
                  </span>
                  <span className={`font-medium ${m.amount < 0 ? "text-destructive" : ""}`}>
                    {fmtMoney(m.amount)}
                  </span>
                </div>
              ))}
            </CardContent>
          </Card>
        </div>
      )}

      {/* ── Acción de match manual ────────────────────────────────────────── */}
      {!isClosed && (
        <div className="flex items-center gap-3">
          <Button
            disabled={
              selectedLines.size === 0 || selectedMovements.size === 0 || createMatch.isPending
            }
            onClick={() => handleMatch(Array.from(selectedLines), Array.from(selectedMovements))}
          >
            Conciliar selección ({selectedLines.size} línea/s ↔ {selectedMovements.size} mov/s)
          </Button>
          {selectedLines.size > 0 &&
            selectedMovements.size > 0 &&
            sumSelectedLines !== sumSelectedMovements && (
              <p className="text-sm text-destructive">
                Las sumas no coinciden ({fmtMoney(sumSelectedLines)} vs {fmtMoney(sumSelectedMovements)})
              </p>
            )}
        </div>
      )}

      {/* pos-banco-movimientos (task 11.3): procedimiento de conciliación de
          tarjeta — el bruto se asienta como card_settlement (D3) y el
          extracto acredita el neto en fecha posterior. No hace falta una
          pieza nueva: es el mismo match manual de arriba, agrupando N:1. */}
      {!isClosed && (
        <p className="text-xs text-muted-foreground rounded-md border border-dashed border-border px-3 py-2">
          <b>Tarjeta:</b> la venta se asienta bruta (antes de la comisión). Para conciliarla contra el
          neto que acredita el extracto, registrá la comisión como movimiento manual
          (tipo &quot;Comisión bancaria&quot;, importe negativo) y seleccioná ambos movimientos junto
          con la línea del extracto — la conciliación N:1 de arriba cierra cuando la suma coincide.
        </p>
      )}

      {/* ── Conciliados (undo) ────────────────────────────────────────────── */}
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-sm">Conciliados en esta sesión ({matches?.length ?? 0})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1">
          {(matches ?? []).length === 0 && (
            <p className="text-sm text-muted-foreground">Todavía no hay grupos conciliados.</p>
          )}
          {(matches ?? []).map((g) => (
            <div
              key={g.matchGroup}
              className="flex items-center justify-between rounded-md border p-2 text-sm"
            >
              <span>
                {g.lineCount} línea/s ↔ {g.movementCount} movimiento/s · <b>{fmtMoney(g.amount)}</b>
              </span>
              {!isClosed && (
                <Button size="sm" variant="ghost" onClick={() => setUndoTarget(g.matchGroup)}>
                  Deshacer
                </Button>
              )}
            </div>
          ))}
        </CardContent>
      </Card>

      {/* ── Dialog: deshacer con motivo (RN-A5) ───────────────────────────── */}
      <Dialog open={!!undoTarget} onOpenChange={(open) => !open && setUndoTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Deshacer conciliación</DialogTitle>
            <DialogDescription>
              El grupo queda registrado como deshecho (no se borra). El motivo es obligatorio.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <Label htmlFor="undo-reason">Motivo</Label>
            <Textarea
              id="undo-reason"
              value={undoReason}
              onChange={(e) => setUndoReason(e.target.value)}
              placeholder="Ej: el monto correspondía a otra transferencia"
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setUndoTarget(null)}>
              Cancelar
            </Button>
            <Button
              disabled={undoReason.trim() === "" || undoMatch.isPending}
              onClick={handleUndo}
            >
              Deshacer
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ── Dialog: cierre de sesión ──────────────────────────────────────── */}
      <Dialog open={closeOpen} onOpenChange={setCloseOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Cerrar sesión de conciliación</DialogTitle>
            <DialogDescription>
              El cierre calcula el saldo del sistema al {session.periodTo} y la diferencia contra
              el extracto ({fmtMoney(session.statementClosingBalance)}). Si la diferencia no es
              cero, el motivo es obligatorio. Una sesión cerrada no se reabre.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <Label htmlFor="close-reason">Motivo (obligatorio si hay diferencia)</Label>
            <Textarea
              id="close-reason"
              value={closeReason}
              onChange={(e) => setCloseReason(e.target.value)}
              placeholder="Ej: transferencia del 25/07 pendiente de registrar"
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCloseOpen(false)}>
              Cancelar
            </Button>
            <Button disabled={closeSession.isPending} onClick={handleClose}>
              Cerrar sesión
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ── Dialog: anotar cargo del extracto ("solo anotar" V1) ──────────── */}
      <Dialog open={!!annotateLine} onOpenChange={(open) => !open && setAnnotateLine(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Anotar movimiento en el ledger</DialogTitle>
            <DialogDescription>
              Registra este cargo del extracto como movimiento bancario del sistema
              (comisiones, impuestos, intereses que el banco debitó/acreditó). Después
              se concilia 1:1 con la línea.
            </DialogDescription>
          </DialogHeader>
          {annotateLine && (
            <div className="space-y-3 text-sm">
              <p>
                {annotateLine.valueDate} · {annotateLine.description ?? "(sin descripción)"} ·{" "}
                <b>{fmtMoney(annotateLine.amount)}</b>
              </p>
              <div className="space-y-2">
                <Label>Tipo de movimiento</Label>
                <Select value={annotateType} onValueChange={setAnnotateType}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {MANUAL_TYPES.map((t) => (
                      <SelectItem key={t.value} value={t.value}>
                        {t.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setAnnotateLine(null)}>
              Cancelar
            </Button>
            <Button disabled={registerManual.isPending} onClick={handleAnnotate}>
              Anotar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
