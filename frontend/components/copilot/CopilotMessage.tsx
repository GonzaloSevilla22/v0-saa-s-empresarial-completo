"use client"

import { Bot, ThumbsDown, ThumbsUp, User } from "lucide-react"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import type { CopilotConsulted, CopilotRating } from "@/hooks/data/use-copilot"

interface CopilotMessageProps {
  role: "user" | "assistant"
  content: string
  /** Lo que el Copiloto miró para responder (rótulos armados por el servidor). */
  consulted?: CopilotConsulted[]
  /** Sin id (no se pudo guardar el turno) no hay valoración posible. */
  conversationId?: string | null
  rating?: CopilotRating | null
  /** `null` borra la valoración (toggle). */
  onRate?: (conversationId: string, next: CopilotRating | null) => void
}

export function CopilotMessage({ role, content, consulted, conversationId, rating = null, onRate }: CopilotMessageProps) {
  const isUser = role === "user"
  const rateable = !isUser && !!conversationId && !!onRate

  return (
    <div className={cn("flex", isUser ? "justify-end" : "justify-start")}>
      <div className={cn("flex min-w-0 max-w-[90%] gap-2 sm:max-w-[80%] sm:gap-3", isUser && "flex-row-reverse")}>
        <div
          aria-hidden="true"
          className={cn(
            "mt-1 flex h-8 w-8 shrink-0 items-center justify-center rounded-full",
            isUser ? "bg-primary text-primary-foreground" : "border border-primary/20 bg-muted",
          )}
        >
          {isUser ? <User className="h-4 w-4" /> : <Bot className="h-4 w-4 text-primary" />}
        </div>
        <div className="flex min-w-0 flex-col gap-1.5">
          <div
            className={cn(
              "rounded-2xl p-3 shadow-sm sm:p-4",
              isUser
                ? "rounded-tr-none bg-primary text-primary-foreground"
                : "rounded-tl-none border border-border bg-card text-card-foreground",
            )}
          >
            <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">{content}</p>
          </div>
          {!isUser && consulted && consulted.length > 0 && (
            <p className="px-1 text-xs text-muted-foreground">
              <span className="font-medium">Miré:</span> {consulted.map((c) => c.label).join(" · ")}
            </p>
          )}
          {rateable && (
            <div role="group" aria-label="¿Te sirvió esta respuesta?" className="flex flex-wrap gap-1 px-1">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                aria-pressed={rating === "useful"}
                onClick={() => onRate!(conversationId!, rating === "useful" ? null : "useful")}
                className={cn("h-8 gap-1.5 px-2 text-xs", rating === "useful" && "bg-accent text-accent-foreground")}
              >
                <ThumbsUp className="h-3.5 w-3.5" aria-hidden="true" />
                Me sirvió
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                aria-pressed={rating === "not_useful"}
                onClick={() => onRate!(conversationId!, rating === "not_useful" ? null : "not_useful")}
                className={cn("h-8 gap-1.5 px-2 text-xs", rating === "not_useful" && "bg-accent text-accent-foreground")}
              >
                <ThumbsDown className="h-3.5 w-3.5" aria-hidden="true" />
                No me sirvió
              </Button>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
