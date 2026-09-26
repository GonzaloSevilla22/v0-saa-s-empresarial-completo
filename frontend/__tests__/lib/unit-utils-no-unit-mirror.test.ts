/**
 * Corrección del PR #584 (hallazgo bajo: `toBaseQuantity` no era espejo exacto
 * de `_uom_normalize_quantity` cuando la LÍNEA no tiene unidad).
 *
 * El SQL, con `p_unit_id IS NULL`, devuelve la cantidad tal cual
 * (`p_quantity::numeric(15,4)`) — sin mirar la unidad base del producto. El
 * helper TS dividía igual por el factor de la base: una línea sin unidad sobre
 * un producto llevado en gramos daba 3 → 3000 en la validación local de stock,
 * mientras el servidor descontaba 3.
 */
import { describe, expect, it } from "vitest"

import { toBaseQuantity } from "@/lib/unit-utils"
import type { UnitOfMeasure } from "@/lib/types"

const kg: UnitOfMeasure = { id: "kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const g: UnitOfMeasure = { id: "g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "kg", isSystem: true }
const mL: UnitOfMeasure = { id: "mL", name: "Mililitro", symbol: "mL", type: "volume", factor: 0.001, baseUnitId: "L", isSystem: true }

describe("toBaseQuantity — línea SIN unidad: cantidad tal cual (espejo del SQL)", () => {
  it("producto en gramos, línea sin unidad: 3 → 3 (no 3000)", () => {
    expect(toBaseQuantity(3, undefined, g)).toBe(3)
    expect(toBaseQuantity(3, null, g)).toBe(3)
  })

  it("producto en mL, línea sin unidad: 0.381 → 0.381 (no 381)", () => {
    expect(toBaseQuantity(0.381, undefined, mL)).toBe(0.381)
  })

  it("redondea a 4 decimales igual que numeric(15,4): 1.23456 → 1.2346", () => {
    expect(toBaseQuantity(1.23456, undefined, g)).toBe(1.2346)
  })

  it("con unidad el factor sigue aplicando (regresión): 450 g sobre kg → 0.45", () => {
    expect(toBaseQuantity(450, g, kg)).toBe(0.45)
  })
})
