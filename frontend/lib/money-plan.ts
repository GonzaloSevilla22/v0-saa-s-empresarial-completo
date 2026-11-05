/**
 * edicion-operaciones-con-dinero (tanda C, D13/D17) — la ÚNICA redacción del plan de dinero.
 *
 * El plan de una edición lo calcula el SERVIDOR (`_op_edit_plan`, la misma función en la vista previa y en la
 * edición real): por libro —cuenta corriente, caja y banco— qué se compensa y qué se registra, y los bloqueos de
 * negocio como datos. La interfaz NO recalcula nada: sólo lo escribe en lenguaje del usuario. Este módulo lo consumen el
 * diálogo de confirmación de la edición (`OperationEditPlanDialog`), el de borrado (`DeleteOperationDialog`, que
 * comparte el texto del comprobante que se anula) y el historial de cambios (`OperationEditHistory`).
 *
 * El SENTIDO del dinero sale del signo del importe que mandó el servidor: en caja y banco, un importe positivo es un
 * ingreso y uno negativo una salida; compensar un movimiento es hacer lo opuesto a su neto. Los importes viajan sin
 * signo en el texto —el sentido lo dice el verbo ("entran", "salen", "vuelven")—.
 */

import { formatDate, formatMoney } from "@/lib/format"

/** Decimal del servidor: Pydantic v2 serializa `Decimal` como string. */
export type Amount = number | string

export type PlanAction = "none" | "register" | "reverse" | "both"

export interface MoneyPlanBlock {
  /** `account`, `cash`, `bank` o `role`. */
  book: string
  /** SQLSTATE del rechazo (`P0426`, `P0425`, `P0424`, `P0403`…). */
  code: string
  /** Token estable (`no_open_session_for_reversal`, `reversal_would_go_negative`…). */
  token: string
  /** Mensaje del servidor, con el token delante: `token: texto`. */
  message: string
}

export interface MoneyPlanAccount {
  action: PlanAction
  party_kind: "customer" | "supplier" | null
  party_id?: string | null
  target_ledger?: string | null
  register: { party_id?: string | null; amount: Amount; due_date: string | null; reference_id?: string | null } | null
  reverse: Array<{ ledger_id?: string | null; net: Amount; reference_id?: string | null }>
  current_balance: Amount | null
  projected_balance: Amount | null
  current_due_date: string | null
}

export interface MoneyPlanCash {
  action: PlanAction
  register: { session_id?: string | null; cashbox_id?: string | null; amount: Amount; reference_id?: string | null; movement_type?: string | null } | null
  reverse: Array<{ cashbox_id?: string | null; session_id?: string | null; net: Amount; reference_id?: string | null; movement_type?: string | null }>
}

export interface MoneyPlanBank {
  action: PlanAction
  register: { bank_account_id?: string | null; amount: Amount; family?: string | null; reference_id?: string | null; value_date?: string | null } | null
  reverse: Array<{ bank_account_id?: string | null; family?: string | null; net: Amount; mirror_type?: string | null; reference_id?: string | null; branch_id?: string | null }>
}

/** El plan de dinero de una edición, tal como lo devuelve el servidor (`MoneyEditPlanOut`). */
export interface MoneyPlan {
  writes_money: boolean
  blocks: MoneyPlanBlock[]
  account: MoneyPlanAccount
  cash: MoneyPlanCash
  bank: MoneyPlanBank
}

/** El comprobante pendiente que la edición anula (`VoidedFiscalDocumentOut`). */
export interface VoidedFiscalDocument {
  fiscal_document_id: string
  punto_de_venta: number
  number: number
  /** "0003-00000005" — formateado por el servidor. */
  label: string
}

/** Respuesta de `POST .../edit-preview`. */
export interface EditPreview {
  dry_run: boolean
  plan: MoneyPlan
  voided_fiscal_document: VoidedFiscalDocument | null
}

/** Contraparte de la cuenta corriente: sólo cambia la redacción. */
export interface MoneyPlanContext {
  party: "cliente" | "proveedor"
}

export type MoneyPlanBook = "account" | "cash" | "bank" | "fiscal"

export interface MoneyPlanItem {
  book: MoneyPlanBook
  text: string
}

