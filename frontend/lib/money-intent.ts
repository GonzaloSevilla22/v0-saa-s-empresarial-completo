/**
 * edicion-operaciones-con-dinero (tanda C, D6/D7/D9) — las intenciones de dinero de una edición.
 *
 * Contrato tri-estado por AUSENCIA, el mismo de `payment_method_id`/`branch_id`: una clave ausente significa
 * "conservar el efecto vigente"; presente —incluso con `null`— es una intención explícita ("sacar de la caja", "volver al
 * destino configurado", "sin vencimiento"). El servidor lo resuelve con `model_fields_set`. Por eso el formulario manda
 * `cash_session_id`, `bank_account_id` y `due_date` SÓLO cuando el usuario cambió algo: reenviar el valor vigente
 * "por las dudas" sería una intención nueva (reimputar) y, para la caja, exigiría además que la fecha sea hoy.
 *
 * Es lógica pura, sin hooks: los tres formularios la comparten y se prueba sin montar nada.
 */

export interface EditCashInput {
  /** La forma de pago final de la edición es efectivo. */
  finalKindIsCash: boolean
  /** La operación ya tiene movimiento de caja vigente (huella neta). */
  hadCash: boolean
  /** Estado del tilde "Registrar en caja" (precargado con `hadCash`). */
  registerInCash: boolean
  /** La sucursal cambió respecto de la de la operación: la sesión vigente ya no es la de la caja nueva. */
  branchChanged: boolean
  /** Hay una sesión abierta en la sucursal efectiva. */
  eligible: boolean
  /** Sesión abierta de la sucursal efectiva. */
  sessionId: string | null
}

export interface EditBankInput {
  /** El usuario cambió el selector de cuenta bancaria. */
  touched: boolean
  /** La forma de pago final es bancaria (transferencia, tarjeta, billetera, cheque). */
  kindIsBank: boolean
  value: string | null
}

export interface EditDueInput {
  /** El usuario tocó el campo (también al vaciarlo). */
  touched: boolean
  /** La forma de pago final es a crédito. */
  isCredit: boolean
  value: string
}

export interface EditMoneyInput {
  cash: EditCashInput
  bank: EditBankInput
  due: EditDueInput
  reason: string
}

/** Las intenciones que viajan: una clave presente es una decisión del usuario. */
export interface EditMoneyIntent {
  cashSessionId?: string | null
  bankAccountId?: string | null
  dueDate?: string | null
  reason?: string
}

function cashIntent(cash: EditCashInput): Pick<EditMoneyIntent, "cashSessionId"> {
  // Sin efectivo como forma de pago final la caja no se pide: el plan compensa lo que haya.
  if (!cash.finalKindIsCash) return {}
  if (cash.registerInCash) {
    // Tildado y ya registrado en la misma sucursal: conservar. Sin sesión abierta no se inventa una intención:
    // el plan del servidor nombra el bloqueo.
    if (cash.hadCash && !cash.branchChanged) return {}
    if (!cash.eligible || !cash.sessionId) return {}
    return { cashSessionId: cash.sessionId }
  }
  // Destildado: sólo es una decisión si había algo que sacar de la caja.
  return cash.hadCash ? { cashSessionId: null } : {}
}

export function buildEditMoneyIntent(input: EditMoneyInput): EditMoneyIntent {
  const intent: EditMoneyIntent = { ...cashIntent(input.cash) }
  if (input.bank.touched && input.bank.kindIsBank) intent.bankAccountId = input.bank.value ?? null
  if (input.due.touched && input.due.isCredit) intent.dueDate = input.due.value || null
  const reason = input.reason.trim()
  if (reason) intent.reason = reason
  return intent
}

/** A las claves del contrato HTTP. JSON.stringify conserva `null` y las claves ausentes siguen ausentes. */
export function moneyIntentPayload(intent: EditMoneyIntent): Record<string, unknown> {
  const payload: Record<string, unknown> = {}
  if ("cashSessionId" in intent) payload.cash_session_id = intent.cashSessionId ?? null
  if ("bankAccountId" in intent) payload.bank_account_id = intent.bankAccountId ?? null
  if ("dueDate" in intent) payload.due_date = intent.dueDate ?? null
  if (intent.reason !== undefined) payload.reason = intent.reason
  return payload
}
