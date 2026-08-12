/**
 * Test de paridad entre los dos módulos canónicos de "día de negocio
 * argentino" (app-timezone-argentina, D3): `frontend/lib/date-range.ts`
 * (Next.js) y `supabase/functions/_shared/argentina-time.ts` (Deno).
 *
 * Una única tabla de casos (`argentinaDayCases`, exportada desde
 * `lib/date-range.ts`), ejecutada contra las dos implementaciones de
 * `argentinaToday`, con assert de igualdad resultado a resultado. Si un solo
 * caso difiere entre las dos copias, este test se pone rojo — es la
 * mitigación completa del riesgo de divergencia silenciosa entre runtimes.
 */

import { describe, it, expect } from "vitest"
import { argentinaToday as frontendArgentinaToday, argentinaDayCases } from "@/lib/date-range"
import { argentinaToday as edgeArgentinaToday } from "../../../supabase/functions/_shared/argentina-time"

describe("paridad frontend <-> Deno: argentinaToday", () => {
  for (const c of argentinaDayCases) {
    it(`${c.name} — ambas implementaciones coinciden`, () => {
      const instant = new Date(c.instantIso)
      const frontendResult = frontendArgentinaToday(instant)
      const edgeResult = edgeArgentinaToday(instant)
      expect(frontendResult).toBe(c.expectedDay)
      expect(edgeResult).toBe(c.expectedDay)
      expect(frontendResult).toBe(edgeResult)
    })
  }
})
