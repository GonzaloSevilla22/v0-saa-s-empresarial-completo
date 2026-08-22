"use client"

/**
 * /banco — módulo de Banco como primer nivel, con la conciliación adentro
 * (D8 del design). Tabs Movimientos | Conciliación. La tab de Conciliación
 * monta `ReconciliationBoard`, el importador de extracto y
 * `BankAccountFormDialog` SIN REESCRIBIRLOS (D8, C3 intacto) — mismo
 * contenido que tenía `/finanzas/conciliacion`, que ahora redirige acá.
 */

import { useMemo, useRef, useState } from "react"
import { useSearchParams } from "next/navigation"
import { Plus, Landmark, Scale } from "lucide-react"
import { toast } from "sonner"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter,
  DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { ReconciliationBoard } from "@/components/bank-reconciliation/ReconciliationBoard"
import { BankAccountFormDialog } from "@/components/bank-accounts/BankAccountFormDialog"
import { LedgerMovementsPanel } from "@/components/ledger/LedgerMovementsPanel"
import { LedgerAdjustmentDialog } from "@/components/ledger/LedgerAdjustmentDialog"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import {
  useImportStatement, useOpenSession, useReconciliationSessions,
  useStatementImports, useRegisterManualMovement,
} from "@/hooks/data/use-bank-reconciliation"
import { fetchBankMovementsPage } from "@/hooks/data/use-bank-movements"
import { BANK_MOVEMENT_FAMILIES, BANK_MOVEMENT_META } from "@/lib/ledger/bank-movement-meta"
import type { LedgerBookConfig } from "@/lib/ledger/types"
import type { BankMovementRow } from "@/lib/types"
import {
  hashFileSHA256, parseBankStatementFile, type NormalizedStatementLine,
} from "@/lib/bank-statement-parser"

const fmtMoney = (n: number) =>
  n.toLocaleString("es-AR", { style: "currency", currency: "ARS" })

