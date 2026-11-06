"use client"

import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"

/** Preguntas de arranque (ia-copilot-v2, D11): cada una dispara una herramienta del catálogo. */
export const COPILOT_SUGGESTIONS: readonly string[] = [
  "¿Cuánto vendí hoy?",
  "¿Cómo venimos este mes contra el anterior?",
  "¿Qué producto es el que más vendo?",
  "¿Qué cliente compró más este mes?",
  "¿Qué productos tengo con stock bajo?",
  "¿A quién le tengo que cobrar?",
]

interface CopilotSuggestionsProps {
  onPick: (question: string) => void
  disabled?: boolean
  /** `grid`: pantalla vacía; `chips`: fila desplazable debajo del input (mobile). */
  variant: "grid" | "chips"
  className?: string
}

export function CopilotSuggestions({ onPick, disabled, variant, className }: CopilotSuggestionsProps) {
  return (
    <div
      role="group"
      aria-label="Preguntas sugeridas"
      className={cn(
        variant === "grid"
          ? "grid w-full max-w-xl grid-cols-1 gap-2 sm:grid-cols-2"
          : "flex gap-2 overflow-x-auto pb-1",
        className,
      )}
    >
      {COPILOT_SUGGESTIONS.map((q) => (
        <Button
          key={q}
          type="button"
          variant="outline"
          size="sm"
          disabled={disabled}
          onClick={() => onPick(q)}
          className={cn(variant === "grid" ? "h-auto justify-start whitespace-normal py-2 text-left" : "shrink-0 rounded-full")}
        >
          {q}
        </Button>
      ))}
    </div>
  )
}
