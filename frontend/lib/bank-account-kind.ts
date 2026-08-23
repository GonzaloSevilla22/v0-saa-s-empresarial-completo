import { Landmark, Wallet, type LucideIcon } from "lucide-react"
import type { BadgeProps } from "@/components/ui/badge"

/**
 * cuentas-billetera-tipo (D5) — módulo canónico único para presentar el tipo
 * de una cuenta bancaria (`account_kind`, `'bank' | 'wallet'`): etiqueta,
 * ícono y variante de badge.
 *
 * Precedente: `lib/product-stock.ts` (criticidad de stock) — se canonizó
 * después de que el mismo cálculo se reescribiera en cinco lugares. Acá se
 * canoniza DESDE EL PRIMER consumidor: hay al menos cinco superficies que
 * listan cuentas bancarias (`/banco`, `PaymentMethodManager`,
 * `PaymentMethodSelect`, `RegisterPaymentForm`, `RegisterPaymentMadeForm`) y
 * el `Landmark` hoy hardcodeado en `PaymentMethodManager` es exactamente el
 * tipo de divergencia que este módulo evita.
 *
 * Tokens semánticos vía `BadgeProps["variant"]` (default | secondary |
 * destructive | outline) — ningún color literal que evada el gate de
 * contraste AA (`token-contrast-aa.test.ts`).
 */
export type AccountKind = "bank" | "wallet"

interface AccountKindPresentation {
  label: string
  icon: LucideIcon
  badgeVariant: NonNullable<BadgeProps["variant"]>
}

const ACCOUNT_KIND_PRESENTATION: Record<AccountKind, AccountKindPresentation> = {
  bank: {
    label: "Banco",
    icon: Landmark,
    badgeVariant: "outline",
  },
  wallet: {
    label: "Billetera virtual",
    icon: Wallet,
    badgeVariant: "secondary",
  },
}

/**
 * Fuente única de etiqueta/ícono/badge para un `account_kind`. Fail-safe:
 * un valor no reconocido (dato legado o todavía no migrado) se presenta como
 * `'bank'` — nunca se oculta ni rompe el render (mismo criterio fail-open que
 * `holdsOwnStock` en `lib/product-stock.ts`).
 */
export function getAccountKindPresentation(kind: AccountKind | string | null | undefined): AccountKindPresentation {
  return ACCOUNT_KIND_PRESENTATION[kind as AccountKind] ?? ACCOUNT_KIND_PRESENTATION.bank
}

export function getAccountKindLabel(kind: AccountKind | string | null | undefined): string {
  return getAccountKindPresentation(kind).label
}

export function getAccountKindIcon(kind: AccountKind | string | null | undefined): LucideIcon {
  return getAccountKindPresentation(kind).icon
}

export function getAccountKindBadgeVariant(kind: AccountKind | string | null | undefined): NonNullable<BadgeProps["variant"]> {
  return getAccountKindPresentation(kind).badgeVariant
}

// ── Etiquetas del formulario de alta por tipo (D3) ──────────────────────────
// El formulario reutiliza los mismos campos (bank_name, cbu) para ambos
// tipos — solo cambian los rótulos: 'bank_name' → "Billetera" / "Banco",
// 'cbu' → "CVU" / "CBU". Sin columnas nuevas, sin ocultar campos.

interface AccountKindFormLabels {
  dialogTitle: string
  issuerLabel: string
  issuerPlaceholder: string
  cbuLabel: string
}

const ACCOUNT_KIND_FORM_LABELS: Record<AccountKind, AccountKindFormLabels> = {
  bank: {
    dialogTitle: "Nueva cuenta bancaria",
    issuerLabel: "Banco (opcional)",
    issuerPlaceholder: "Ej: Banco Galicia",
    cbuLabel: "CBU (opcional)",
  },
  wallet: {
    dialogTitle: "Nueva billetera virtual",
    issuerLabel: "Billetera (opcional)",
    issuerPlaceholder: "Ej: Mercado Pago",
    cbuLabel: "CVU (opcional)",
  },
}

export function getAccountKindFormLabels(kind: AccountKind): AccountKindFormLabels {
  return ACCOUNT_KIND_FORM_LABELS[kind] ?? ACCOUNT_KIND_FORM_LABELS.bank
}
