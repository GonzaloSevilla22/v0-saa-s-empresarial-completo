/**
 * lib/accounts.ts — las cuentas del usuario tal como las devuelve
 * `rpc_my_accounts()`.
 *
 * multiusuario-operativo (tanda A, D5). Un usuario puede pertenecer a más de una
 * cuenta (su cuenta personal y el negocio al que lo invitaron). La RPC devuelve una
 * fila por membresía con la ACTIVA marcada — la que resuelve `current_account_ids()`
 * en la base, la misma que ve FastAPI y la RLS —, el rol propio en cada una, el
 * estado de billing y los campos CRUDOS del nombre.
 *
 * Pura — sin React, sin fetch. Lo que NO se inventa acá:
 *   - el nombre visible: lo calcula `previewIssuer` (`lib/document-branding.ts`), la
 *     cascada de los documentos comerciales, atada a
 *     `backend/services/commercial_documents/issuer.py` por un fixture compartido. SQL
 *     no calcula el nombre justamente para que no nazca una tercera cascada;
 *   - la cuenta activa: viene marcada por la base (`is_active`). Si ninguna lo está
 *     (un token que declara una cuenta de la que el usuario ya no es miembro), el
 *     resultado es `null` — NUNCA se elige otra en silencio.
 */
import { emptyBrandingForm, previewIssuer } from "@/lib/document-branding"
import type { BillingStatus, OrgRole, Plan } from "@/lib/types"

/** Una fila cruda de `rpc_my_accounts()`. */
export interface MyAccountRow {
  account_id: string
  is_active: boolean
  is_owner: boolean
  member_role: string
  roles: string[] | null
  brand_display_name: string | null
  fiscal_nombre_fantasia: string | null
  fiscal_razon_social: string | null
  brand_legal_name: string | null
  owner_business_name: string | null
  billing_plan: string
  billing_status: string
  trial_plan: string | null
  trial_started_at: string | null
  trial_expires_at: string | null
  plan_expires_at: string | null
  billing_exempt: boolean | null
  effective_plan: string
  created_at: string
}

/** Una cuenta del usuario, lista para el contexto y el selector. */
export interface AccountSummary {
  accountId: string
  /** La cuenta activa: la que resuelve `current_account_ids()`. */
  isActive: boolean
  isOwner: boolean
  /** `account_members.role` (derivado singular legacy: owner / admin / member). */
  memberRole: OrgRole
  /** Roles ACTIVOS del usuario en esta cuenta (vencidos excluidos). */
  roles: string[]
  /** Nombre visible, con la cascada de los documentos comerciales. */
  displayName: string
  billingPlan: Plan
  billingStatus: BillingStatus
  trialPlan?: Plan
  trialStartedAt?: string
  trialExpiresAt?: string
  planExpiresAt?: string
  billingExempt: boolean
  effectivePlan: Plan
}

function isRow(value: unknown): value is MyAccountRow {
  if (typeof value !== "object" || value === null) return false
  const row = value as Record<string, unknown>
  return typeof row.account_id === "string" && row.account_id !== ""
}

function nullToUndefined<T>(value: T | null | undefined): T | undefined {
  return value === null || value === undefined ? undefined : value
}

/** El nombre visible de una cuenta: misma cascada que los papeles. */
function displayNameOf(row: MyAccountRow): string {
  const form = emptyBrandingForm()
  form.display_name = row.brand_display_name ?? ""
  form.legal_name = row.brand_legal_name ?? ""
  return previewIssuer(
    form,
    {
      razon_social: row.fiscal_razon_social,
      nombre_fantasia: row.fiscal_nombre_fantasia,
      cuit: null,
      domicilio_comercial: null,
      iva_condition: null,
    },
    { business_name: row.owner_business_name, phone: null },
  ).issuer.name
}

/**
 * Convierte la respuesta cruda de `rpc_my_accounts()`. Tolera lo que no es una lista
 * y descarta las filas sin cuenta: la pantalla nunca debe romper por una respuesta rara.
 */
export function parseMyAccounts(raw: unknown): AccountSummary[] {
  if (!Array.isArray(raw)) return []
  return raw.filter(isRow).map((row) => ({
    accountId: row.account_id,
    isActive: row.is_active === true,
    isOwner: row.is_owner === true,
    memberRole: (row.member_role as OrgRole) ?? "member",
    roles: Array.isArray(row.roles) ? row.roles : [],
    displayName: displayNameOf(row),
    billingPlan: row.billing_plan as Plan,
    billingStatus: row.billing_status as BillingStatus,
    trialPlan: nullToUndefined(row.trial_plan) as Plan | undefined,
    trialStartedAt: nullToUndefined(row.trial_started_at),
    trialExpiresAt: nullToUndefined(row.trial_expires_at),
    planExpiresAt: nullToUndefined(row.plan_expires_at),
    billingExempt: row.billing_exempt === true,
    effectivePlan: row.effective_plan as Plan,
  }))
}

/** La cuenta activa, o `null` si ninguna lo está. Nunca elige otra por su cuenta. */
export function getActiveAccount(accounts: readonly AccountSummary[]): AccountSummary | null {
  return accounts.find((account) => account.isActive) ?? null
}