const num = (value: Amount | null | undefined): number => Number(value ?? 0)
const money = (value: Amount): string => formatMoney(Math.abs(num(value)))

/** Única redacción del comprobante pendiente que una edición o un borrado anula. */
export function voidedFiscalText(label: string): string {
  return `Se anulará el comprobante pendiente ${label} (todavía no se envió a ARCA). Podés volver a emitirlo después.`
}

function accountItems(account: MoneyPlanAccount, party: MoneyPlanContext["party"]): MoneyPlanItem[] {
  const items: MoneyPlanItem[] = []
  const reversed = account.reverse.reduce((sum, row) => sum + num(row.net), 0)
  if ((account.action === "reverse" || account.action === "both") && account.reverse.length > 0) {
    items.push({
      book: "account",
      text: `Se revertirá el cargo de ${money(reversed)} registrado en la cuenta corriente del ${party}.`,
    })
  }
  if ((account.action === "register" || account.action === "both") && account.register) {
    const due = account.register.due_date
      ? `con vencimiento el ${formatDate(account.register.due_date)}`
      : "sin vencimiento"
    items.push({
      book: "account",
      text: `Se registrará un cargo de ${money(account.register.amount)} en la cuenta corriente del ${party}, ${due}.`,
    })
  }
  if (items.length > 0 && account.current_balance != null && account.projected_balance != null) {
    items.push({
      book: "account",
      text: `Saldo de la cuenta corriente: ${formatMoney(num(account.current_balance))} → ${formatMoney(num(account.projected_balance))}.`,
    })
  }
  return items
}

function cashItems(cash: MoneyPlanCash): MoneyPlanItem[] {
  const items: MoneyPlanItem[] = []
  if (cash.action === "reverse" || cash.action === "both") {
    for (const row of cash.reverse) {
      // Compensar es lo opuesto al neto: lo que había entrado ahora sale, y al revés.
      const comp = -num(row.net)
      if (comp === 0) continue
      items.push({
        book: "cash",
        text: comp < 0
          ? `Salen ${money(comp)} de la caja (se compensa lo que había entrado), en la sesión abierta.`
          : `Vuelven ${money(comp)} a la caja (se compensa lo que había salido), en la sesión abierta.`,
      })
    }
  }
  if ((cash.action === "register" || cash.action === "both") && cash.register) {
    const amount = num(cash.register.amount)
    items.push({
      book: "cash",
      text: amount >= 0 ? `Entran ${money(amount)} a la caja.` : `Salen ${money(amount)} de la caja.`,
    })
  }
  return items
}

function bankItems(bank: MoneyPlanBank): MoneyPlanItem[] {
  const items: MoneyPlanItem[] = []
  if (bank.action === "reverse" || bank.action === "both") {
    for (const row of bank.reverse) {
      const comp = -num(row.net)
      if (comp === 0) continue
      items.push({
        book: "bank",
        text: comp > 0
          ? `Se acreditan ${money(comp)} en la cuenta bancaria como movimiento inverso, pendiente de conciliar.`
          : `Se debitan ${money(comp)} de la cuenta bancaria como movimiento inverso, pendiente de conciliar.`,
      })
    }
  }
  if ((bank.action === "register" || bank.action === "both") && bank.register) {
    const amount = num(bank.register.amount)
    items.push({
      book: "bank",
      text: amount >= 0
        ? `Se registra un ingreso de ${money(amount)} en la cuenta bancaria, pendiente de conciliar.`
        : `Se registra un egreso de ${money(amount)} en la cuenta bancaria, pendiente de conciliar.`,
    })
  }
  return items
}

/** ¿El plan escribe en algún libro? */
export function moneyPlanHasEffect(plan: MoneyPlan | null | undefined): boolean {
  if (!plan) return false
  return plan.account.action !== "none" || plan.cash.action !== "none" || plan.bank.action !== "none"
}

/** El plan por libro, en el orden de la edición: cuenta corriente → caja → banco. */
export function moneyPlanItems(plan: MoneyPlan, ctx: MoneyPlanContext): MoneyPlanItem[] {
  return [...accountItems(plan.account, ctx.party), ...cashItems(plan.cash), ...bankItems(plan.bank)]
}

