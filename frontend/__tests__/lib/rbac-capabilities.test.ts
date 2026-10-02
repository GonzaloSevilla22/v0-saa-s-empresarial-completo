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
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"

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
