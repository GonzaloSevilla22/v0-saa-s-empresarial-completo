/**
 * multiusuario-operativo TANDA B (10.3) — capacidades de ventas y compras en el frontend.
 *
 * Las ventas y las compras se autorizan por la CAPACIDAD DE ROL de la cuenta activa:
 *   - `CAN_SELL`  (dueño, administrador, vendedor, cajero) — vender, y editar / borrar ventas;
 *   - `CAN_PURCHASE` (dueño, administrador, compras) — comprar, y editar / borrar compras. El
 *     depósito NO compra (OQ-3 b): recibe mercadería por remito;
 *   - `CAN_MODIFY_ANY_DOCUMENT` (dueño, administrador) — la regla de autor (OQ-4 b): sobre un
 *     documento de OTRO miembro sólo ellos; el resto modifica lo que cargó.
 *
 * El backend y la base son la autoridad; el frontend sólo decide qué MOSTRAR. Por eso cada
 * conjunto está atado por test al de `backend/core/rbac.py` y a los `ARRAY[...]` de la
 * migración 20261083000001, y la decisión por documento (`canModifyDocument`) se prueba acá.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  CAN_MODIFY_ANY_DOCUMENT,
  CAN_PURCHASE,
  CAN_SELL,
  canModifyDocument,
  hasCapability,
} from "@/lib/rbac-capabilities"
import type { OrgRole } from "@/lib/types"

const ROOT = path.resolve(__dirname, "../../..")

function pythonCapability(name: string): string[] | null {
  const source = fs.readFileSync(path.join(ROOT, "backend/core/rbac.py"), "utf-8")
  const match = new RegExp(`^${name}\\b[^=]*=\\s*frozenset\\(\\{([^}]*)\\}\\)`, "m").exec(source)
  if (!match) return null
  return [...match[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]).sort()
}

const MIGRATION = fs.readFileSync(
  path.join(ROOT, "supabase/migrations/20261083000001_multiusuario_operaciones.sql"),
  "utf-8",
)

/** Los `ARRAY[...]` que cada función pasa a `_account_assert_capability(v_account_id, ARRAY[...], …)`. */
function capabilityArrays(fn: string): string[][] {
  const section = new RegExp(`CREATE OR REPLACE FUNCTION public\\.${fn}\\([\\s\\S]*?\\n\\$function\\$;`).exec(MIGRATION)
  expect(section, `${fn} no está en la migración`).not.toBeNull()
  return [...section![0].matchAll(/_account_assert_capability\(\s*v_account_id,\s*ARRAY\[([^\]]*)\]/g)].map((m) =>
    [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]).sort(),
  )
}

describe("CAN_SELL / CAN_PURCHASE — atados al backend y a la base", () => {
  it("CAN_SELL es dueño, administrador, vendedor y cajero", () => {
    expect([...CAN_SELL].sort()).toEqual(["admin", "cashier", "owner", "seller"])
  })

  it("CAN_PURCHASE es dueño, administrador y compras (el depósito NO compra: OQ-3)", () => {
    expect([...CAN_PURCHASE].sort()).toEqual(["admin", "owner", "purchases"])
    expect(CAN_PURCHASE).not.toContain("stock")
  })

  it("coinciden con CAN_SELL y CAN_PURCHASE de backend/core/rbac.py", () => {
    expect([...CAN_SELL].sort()).toEqual(pythonCapability("CAN_SELL"))
    expect([...CAN_PURCHASE].sort()).toEqual(pythonCapability("CAN_PURCHASE"))
  })

  it.each([
    "rpc_create_sale_operation",
    "rpc_create_sale_operation_v2",
    "rpc_atomic_update_sale_operation",
    "rpc_delete_sale_operation",
  ])("%s exige exactamente CAN_SELL en la migración", (fn) => {
    const arrays = capabilityArrays(fn)
    expect(arrays.length).toBeGreaterThan(0)
    for (const roles of arrays) expect(roles).toEqual([...CAN_SELL].sort())
  })

  it.each([
    "rpc_create_purchase_operation",
    "rpc_create_purchase_operation_v2",
    "rpc_atomic_update_purchase_operation",
    "rpc_delete_purchase_operation",
  ])("%s exige exactamente CAN_PURCHASE en la migración", (fn) => {
    const arrays = capabilityArrays(fn)
    expect(arrays.length).toBeGreaterThan(0)
    for (const roles of arrays) expect(roles).toEqual([...CAN_PURCHASE].sort())
  })
})