/** Quita el prefijo técnico `token: ` de un mensaje del servidor. */
function stripToken(token: string, message: string): string {
  const prefix = `${token}:`
  return message.startsWith(prefix) ? message.slice(prefix.length).trim() : message.trim()
}

/** El motivo de un bloqueo del plan, en lenguaje del usuario. Un token que no conoce usa el mensaje del servidor. */
export function describeBlock(block: MoneyPlanBlock, ctx: Partial<MoneyPlanContext> = {}): string {
  switch (block.token) {
    case "no_open_session_for_reversal":
      return "Abrí la caja para poder corregir esta operación: el efectivo ya registrado se compensa en la sesión abierta de la misma caja."
    case "reversal_would_go_negative": {
      const match = block.message.match(/quedar[ií]a en (-?\d+(?:\.\d+)?)/)
      const quedaria = match ? ` en ${formatMoney(Number(match[1]))}` : " en negativo"
      const pago = ctx.party === "proveedor" ? "pago" : "cobro"
      return `La cuenta corriente quedaría${quedaria}: ya se registraron ${pago}s por esta operación. Anulá primero el ${pago} desde la cuenta corriente y volvé a editar.`
    }
    case "bank_period_reconciled":
      return "La fecha cae en un período conciliado y cerrado de la cuenta bancaria. Registrá el ajuste como movimiento bancario manual."
    case "money_edit_requires_admin":
      return "Solo el dueño o un administrador pueden corregir dinero ya registrado: esta edición modifica la caja, el banco o la cuenta corriente."
    case "cash_intent_required":
      return "Cambió la sucursal y puede tener varias cajas: indicá en qué sesión de caja se registra el efectivo."
    default:
      return stripToken(block.token, block.message)
  }
}

/** Una línea con lo que el SERVIDOR dijo que hizo (para el aviso posterior al guardado). `null` si no tocó ningún libro. */
export function summarizeExecutedPlan(plan: MoneyPlan | null | undefined, ctx: MoneyPlanContext): string | null {
  if (!plan || !moneyPlanHasEffect(plan)) return null
  const items = moneyPlanItems(plan, ctx).filter((item) => !item.text.startsWith("Saldo de la cuenta"))
  return items.length > 0 ? items.map((item) => item.text).join(" ") : null
}

export type EditedDocument = "venta" | "compra" | "gasto"

export interface EditHistorySource {
  before: Record<string, unknown> | null
  after: Record<string, unknown> | null
  money: MoneyPlan | null
  reason: string | null
}

const asNumber = (value: unknown): number | null => {
  if (value === null || value === undefined || value === "") return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

/** El resumen de una entrada del historial: qué cambió de importe y fecha, qué libros tocó y el motivo. */
export function summarizeEdit(entry: EditHistorySource, document: EditedDocument): string {
  const amountKey = document === "gasto" ? "amount" : "total"
  const amountLabel = document === "gasto" ? "Importe" : "Total"
  const parts: string[] = []

  const before = asNumber(entry.before?.[amountKey])
  const after = asNumber(entry.after?.[amountKey])
  if (before !== null && after !== null && before !== after) {
    parts.push(`${amountLabel} ${formatMoney(before)} → ${formatMoney(after)}`)
  }

  const dateBefore = entry.before?.date
  const dateAfter = entry.after?.date
  if (typeof dateBefore === "string" && typeof dateAfter === "string" && dateBefore !== dateAfter) {
    parts.push(`Fecha ${formatDate(dateBefore)} → ${formatDate(dateAfter)}`)
  }

  if (entry.money) {
    const ctx: MoneyPlanContext = { party: document === "venta" ? "cliente" : "proveedor" }
    const items = moneyPlanItems(entry.money, ctx).filter((item) => !item.text.startsWith("Saldo de la cuenta"))
    for (const item of items) parts.push(item.text.replace(/\.$/, ""))
  }

  const summary = parts.length > 0 ? `${parts.join("; ")}.` : "Sin cambios de importe ni de fecha."
  return entry.reason ? `${summary} Motivo: ${entry.reason}` : summary
}
