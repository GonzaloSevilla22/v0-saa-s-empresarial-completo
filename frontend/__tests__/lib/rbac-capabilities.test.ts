/**
 * presupuestos-modulo (D11, task 4.8) — `lib/rbac-capabilities.ts`: el espejo
 * canónico en el frontend de `CAN_QUOTE` de `backend/core/rbac.py`, y
 * `hasCapability(roles, cap, rolesResolved)`.
 *
 * El backend es la fuente de verdad; el espejo sólo decide qué mostrar. Por eso
 * está ATADO por test al conjunto de Python (lee el archivo, como los tests de
 * contrato existentes) y, además, al catálogo de la FSM: `CAN_QUOTE` es el
 * conjunto que `document_status_transitions.allowed_role` declara para las
 * transiciones de `quote`.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { CAN_CONFIGURE, CAN_QUOTE, CAN_STOCK, hasCapability } from "@/lib/rbac-capabilities"

const ROOT = path.resolve(__dirname, "../../..")

function pythonCapability(name: string): string[] | null {
  const source = fs.readFileSync(path.join(ROOT, "backend/core/rbac.py"), "utf-8")
  const match = new RegExp(`^${name}\\b[^=]*=\\s*frozenset\\(\\{([^}]*)\\}\\)`, "m").exec(source)
  if (!match) return null
  return [...match[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]).sort()
}

describe("CAN_QUOTE — atado al backend y a la FSM", () => {
  it("es owner, admin y seller", () => {
    expect([...CAN_QUOTE].sort()).toEqual(["admin", "owner", "seller"])
  })

  // `CAN_QUOTE` en `core/rbac.py` llega con la tanda de backend del mismo
  // change (tarea 2.2): mientras esa constante no esté en el árbol el contrato
  // contra Python no tiene contra qué compararse. El contrato contra la FSM de
  // abajo corre siempre.
  const python = pythonCapability("CAN_QUOTE")
  it.runIf(python !== null)("coincide con CAN_QUOTE de backend/core/rbac.py", () => {
    expect([...CAN_QUOTE].sort()).toEqual(python)
  })

  it("coincide con los allowed_role de las transiciones de quote que ejecuta un usuario (catálogo de la FSM)", () => {
    const sql = fs.readFileSync(
      path.join(ROOT, "supabase/migrations/20261048000001_v3_rbac_multirole_parte_b.sql"),
      "utf-8",
    )
    const rows = [...sql.matchAll(/ARRAY\[([^\]]*)\]\s+WHERE document_type = 'quote'\s+AND from_status(?: IS NULL| = '(\w+)')\s+AND to_status = '(\w+)'/g)]
    expect(rows.length).toBeGreaterThanOrEqual(6)
    for (const row of rows) {
      const roles = [...row[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort()
      expect(roles).toEqual([...CAN_QUOTE].sort())
    }
  })
})

describe("CAN_CONFIGURE — atado al backend (presupuestos-modulo, tarea 5.11)", () => {
  it("es owner y admin", () => {
    expect([...CAN_CONFIGURE].sort()).toEqual(["admin", "owner"])
  })

  it("coincide con CAN_CONFIGURE de backend/core/rbac.py", () => {
    expect([...CAN_CONFIGURE].sort()).toEqual(pythonCapability("CAN_CONFIGURE"))
  })

  it("un vendedor no configura la cuenta; un admin sí", () => {
    expect(hasCapability(["seller"], CAN_CONFIGURE, true)).toBe(false)
    expect(hasCapability(["admin"], CAN_CONFIGURE, true)).toBe(true)
  })
})

describe("CAN_STOCK — atado al backend y a la migración (stock-ledger-solo-rpc, task 11.1)", () => {
  /** Los roles que `_stock_assert_can_adjust` exige (ARRAY[...] de la migración de la tanda B). */
  function sqlAllowedRoles(): string[] {
    const sql = fs.readFileSync(
      path.join(ROOT, "supabase/migrations/20261074000001_stock_ledger_nucleo_ajuste_manual.sql"),
      "utf-8",
    )
    const fn = /FUNCTION public\._stock_assert_can_adjust\(p_account_id uuid\)[\s\S]*?\$function\$;/.exec(sql)
    expect(fn, "no se encontró _stock_assert_can_adjust en la migración").not.toBeNull()
    const array = /&&\s*ARRAY\[([^\]]*)\]/.exec(fn![0])
    expect(array, "no se encontró el ARRAY[...] de roles en _stock_assert_can_adjust").not.toBeNull()
    return [...array![1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort()
  }

  it("es owner, admin y stock (decisión 1 del PO, 2026-10-08)", () => {
    expect([...CAN_STOCK].sort()).toEqual(["admin", "owner", "stock"])
  })

  it("coincide con CAN_STOCK de backend/core/rbac.py", () => {
    expect([...CAN_STOCK].sort()).toEqual(pythonCapability("CAN_STOCK"))
  })

  it("coincide con el ARRAY[...] de _stock_assert_can_adjust en la migración 20261074000001 (la base exige lo mismo)", () => {
    expect([...CAN_STOCK].sort()).toEqual(sqlAllowedRoles())
  })

  it("los tres lados leen el mismo conjunto no vacío (un regex que no encuentra nada no puede dar verde)", () => {
    expect(pythonCapability("CAN_STOCK")).not.toBeNull()
    expect(sqlAllowedRoles().length).toBe(3)
  })

  it("seller, cashier, purchases, accountant y viewer no ajustan; owner, admin y stock sí", () => {
    for (const role of ["seller", "cashier", "purchases", "accountant", "viewer"] as const) {
      expect(hasCapability([role], CAN_STOCK, true), role).toBe(false)
    }
    for (const role of ["owner", "admin", "stock"] as const) {
      expect(hasCapability([role], CAN_STOCK, true), role).toBe(true)
    }
  })

  it("un miembro con varios roles ajusta si ALGUNO está en CAN_STOCK (intersección, no igualdad)", () => {
    expect(hasCapability(["seller", "stock"], CAN_STOCK, true)).toBe(true)
    expect(hasCapability(["seller", "cashier"], CAN_STOCK, true)).toBe(false)
  })

  it("con el conjunto sin resolver la decisión es optimista: la barrera real es la base", () => {
    expect(hasCapability(["member"], CAN_STOCK, false)).toBe(true)
  })
})

