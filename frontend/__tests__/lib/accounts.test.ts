/**
 * multiusuario-operativo tanda A (D5) — `lib/accounts.ts`: la lista de cuentas del
 * usuario tal como la devuelve `rpc_my_accounts()`.
 *
 * La RPC devuelve los campos CRUDOS del nombre (marca, perfil fiscal, dueño); el
 * nombre visible lo calcula `previewIssuer` (`lib/document-branding.ts`), la misma
 * cascada que usan los papeles — así no nace una tercera. Este archivo fija que el
 * selector de cuenta no tiene un criterio de nombre propio.
 */
import { describe, it, expect } from "vitest"
import { getActiveAccount, parseMyAccounts, type MyAccountRow } from "@/lib/accounts"
import { DEFAULT_ISSUER_NAME } from "@/lib/document-branding"

function row(overrides: Partial<MyAccountRow> = {}): MyAccountRow {
  return {
    account_id: "acc-1",
    is_active: true,
    is_owner: true,
    member_role: "owner",
    roles: ["owner"],
    brand_display_name: null,
    fiscal_nombre_fantasia: null,
    fiscal_razon_social: null,
    brand_legal_name: null,
    owner_business_name: null,
    billing_plan: "inicial",
    billing_status: "active",
    trial_plan: null,
    trial_started_at: null,
    trial_expires_at: null,
    plan_expires_at: null,
    billing_exempt: false,
    effective_plan: "inicial",
    created_at: "2026-01-01T00:00:00.000Z",
    ...overrides,
  }
}

describe("parseMyAccounts — el nombre visible usa la cascada de los documentos", () => {
  it("el nombre comercial de la marca manda sobre todo lo demás", () => {
    const [a] = parseMyAccounts([
      row({
        brand_display_name: "Kiosco Sol",
        fiscal_nombre_fantasia: "Fantasía fiscal",
        fiscal_razon_social: "Razón social SRL",
        brand_legal_name: "Legal de marca",
        owner_business_name: "Negocio del dueño",
      }),
    ])
    expect(a.displayName).toBe("Kiosco Sol")
  })

  it("sin marca: nombre de fantasía fiscal, después razón social, después razón social de la marca, después el negocio del dueño", () => {
    expect(parseMyAccounts([row({ fiscal_nombre_fantasia: "Fantasía", fiscal_razon_social: "Razón" })])[0].displayName).toBe("Fantasía")
    expect(parseMyAccounts([row({ fiscal_razon_social: "Razón", brand_legal_name: "Legal" })])[0].displayName).toBe("Razón")
    expect(parseMyAccounts([row({ brand_legal_name: "Legal", owner_business_name: "Dueño" })])[0].displayName).toBe("Legal")
    expect(parseMyAccounts([row({ owner_business_name: "Dueño" })])[0].displayName).toBe("Dueño")
  })

  it("sin ningún dato: el nombre por defecto de los papeles", () => {
    expect(parseMyAccounts([row()])[0].displayName).toBe(DEFAULT_ISSUER_NAME)
  })

  it("los espacios en blanco no cuentan como nombre", () => {
    expect(parseMyAccounts([row({ brand_display_name: "   ", owner_business_name: "Dueño" })])[0].displayName).toBe("Dueño")
  })
})

describe("parseMyAccounts — forma del resultado", () => {
  it("mapea cuenta, rol, plan y estado activo", () => {
    const accounts = parseMyAccounts([
      row({ account_id: "p", is_active: false, member_role: "owner", roles: ["owner"], effective_plan: "inicial" }),
      row({
        account_id: "a",
        is_active: true,
        is_owner: false,
        member_role: "member",
        roles: ["seller", "cashier"],
        billing_plan: "avanzado",
        effective_plan: "avanzado",
        created_at: "2026-02-01T00:00:00.000Z",
      }),
    ])
    expect(accounts).toHaveLength(2)
    expect(accounts[1]).toMatchObject({
      accountId: "a",
      isActive: true,
      isOwner: false,
      memberRole: "member",
      roles: ["seller", "cashier"],
      billingPlan: "avanzado",
      effectivePlan: "avanzado",
    })
  })

  it("roles null (sin asignaciones vigentes) se normaliza a lista vacía", () => {
    expect(parseMyAccounts([row({ roles: null })])[0].roles).toEqual([])
  })

  it("una respuesta que no es una lista, o con filas sin cuenta, no rompe: se descartan", () => {
    expect(parseMyAccounts(null)).toEqual([])
    expect(parseMyAccounts({ oops: true })).toEqual([])
    expect(parseMyAccounts([null, 3, { is_active: true }, row()])).toHaveLength(1)
  })
})

describe("getActiveAccount", () => {
  it("devuelve la cuenta marcada como activa", () => {
    const accounts = parseMyAccounts([row({ account_id: "p", is_active: false }), row({ account_id: "a", is_active: true })])
    expect(getActiveAccount(accounts)?.accountId).toBe("a")
  })

  it("devuelve null si ninguna está activa (token con una cuenta revocada): NUNCA elige otra en silencio", () => {
    const accounts = parseMyAccounts([row({ account_id: "p", is_active: false }), row({ account_id: "a", is_active: false })])
    expect(getActiveAccount(accounts)).toBeNull()
  })

  it("devuelve null con una lista vacía", () => {
    expect(getActiveAccount([])).toBeNull()
  })
})
