"use client"

import { CopilotChat } from "@/components/copilot/CopilotChat"

/**
 * ia-copilot-v2 (tanda B, D11): la pantalla del Copiloto IA. Todo el comportamiento vive en
 * `components/copilot/` y `hooks/data/use-copilot.ts`; la consulta va a la Edge Function `ai-copilot`
 * (herramientas de sólo lectura sobre las RPCs canónicas, con cuota), no a una ruta de Next.
 */
export default function CopilotoPage() {
  return (
    <div className="mx-auto flex h-[calc(100dvh-9rem)] min-h-[30rem] min-w-0 max-w-4xl flex-col gap-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight sm:text-3xl">Copiloto IA</h1>
        <p className="mt-1 text-sm text-muted-foreground sm:mt-2 sm:text-base">
          Tu asesor de negocios. Preguntale sobre ventas, clientes, stock o cobranzas con tus propias palabras.
        </p>
      </div>
      <CopilotChat />
    </div>
  )
}