describe("hasCapability", () => {
  it("conjunto sin resolver (roles=['member'], rolesResolved=false) -> sí (fail-open, como isWriter)", () => {
    expect(hasCapability(["member"], CAN_QUOTE, false)).toBe(true)
  })

  it("sin resolver y sin roles -> también sí: no decide sobre un dato que no llegó", () => {
    expect(hasCapability([], CAN_QUOTE, false)).toBe(true)
  })

  it("resuelto sólo seller -> sí", () => {
    expect(hasCapability(["seller"], CAN_QUOTE, true)).toBe(true)
  })

  it("resuelto sólo cashier -> no", () => {
    expect(hasCapability(["cashier"], CAN_QUOTE, true)).toBe(false)
  })

  it("resuelto con varios roles, alguno habilitado -> sí (intersección, no igualdad)", () => {
    expect(hasCapability(["cashier", "stock", "admin"], CAN_QUOTE, true)).toBe(true)
  })

  it("resuelto y vacío -> no (sin ningún rol activo, como la base)", () => {
    expect(hasCapability([], CAN_QUOTE, true)).toBe(false)
  })

  it("resuelto con 'member' (el colapso del singular) no habilita: sólo cuenta el conjunto real", () => {
    expect(hasCapability(["member"], CAN_QUOTE, true)).toBe(false)
  })

  it("owner y admin habilitan", () => {
    expect(hasCapability(["owner"], CAN_QUOTE, true)).toBe(true)
    expect(hasCapability(["admin"], CAN_QUOTE, true)).toBe(true)
  })
})