export default function BancoPage() {
  const searchParams = useSearchParams()
  const initialTab = searchParams.get("tab") === "conciliacion" ? "conciliacion" : "movimientos"

  const { data: bankAccounts, isLoading: loadingAccounts } = useBankAccounts()
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  const [newAccountDialogOpen, setNewAccountDialogOpen] = useState(false)

  const selectedAccount = (bankAccounts ?? []).find((ba) => ba.id === bankAccountId) ?? null

  return (
    <div className="space-y-6 p-6">
      <div>
        <h1 className="text-2xl font-bold flex items-center gap-2">
          <Landmark className="h-6 w-6" />
          Banco
        </h1>
        <p className="text-sm text-muted-foreground">
          Movimientos, ajustes y conciliación bancaria en un solo lugar.
        </p>
      </div>

      {/* Selector de cuenta bancaria */}
      <Card>
        <CardHeader className="pb-2 flex flex-row items-center justify-between">
          <CardTitle className="text-base">Cuenta bancaria</CardTitle>
          {(bankAccounts ?? []).length > 0 && (
            <Button size="sm" variant="outline" onClick={() => setNewAccountDialogOpen(true)}>
              <Plus className="h-4 w-4 mr-1" />
              Nueva cuenta bancaria
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {loadingAccounts ? (
            <p className="text-sm text-muted-foreground">Cargando cuentas…</p>
          ) : (bankAccounts ?? []).length === 0 ? (
            <div className="flex flex-col items-start gap-3">
              <p className="text-sm text-muted-foreground">
                No hay cuentas bancarias activas. Registrá una cuenta para empezar.
              </p>
              <Button size="sm" onClick={() => setNewAccountDialogOpen(true)}>
                <Plus className="h-4 w-4 mr-1" />
                Nueva cuenta bancaria
              </Button>
            </div>
          ) : (
            <Select value={bankAccountId ?? undefined} onValueChange={setBankAccountId}>
              <SelectTrigger className="w-full md:w-96">
                <SelectValue placeholder="Elegí la cuenta" />
              </SelectTrigger>
              <SelectContent>
                {(bankAccounts ?? []).map((ba) => (
                  <SelectItem key={ba.id} value={ba.id}>
                    {ba.name}
                    {ba.bankName ? ` — ${ba.bankName}` : ""}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </CardContent>
      </Card>

      <BankAccountFormDialog open={newAccountDialogOpen} onOpenChange={setNewAccountDialogOpen} />

      {bankAccountId && (
        <Tabs defaultValue={initialTab} className="w-full">
          <TabsList>
            <TabsTrigger value="movimientos">Movimientos</TabsTrigger>
            <TabsTrigger value="conciliacion">Conciliación</TabsTrigger>
          </TabsList>

          <TabsContent value="movimientos" className="mt-4">
            <MovimientosTab bankAccountId={bankAccountId} accountName={selectedAccount?.name ?? ""} />
          </TabsContent>

          <TabsContent value="conciliacion" className="mt-4">
            <ConciliacionTab bankAccountId={bankAccountId} />
          </TabsContent>
        </Tabs>
      )}
    </div>
  )
}

// ── Tab: Movimientos (D3 + D9) ───────────────────────────────────────────────

function MovimientosTab({ bankAccountId, accountName }: { bankAccountId: string; accountName: string }) {
  const [adjustDialogOpen, setAdjustDialogOpen] = useState(false)
  const [refreshToken, setRefreshToken] = useState(0)
  const registerMovement = useRegisterManualMovement(bankAccountId)

  const bookConfig: LedgerBookConfig<BankMovementRow> = useMemo(
    () => ({
      book: "bank",
      meta: BANK_MOVEMENT_META,
      families: BANK_MOVEMENT_FAMILIES,
      extraColumn: {
        header: "Conciliación",
        render: (row) => (
          <Badge variant={row.reconciliationStatus === "matched" ? "secondary" : "outline"} className="text-[10px]">
            {row.reconciliationStatus === "matched" ? "Conciliado" : "Sin conciliar"}
          </Badge>
        ),
      },
      extraFilter: {
        key: "status",
        label: "Conciliación",
        options: [
          { value: "unreconciled", label: "Sin conciliar" },
          { value: "matched", label: "Conciliado" },
        ],
      },
      fetchPage: (params) => fetchBankMovementsPage(bankAccountId, params),
      csvName: "movimientos_banco",
      csvHeader: ["Fecha", "Tipo", "Motivo", "Conciliación", "Importe", "Saldo"],
      csvRow: (row) => [
        row.valueDate ?? new Date(row.createdAt).toLocaleDateString("es-AR"),
        BANK_MOVEMENT_META[row.movementType]?.label ?? row.movementType,
        row.description ?? "",
        row.reconciliationStatus,
        row.amount,
        row.balanceAfter,
      ],
    }),
    [bankAccountId]
  )

  async function handleAdjustment(values: { amount: number; description: string; valueDate?: string }) {
    await registerMovement.mutateAsync({
      idempotencyKey: `bank-adj-${bankAccountId}-${Date.now()}`,
      amount: String(values.amount),
      movementType: "manual_adjustment",
      valueDate: values.valueDate ?? null,
      description: values.description,
    })
    setRefreshToken((t) => t + 1)
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between flex-wrap gap-3">
        <p className="text-sm text-muted-foreground">Cuenta: <strong>{accountName}</strong></p>
        <Button variant="outline" size="sm" onClick={() => setAdjustDialogOpen(true)}>
          <Scale className="mr-1.5 h-3.5 w-3.5" />
          Registrar ajuste
        </Button>
      </div>

      <LedgerMovementsPanel config={bookConfig} scopeKey={bankAccountId} refreshToken={refreshToken} />

      <LedgerAdjustmentDialog
        open={adjustDialogOpen}
        onOpenChange={setAdjustDialogOpen}
        mode="bank"
        canSubmit
        isSubmitting={registerMovement.isPending}
        onConfirm={handleAdjustment}
      />
    </div>
  )
}

// ── Tab: Conciliación — contenido de la ex /finanzas/conciliacion, intacto ──

function ConciliacionTab({ bankAccountId }: { bankAccountId: string }) {
  const { data: sessions } = useReconciliationSessions(bankAccountId)
  const { data: imports } = useStatementImports(bankAccountId)
  const importStatement = useImportStatement(bankAccountId)
  const openSession = useOpenSession(bankAccountId)

  const fileInputRef = useRef<HTMLInputElement>(null)
  const [parsedFile, setParsedFile] = useState<{
    fileName: string
    fileHash: string
    lines: NormalizedStatementLine[]
  } | null>(null)

  const [openDialog, setOpenDialog] = useState(false)
  const [periodFrom, setPeriodFrom] = useState("")
  const [periodTo, setPeriodTo] = useState("")
  const [statementBalance, setStatementBalance] = useState("")

  const activeSession = useMemo(
    () => (sessions ?? []).find((s) => s.status === "open") ?? null,
    [sessions]
  )
  const closedSessions = useMemo(
    () => (sessions ?? []).filter((s) => s.status === "closed"),
    [sessions]
  )

  const handleFileChange = async (file: File | null) => {
    if (!file) return
    const parsed = await parseBankStatementFile(file)
    if (!parsed.ok) {
      toast.error(parsed.error)
      setParsedFile(null)
      return
    }
    const fileHash = await hashFileSHA256(file)
    setParsedFile({ fileName: file.name, fileHash, lines: parsed.lines })
  }

  const handleImport = async () => {
    if (!parsedFile) return
    try {
      const result = await importStatement.mutateAsync({
        idempotencyKey: `import-${parsedFile.fileHash.slice(0, 32)}`,
        fileName: parsedFile.fileName,
        fileHash: parsedFile.fileHash,
        lines: parsedFile.lines,
      })
      toast[result.replayed ? "info" : "success"](
        result.replayed
          ? "Este extracto ya estaba importado (sin duplicar)"
          : `Extracto importado: ${result.line_count} líneas (${result.period_from} → ${result.period_to})`
      )
      setParsedFile(null)
      if (fileInputRef.current) fileInputRef.current.value = ""
      if (result.period_from && result.period_to && !activeSession) {
        setPeriodFrom(result.period_from)
        setPeriodTo(result.period_to)
      }
    } catch (err) {
      toast.error((err as Error).message || "No se pudo importar el extracto")
    }
  }

  const handleOpenSession = async () => {
    try {
      await openSession.mutateAsync({ periodFrom, periodTo, statementClosingBalance: statementBalance })
      toast.success("Sesión de conciliación abierta")
      setOpenDialog(false)
    } catch (err) {
      toast.error(
        (err as Error).message || "No se pudo abrir la sesión (¿ya hay una abierta para esta cuenta?)"
      )
    }
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base">Importar extracto</CardTitle>
          <CardDescription>
            CSV con columnas de fecha e importe (descripción y saldo opcionales). Si el banco entrega
            Excel, guardalo como CSV antes de subir. Máximo 5.000 líneas.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Input
            ref={fileInputRef}
            type="file"
            accept=".csv,text/csv"
            onChange={(e) => handleFileChange(e.target.files?.[0] ?? null)}
          />
          {parsedFile && (
            <div className="flex items-center justify-between rounded-md border p-3 text-sm">
              <span>
                <b>{parsedFile.fileName}</b> · {parsedFile.lines.length} líneas ·{" "}
                {parsedFile.lines[0]?.value_date} → {parsedFile.lines.at(-1)?.value_date}
              </span>
              <Button size="sm" disabled={importStatement.isPending} onClick={handleImport}>
                Importar
              </Button>
            </div>
          )}
          {(imports ?? []).length > 0 && (
            <div className="text-xs text-muted-foreground">
              Últimos imports:{" "}
              {(imports ?? [])
                .slice(0, 3)
                .map((i) => `${i.file_name} (${i.line_count})`)
                .join(" · ")}
            </div>
          )}
        </CardContent>
      </Card>

      {activeSession ? (
        <ReconciliationBoard sessionId={activeSession.id} bankAccountId={bankAccountId} />
      ) : (
        <Card>
          <CardContent className="flex items-center justify-between p-4">
            <p className="text-sm text-muted-foreground">
              No hay una sesión de conciliación abierta para esta cuenta.
            </p>
            <Button onClick={() => setOpenDialog(true)}>Nueva conciliación</Button>
          </CardContent>
        </Card>
      )}

      {closedSessions.length > 0 && (
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-base">Sesiones cerradas</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1">
            {closedSessions.map((s) => (
              <div key={s.id} className="flex items-center justify-between rounded-md border p-2 text-sm">
                <span>
                  {s.periodFrom} → {s.periodTo} · extracto {fmtMoney(s.statementClosingBalance)} · sistema{" "}
                  {s.ledgerClosingBalance !== null ? fmtMoney(s.ledgerClosingBalance) : "—"}
                </span>
                <Badge variant={s.difference === 0 ? "secondary" : "destructive"}>
                  {s.difference === 0 ? "Sin diferencia" : `Dif. ${fmtMoney(s.difference ?? 0)}`}
                </Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      <Dialog open={openDialog} onOpenChange={setOpenDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Nueva conciliación</DialogTitle>
            <DialogDescription>
              Definí el período y el saldo final que muestra el extracto del banco. Solo puede haber una
              sesión abierta por cuenta.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <Label htmlFor="period-from">Desde</Label>
                <Input id="period-from" type="date" value={periodFrom} onChange={(e) => setPeriodFrom(e.target.value)} />
              </div>
              <div className="space-y-1">
                <Label htmlFor="period-to">Hasta</Label>
                <Input id="period-to" type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} />
              </div>
            </div>
            <div className="space-y-1">
              <Label htmlFor="statement-balance">Saldo final del extracto</Label>
              <Input
                id="statement-balance"
                type="number"
                step="0.01"
                value={statementBalance}
                onChange={(e) => setStatementBalance(e.target.value)}
                placeholder="Ej: 14750.00"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpenDialog(false)}>
              Cancelar
            </Button>
            <Button
              disabled={!periodFrom || !periodTo || statementBalance === "" || openSession.isPending}
              onClick={handleOpenSession}
            >
              Abrir sesión
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
