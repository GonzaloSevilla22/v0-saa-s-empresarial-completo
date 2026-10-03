/**
 * remitos-venta (D3/D13, tarea 4.4) — capacidades del remito en
 * `lib/rbac-capabilities.ts`: `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE` y
 * `CAN_SELL`.
 *
 * El backend es la fuente de verdad y el frontend sólo decide qué mostrar, así
 * que cada conjunto está ATADO por test a `backend/core/rbac.py` (lee el
 * archivo) y al catálogo de la máquina de estados
 * (`document_status_transitions.allowed_role`, sembrado en la migración del
 * remito). Si alguno de los tres diverge, este archivo falla.
 */
import { describe, it, expect } from "vitest"
import fs from "node:fs"
import path from "node:path"
import {
  CAN_CONVERT_PURCHASE_DELIVERY_NOTE,
  CAN_DELIVER_SALE,
  CAN_RECEIVE_PURCHASE,
  CAN_SELL,
  CAN_VOID_DELIVERY_NOTE,
  hasCapability,
} from "@/lib/rbac-capabilities"

const ROOT = path.resolve(__dirname, "../../..")

function pythonCapability(name: string): string[] | null {
  const source = fs.readFileSync(path.join(ROOT, "backend/core/rbac.py"), "utf-8")
  const match = new RegExp(`^${name}\\b[^=]*=\\s*frozenset\\(\\{([^}]*)\\}\\)`, "m").exec(source)
  if (!match) return null
  return [...match[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]).sort()
}

const MIGRATION = fs.readFileSync(
  path.join(ROOT, "supabase/migrations/20261069000001_remitos_venta.sql"),
  "utf-8",
)

