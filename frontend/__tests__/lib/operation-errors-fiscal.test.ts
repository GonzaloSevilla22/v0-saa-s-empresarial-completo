import { describe, it, expect } from "vitest"
import { humanizeOperationError } from "@/lib/operation-errors"

// venta-editable-sin-cae: los dos tokens nuevos de P0423. El SQLSTATE es el
// mismo que el de los otros cuatro guards de inmutabilidad, así que lo único
// que distingue la causa —y lo que el usuario puede hacer— es el token.

describe("humanizeOperationError — tokens fiscales de venta-editable-sin-cae", () => {
  it("fiscal_document_claim_in_flight → mensaje REINTENTABLE, sin acción", () => {
    const { message, action } = humanizeOperationError(
      "fiscal_document_claim_in_flight: se está emitiendo el comprobante de esta venta en este momento",
    )
    expect(message).toMatch(/unos minutos/i)
    expect(message).toMatch(/no se guardó ningún cambio/i)
    expect(action).toBeUndefined()
  })

  it("fiscal_document_sent_immutable → mensaje TERMINAL, sin invitar a reintentar ya", () => {
    const { message, action } = humanizeOperationError(
      "fiscal_document_sent_immutable: el comprobante de esta venta (0003-00000006) ya se envió a ARCA",
    )
    expect(message).toMatch(/ya se envió a ARCA/i)
    expect(message).toMatch(/hasta que se resuelva/i)
    expect(message).not.toMatch(/unos minutos/i)
    expect(action).toBeUndefined()
  })

  it("no se confunden entre sí: el transitorio se evalúa primero y no arrastra al terminal", () => {
    const transitorio = humanizeOperationError("fiscal_document_claim_in_flight: …").message
    const terminal = humanizeOperationError("fiscal_document_sent_immutable: …").message
    expect(transitorio).not.toBe(terminal)
  })

  it("un error desconocido sigue pasando tal cual (nunca se oculta)", () => {
    const { message } = humanizeOperationError("algo_muy_raro: detalle crudo")
    expect(message).toBe("algo_muy_raro: detalle crudo")
  })
})
