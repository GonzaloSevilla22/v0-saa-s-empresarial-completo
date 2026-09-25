/**
 * Corrección del PR #584 (hallazgo bloqueante 3, defensa en profundidad): el
 * formateador de cantidades no puede tirar la pantalla si un caller le pasa un
 * Decimal serializado ("5.0000") en vez de un número — fue exactamente lo que
 * rompió `/stock` en prod. El mapeo del hook ya convierte; esto cubre a
 * cualquier otro caller que se olvide.
 */
import { describe, expect, it } from "vitest"
import { formatQuantity, formatStock } from "@/lib/format-unit"

// Simula lo que llega en runtime desde un JSON sin mapear, sin `any`.
const asRuntime = (v: string): number => v as unknown as number

describe("format-unit — cantidades que llegan como string decimal", () => {
  it("formatStock: '5.0000' → '5 uds' y '0.5000' kg → '0.500 kg'", () => {
    expect(formatStock(asRuntime("5.0000"))).toBe("5 uds")
    expect(formatStock(asRuntime("0.5000"), "kg")).toBe("0.500 kg")
  })

  it("formatQuantity: '12.3750' → '12.375 kg' y '3' → '3'", () => {
    expect(formatQuantity(asRuntime("12.3750"), "kg")).toBe("12.375 kg")
    expect(formatQuantity(asRuntime("3"))).toBe("3")
  })

  it("los números siguen igual (regresión)", () => {
    expect(formatStock(1.25, "kg")).toBe("1.250 kg")
    expect(formatQuantity(10)).toBe("10")
  })
})
