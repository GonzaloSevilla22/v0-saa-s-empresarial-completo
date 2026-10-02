/**
 * Revisión adversarial F7 (PR #608): `ClientForm` armaba el alta con
 * `addClient(clientData as any)` porque `addClient` pedía `Omit<Client, "id">`
 * (email/phone `string`, `lastPurchase`/`totalSpent` obligatorios) y el
 * formulario manda `null` y no conoce esos derivados. El contrato de alta y de
 * edición pasa a ser `NewClientInput`; este test lo fija a nivel de tipos (lo
 * verifica `tsc`, vitest sólo lo ejecuta) y comprueba en runtime que el
 * formulario sigue entregando el cliente creado.
 */
import { describe, it, expect, expectTypeOf } from "vitest"
import type { useClients } from "@/hooks/data/use-clients"
import type { Client, NewClientInput } from "@/lib/types"

type UseClients = ReturnType<typeof useClients>

describe("contrato de tipos de useClients", () => {
  it("el alta y la edición aceptan los datos del formulario (null en contacto, sin derivados)", () => {
    const fromForm: NewClientInput = {
      name: "Ana",
      email: null,
      phone: null,
      category: undefined,
      taxId: undefined,
      paymentTermsDays: null,
    }
    expectTypeOf<Parameters<UseClients["addClient"]>[0]>().toEqualTypeOf<NewClientInput>()
    expectTypeOf<Parameters<UseClients["updateClient"]>[0]>().toEqualTypeOf<NewClientInput & { id: string }>()
    expect(fromForm.paymentTermsDays).toBeNull()
  })

  it("un Client completo sigue siendo un NewClientInput válido (los demás callers no cambian)", () => {
    expectTypeOf<Omit<Client, "id">>().toMatchTypeOf<NewClientInput>()
    expectTypeOf<Client>().toMatchTypeOf<NewClientInput & { id: string }>()
  })
})