describe("CAN_MODIFY_ANY_DOCUMENT — la regla de autor (OQ-4 b)", () => {
  it("es dueño y administrador", () => {
    expect([...CAN_MODIFY_ANY_DOCUMENT].sort()).toEqual(["admin", "owner"])
  })

  it("coincide con backend/core/rbac.py", () => {
    expect([...CAN_MODIFY_ANY_DOCUMENT].sort()).toEqual(pythonCapability("CAN_MODIFY_ANY_DOCUMENT"))
  })

  it("coincide con el ARRAY de _account_assert_document_authority en la migración", () => {
    const section = /CREATE OR REPLACE FUNCTION public\._account_assert_document_authority\([\s\S]*?\n\$function\$;/.exec(MIGRATION)
    expect(section).not.toBeNull()
    const array = /&&\s*ARRAY\[([^\]]*)\]/.exec(section![0])
    expect(array).not.toBeNull()
    expect([...array![1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort()).toEqual([...CAN_MODIFY_ANY_DOCUMENT].sort())
  })
})

describe("canModifyDocument — editar y eliminar una venta o una compra", () => {
  const ME = "user-me"
  const OTHER = "user-other"
  const decide = (roles: OrgRole[], capability: readonly OrgRole[], author: string | null | undefined, resolved = true) =>
    canModifyDocument({ roles, rolesResolved: resolved, capability, authorId: author, userId: ME })

  it("sin la capacidad del dominio no se ofrece nada, ni siquiera sobre lo propio", () => {
    expect(decide(["viewer"], CAN_SELL, ME)).toBe(false)
    expect(decide(["stock"], CAN_SELL, ME)).toBe(false)
    expect(decide(["seller"], CAN_PURCHASE, ME)).toBe(false)
    expect(decide(["stock"], CAN_PURCHASE, ME)).toBe(false)
  })

  it("el vendedor y el cajero modifican lo propio pero no lo del dueño ni lo de otro", () => {
    for (const role of ["seller", "cashier"] as const) {
      expect(decide([role], CAN_SELL, ME), `${role} propia`).toBe(true)
      expect(decide([role], CAN_SELL, OTHER), `${role} ajena`).toBe(false)
    }
  })

  it("compras modifica lo propio pero no lo ajeno", () => {
    expect(decide(["purchases"], CAN_PURCHASE, ME)).toBe(true)
    expect(decide(["purchases"], CAN_PURCHASE, OTHER)).toBe(false)
  })

  it("dueño y administrador modifican cualquiera", () => {
    for (const role of ["owner", "admin"] as const) {
      expect(decide([role], CAN_SELL, OTHER), role).toBe(true)
      expect(decide([role], CAN_PURCHASE, OTHER), role).toBe(true)
    }
  })

  it("un multirol (vendedor + compras) modifica lo propio de los dos dominios y nada ajeno", () => {
    expect(decide(["seller", "purchases"], CAN_SELL, ME)).toBe(true)
    expect(decide(["seller", "purchases"], CAN_PURCHASE, ME)).toBe(true)
    expect(decide(["seller", "purchases"], CAN_SELL, OTHER)).toBe(false)
  })

  it("sin dato de autoría no se oculta: la base decide (P0403)", () => {
    expect(decide(["seller"], CAN_SELL, null)).toBe(true)
    expect(decide(["seller"], CAN_SELL, undefined)).toBe(true)
  })

  it("con el conjunto de roles sin resolver la decisión es optimista (la barrera real es la base)", () => {
    expect(decide(["member"], CAN_SELL, OTHER, false)).toBe(true)
  })

  it("hasCapability sigue siendo la intersección", () => {
    expect(hasCapability(["seller", "stock"], CAN_PURCHASE, true)).toBe(false)
    expect(hasCapability(["stock", "purchases"], CAN_PURCHASE, true)).toBe(true)
  })
})