/** `allowed_role` de una fila del catálogo `delivery_note_sale` (`from` null = alta). */
function catalogRoles(from: string | null, to: string): string[] | null {
  const fromSql = from === null ? "NULL" : `'${from}'`
  const row = new RegExp(
    `\\('delivery_note_sale',\\s*${fromSql},\\s*'${to}',\\s*(?:true|false),\\s*(?:true|false),\\s*ARRAY\\[([^\\]]*)\\]`,
  ).exec(MIGRATION)
  if (!row) return null
  return [...row[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort()
}

describe("CAN_DELIVER_SALE — emite y edita un remito", () => {
  it("es owner, admin, seller y stock", () => {
    expect([...CAN_DELIVER_SALE].sort()).toEqual(["admin", "owner", "seller", "stock"])
  })

  it("el cajero no emite (cobra, no despacha)", () => {
    expect(hasCapability(["cashier"], CAN_DELIVER_SALE, true)).toBe(false)
  })

  it("el rol stock emite: el depósito despacha la mercadería", () => {
    expect(hasCapability(["stock"], CAN_DELIVER_SALE, true)).toBe(true)
  })

  const python = pythonCapability("CAN_DELIVER_SALE")
  // `CAN_DELIVER_SALE` llega a `core/rbac.py` con la tanda de backend del mismo
  // change (tarea 2.2): mientras no esté en el árbol, el contrato contra Python
  // no tiene contra qué compararse. Los contratos contra la FSM corren siempre.
  it.runIf(python !== null)("coincide con CAN_DELIVER_SALE de backend/core/rbac.py", () => {
    expect([...CAN_DELIVER_SALE].sort()).toEqual(python)
  })

  it("coincide con el allowed_role de NULL -> issued del catálogo delivery_note_sale (la emisión)", () => {
    expect(catalogRoles(null, "issued")).not.toBeNull()
    expect([...CAN_DELIVER_SALE].sort()).toEqual(catalogRoles(null, "issued"))
  })
})

describe("CAN_VOID_DELIVERY_NOTE — anula un remito (devuelve stock)", () => {
  it("es owner y admin", () => {
    expect([...CAN_VOID_DELIVERY_NOTE].sort()).toEqual(["admin", "owner"])
  })

  it("stock y seller emiten pero NO anulan", () => {
    expect(hasCapability(["stock"], CAN_VOID_DELIVERY_NOTE, true)).toBe(false)
    expect(hasCapability(["seller"], CAN_VOID_DELIVERY_NOTE, true)).toBe(false)
    expect(hasCapability(["admin"], CAN_VOID_DELIVERY_NOTE, true)).toBe(true)
  })

  const python = pythonCapability("CAN_VOID_DELIVERY_NOTE")
  it.runIf(python !== null)("coincide con CAN_VOID_DELIVERY_NOTE de backend/core/rbac.py", () => {
    expect([...CAN_VOID_DELIVERY_NOTE].sort()).toEqual(python)
  })

  it("coincide con el allowed_role de issued -> canceled del catálogo (la anulación)", () => {
    expect(catalogRoles("issued", "canceled")).not.toBeNull()
    expect([...CAN_VOID_DELIVERY_NOTE].sort()).toEqual(catalogRoles("issued", "canceled"))
  })
})

describe("CAN_SELL — convierte el remito en venta (tanda B) y cobra", () => {
  it("es owner, admin, seller y cashier", () => {
    expect([...CAN_SELL].sort()).toEqual(["admin", "cashier", "owner", "seller"])
  })

  it("el rol stock no cobra: emite pero no tiene camino a caja (OQ-RV2)", () => {
    expect(hasCapability(["stock"], CAN_SELL, true)).toBe(false)
  })

  it("coincide con CAN_SELL de backend/core/rbac.py", () => {
    expect([...CAN_SELL].sort()).toEqual(pythonCapability("CAN_SELL"))
  })
})

describe("hasCapability con las capacidades del remito", () => {
  it("conjunto sin resolver -> sí (fail-open): no oculta el módulo durante la carga", () => {
    expect(hasCapability(["member"], CAN_DELIVER_SALE, false)).toBe(true)
    expect(hasCapability(["member"], CAN_VOID_DELIVERY_NOTE, false)).toBe(true)
  })

  it("resuelto con varios roles, alguno habilitado -> sí (intersección, no igualdad)", () => {
    expect(hasCapability(["cashier", "stock"], CAN_DELIVER_SALE, true)).toBe(true)
    expect(hasCapability(["cashier", "stock"], CAN_VOID_DELIVERY_NOTE, true)).toBe(false)
  })
})

// ── remitos-compra (D3/D12, tarea 4.4) ─────────────────────────────────────────

/** Migraciones de remitos-compra, concatenadas: la tanda B suma sus filas en otra. */
const PURCHASE_MIGRATIONS = fs
  .readdirSync(path.join(ROOT, "supabase/migrations"))
  .filter((file) => file.includes("remitos_compra") && file.endsWith(".sql"))
  .map((file) => fs.readFileSync(path.join(ROOT, "supabase/migrations", file), "utf-8"))
  .join("\n")

/** `allowed_role` de una fila del catálogo `delivery_note_purchase`; `null` si todavía no existe. */
function purchaseCatalogRoles(from: string | null, to: string): string[] | null {
  const fromSql = from === null ? "NULL" : `'${from}'`
  const row = new RegExp(
    `\\('delivery_note_purchase',\\s*${fromSql},\\s*'${to}',\\s*(?:true|false),\\s*(?:true|false),\\s*ARRAY\\[([^\\]]*)\\]`,
  ).exec(PURCHASE_MIGRATIONS)
  if (!row) return null
  return [...row[1].matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort()
}

describe("CAN_RECEIVE_PURCHASE — emite y edita un remito de compra (suma stock)", () => {
  it("es owner, admin y stock", () => {
    expect([...CAN_RECEIVE_PURCHASE].sort()).toEqual(["admin", "owner", "stock"])
  })

  it("el vendedor no recibe mercadería: despacha, no recibe (a diferencia de CAN_DELIVER_SALE)", () => {
    expect(hasCapability(["seller"], CAN_RECEIVE_PURCHASE, true)).toBe(false)
    expect(hasCapability(["seller"], CAN_DELIVER_SALE, true)).toBe(true)
  })

  it("el rol stock recibe; purchases, cashier y accountant no", () => {
    expect(hasCapability(["stock"], CAN_RECEIVE_PURCHASE, true)).toBe(true)
    expect(hasCapability(["purchases"], CAN_RECEIVE_PURCHASE, true)).toBe(false)
    expect(hasCapability(["cashier"], CAN_RECEIVE_PURCHASE, true)).toBe(false)
    expect(hasCapability(["accountant"], CAN_RECEIVE_PURCHASE, true)).toBe(false)
  })

  const python = pythonCapability("CAN_RECEIVE_PURCHASE")
  // `CAN_RECEIVE_PURCHASE` llega a `core/rbac.py` con la tanda de backend del mismo
  // change (tarea 2.2); los contratos contra la FSM corren siempre.
  it.runIf(python !== null)("coincide con CAN_RECEIVE_PURCHASE de backend/core/rbac.py", () => {
    expect([...CAN_RECEIVE_PURCHASE].sort()).toEqual(python)
  })

  it("coincide con el allowed_role de NULL -> issued del catálogo delivery_note_purchase (la recepción)", () => {
    expect(purchaseCatalogRoles(null, "issued")).not.toBeNull()
    expect([...CAN_RECEIVE_PURCHASE].sort()).toEqual(purchaseCatalogRoles(null, "issued"))
  })

  it("anular un remito de compra sigue siendo CAN_VOID_DELIVERY_NOTE: coincide con issued -> canceled", () => {
    expect(purchaseCatalogRoles("issued", "canceled")).not.toBeNull()
    expect([...CAN_VOID_DELIVERY_NOTE].sort()).toEqual(purchaseCatalogRoles("issued", "canceled"))
  })
})

describe("CAN_CONVERT_PURCHASE_DELIVERY_NOTE — convierte el remito en compra (tanda B, OQ-RC6)", () => {
  it("es owner, admin, purchases y stock", () => {
    expect([...CAN_CONVERT_PURCHASE_DELIVERY_NOTE].sort()).toEqual(["admin", "owner", "purchases", "stock"])
  })

  it("stock y purchases convierten (quien recibe cierra el ciclo); seller y cashier no", () => {
    expect(hasCapability(["stock"], CAN_CONVERT_PURCHASE_DELIVERY_NOTE, true)).toBe(true)
    expect(hasCapability(["purchases"], CAN_CONVERT_PURCHASE_DELIVERY_NOTE, true)).toBe(true)
    expect(hasCapability(["seller"], CAN_CONVERT_PURCHASE_DELIVERY_NOTE, true)).toBe(false)
    expect(hasCapability(["cashier"], CAN_CONVERT_PURCHASE_DELIVERY_NOTE, true)).toBe(false)
  })

  const python = pythonCapability("CAN_CONVERT_PURCHASE_DELIVERY_NOTE")
  it.runIf(python !== null)("coincide con CAN_CONVERT_PURCHASE_DELIVERY_NOTE de backend/core/rbac.py", () => {
    expect([...CAN_CONVERT_PURCHASE_DELIVERY_NOTE].sort()).toEqual(python)
  })

  // La fila `issued -> converted` de `delivery_note_purchase` la siembra la tanda B (6.3).
  const converted = purchaseCatalogRoles("issued", "converted")
  it.runIf(converted !== null)("coincide con el allowed_role de issued -> converted del catálogo (la conversión)", () => {
    expect([...CAN_CONVERT_PURCHASE_DELIVERY_NOTE].sort()).toEqual(converted)
  })
})
