"use client"

/**
 * ia-copilot-v2 (tanda B, D11) — el chat del Copiloto sobre la Edge Function `ai-copilot`.
 *
 * Estado propio de la conversación en curso (mensajes visibles, `thread_id`, estado de foco) y, arriba
 * y separado, el historial guardado (últimos 50 turnos, D9). Los errores se muestran con texto
 * legible y fijo (nunca el del proveedor) y la pregunta vuelve al campo para poder reintentarla.
 */

import { useCallback, useEffect, useRef, useState } from "react"
import type { FormEvent } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { AlertTriangle, Bot, Loader2, MessageSquarePlus, Send, Sparkles } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { useAuth } from "@/contexts/auth-context"
import { useAiUsage } from "@/hooks/auth/use-ai-usage"
import {
  EMPTY_COPILOT_STATE,
  useAskCopilot,
  useCopilotHistory,
  useSetAiFeedback,
  type CopilotAskResult,
  type CopilotConsulted,
  type CopilotHistoryMessage,
  type CopilotRating,
  type CopilotState,
} from "@/hooks/data/use-copilot"
import { formatAiResetDate, nextAiResetDate } from "@/lib/ai-usage"
import { queryKeys } from "@/lib/query-keys"
import { CopilotMessage } from "./CopilotMessage"
import { CopilotQuotaBadge } from "./CopilotQuotaBadge"
import { CopilotSuggestions } from "./CopilotSuggestions"

const MAX_QUESTION_LENGTH = 1000
const MAX_HISTORY_MESSAGES = 20
const MAX_HISTORY_MESSAGE_LENGTH = 4000
/** Pasos del indicador de espera (D11): a los 2 s y a los 15 s. */
const STEP_1_MS = 2000
const STEP_2_MS = 15_000
const PROGRESS_TEXT = ["Pensando…", "Consultando tus datos…", "Sigo buscando…"] as const

const UNAVAILABLE_TEXT = "No pude responder ahora. Probá de nuevo en un rato."

interface LiveMessage {
  key: string
  role: "user" | "assistant"
  content: string
  consulted?: CopilotConsulted[]
  conversationId?: string | null
  rating?: CopilotRating | null
}

type Notice =
  | { kind: "error"; text: string }
  | { kind: "rate"; seconds: number }

interface QuotaBlock {
  limit: number | null
  used: number | null
  resetAt: string | null
}

function newId(): string {
  const c = globalThis.crypto
  if (c && typeof c.randomUUID === "function") return c.randomUUID()
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (ch) => {
    const r = Math.floor(Math.random() * 16)
    return (ch === "x" ? r : (r % 4) + 8).toString(16)
  })
}

function renewalText(resetAt: string | null): string {
  const parsed = resetAt ? new Date(resetAt) : null
  const date = parsed && !Number.isNaN(parsed.getTime()) ? parsed : nextAiResetDate(new Date())
  return formatAiResetDate(date)
}

const plural = (n: number, one: string, many: string) => (n === 1 ? `${n} ${one}` : `${n} ${many}`)

/** Texto legible por cada resultado que no es respuesta; nunca el del proveedor. */
function noticeFor(result: CopilotAskResult): Notice | null {
  switch (result.status) {
    case "rate_limited":
      return { kind: "rate", seconds: result.retryAfterSeconds }
    case "unavailable":
    case "fallback":
      return { kind: "error", text: UNAVAILABLE_TEXT }
    case "offline":
      return { kind: "error", text: "Parece que no tenés conexión. Revisá tu internet e intentá de nuevo." }
    case "unauthorized":
      return { kind: "error", text: "Tu sesión venció. Volvé a iniciar sesión para seguir consultando." }
    case "no_account":
      return { kind: "error", text: "No encontramos una cuenta activa para consultar." }
    case "invalid":
      return { kind: "error", text: result.message }
    case "error":
      return { kind: "error", text: "No pude completar la consulta. Probá de nuevo." }
    default:
      return null
  }
}

export function CopilotChat() {
  const { user } = useAuth()
  const queryClient = useQueryClient()
  const usage = useAiUsage()
  const history = useCopilotHistory()
  const ask = useAskCopilot()
  const setFeedback = useSetAiFeedback()

  const [messages, setMessages] = useState<LiveMessage[]>([])
  const [text, setText] = useState("")
  const [notice, setNotice] = useState<Notice | null>(null)
  const [quotaBlock, setQuotaBlock] = useState<QuotaBlock | null>(null)
  const [progressStep, setProgressStep] = useState(0)

  const threadRef = useRef<string | null>(null)
  const focusRef = useRef<CopilotState>(EMPTY_COPILOT_STATE)
  const scrollRef = useRef<HTMLDivElement>(null)

  const sending = ask.isPending
  const usageExhausted = !usage.isLoading && usage.queriesLimit > 0 && usage.queriesRemaining === 0
  const exhausted = quotaBlock !== null || usageExhausted
  const waiting = notice?.kind === "rate"
  const blocked = exhausted || waiting

  // Cuenta regresiva de la ráfaga.
  useEffect(() => {
    if (notice?.kind !== "rate") return
    const id = setInterval(() => {
      setNotice((n) => (n?.kind === "rate" ? (n.seconds <= 1 ? null : { kind: "rate", seconds: n.seconds - 1 }) : n))
    }, 1000)
    return () => clearInterval(id)
  }, [notice?.kind])

  // Pasos del indicador de espera.
  useEffect(() => {
    if (!sending) {
      setProgressStep(0)
      return
    }
    const t1 = setTimeout(() => setProgressStep(1), STEP_1_MS)
    const t2 = setTimeout(() => setProgressStep(2), STEP_2_MS)
    return () => {
      clearTimeout(t1)
      clearTimeout(t2)
    }
  }, [sending])

  const liveIds = new Set(messages.flatMap((m) => (m.conversationId ? [m.conversationId] : [])))
  const savedTurns = (history.data ?? []).filter((t) => !liveIds.has(t.id))

  useEffect(() => {
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages, sending, savedTurns.length, notice])

  const send = useCallback(
    async (raw: string) => {
      const question = raw.trim().slice(0, MAX_QUESTION_LENGTH)
      if (!question || sending || blocked) return

      const sentHistory: CopilotHistoryMessage[] = messages.slice(-MAX_HISTORY_MESSAGES).map((m) => ({
        role: m.role,
        content: m.content.slice(0, MAX_HISTORY_MESSAGE_LENGTH),
        ...(m.role === "assistant" && m.consulted && m.consulted.length > 0 ? { consulted: m.consulted.map((c) => c.label) } : {}),
      }))
      threadRef.current ??= newId()
      const userKey = newId()

      setNotice(null)
      setText("")
      setMessages((ms) => [...ms, { key: userKey, role: "user", content: question }])

      let result: CopilotAskResult
      try {
        result = await ask.mutateAsync({ question, history: sentHistory, state: focusRef.current, threadId: threadRef.current })
      } catch {
        result = { status: "error", message: "unexpected" }
      }

      if (result.status === "answer" || result.status === "clarification") {
        focusRef.current = result.state
        setMessages((ms) => [
          ...ms,
          { key: newId(), role: "assistant", content: result.answer, consulted: result.consulted, conversationId: result.conversationId, rating: null },
        ])
        return
      }

      // Todo lo demás: la pregunta no quedó contestada → vuelve al campo para reintentar.
      setMessages((ms) => ms.filter((m) => m.key !== userKey))
      setText(question)
      if (result.status === "quota_exceeded") {
        setQuotaBlock({ limit: result.limit, used: result.used, resetAt: result.resetAt })
        return
      }
      setNotice(noticeFor(result))
    },
    [ask, blocked, messages, sending],
  )

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    void send(text)
  }

  function handleNewConversation() {
    setMessages([])
    setNotice(null)
    threadRef.current = null
    focusRef.current = EMPTY_COPILOT_STATE
    // Los turnos que acaban de pasar al historial se releen con su valoración.
    void queryClient.invalidateQueries({ queryKey: queryKeys.copilot.history(user?.accountId ?? null) })
  }

  function handleRate(conversationId: string, next: CopilotRating | null) {
    const previous = messages.find((m) => m.conversationId === conversationId)?.rating ?? null
    setMessages((ms) => ms.map((m) => (m.conversationId === conversationId ? { ...m, rating: next } : m)))
    setFeedback.mutate(
      { conversationId, rating: next },
      {
        onError: () => {
          setMessages((ms) => ms.map((m) => (m.conversationId === conversationId ? { ...m, rating: previous } : m)))
          toast.error("No pudimos guardar tu valoración. Probá de nuevo.")
        },
      },
    )
  }

  const quotaLimit = quotaBlock?.limit ?? (usage.queriesLimit > 0 ? usage.queriesLimit : (quotaBlock?.used ?? usage.queriesUsed))
  const empty = messages.length === 0 && savedTurns.length === 0

  return (
    <Card className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden border-2 border-primary/10 shadow-xl">
      <CardHeader className="border-b bg-muted/30 p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-2">
            <div className="rounded-full bg-primary/10 p-2">
              <Bot className="h-5 w-5 text-primary" aria-hidden="true" />
            </div>
            <div className="min-w-0">
              <CardTitle className="text-lg">Chat con ALIADATA Copilot</CardTitle>
              <CardDescription>Responde con los datos reales de tu negocio. No modifica nada.</CardDescription>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <CopilotQuotaBadge remaining={usage.queriesRemaining} limit={usage.queriesLimit} isLoading={usage.isLoading} />
            <Button type="button" variant="outline" size="sm" onClick={handleNewConversation} disabled={messages.length === 0 || sending}>
              <MessageSquarePlus className="h-4 w-4" aria-hidden="true" />
              Nueva conversación
            </Button>
          </div>
        </div>
      </CardHeader>

      <CardContent className="relative min-h-0 flex-1 p-0">
        <div
          ref={scrollRef}
          role="log"
          aria-label="Conversación con el Copiloto"
          aria-live="polite"
          tabIndex={0}
          className="flex h-full flex-col gap-4 overflow-y-auto p-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:p-4"
        >
          {savedTurns.length > 0 && (
            <section aria-labelledby="copilot-history-title" className="flex flex-col gap-4">
              <h2 id="copilot-history-title" className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                Conversaciones anteriores
              </h2>
              {savedTurns.map((t) => (
                <div key={t.id} className="flex flex-col gap-3">
                  <CopilotMessage role="user" content={t.question} />
                  {t.answer && (
                    <CopilotMessage role="assistant" content={t.answer} conversationId={t.id} rating={t.rating} onRate={handleRate} />
                  )}
                </div>
              ))}
              {messages.length > 0 && <hr className="border-border" />}
            </section>
          )}

          {empty && (
            <div className="flex flex-col items-center justify-center gap-4 py-8 text-center">
              <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary/10">
                <Sparkles className="h-8 w-8 text-primary" aria-hidden="true" />
              </div>
              <div>
                <h2 className="text-lg font-medium">¿Qué querés saber de tu negocio?</h2>
                <p className="mt-1 text-sm text-muted-foreground">Preguntame con tus palabras; si me falta algo, te repregunto.</p>
              </div>
              <CopilotSuggestions variant="grid" onPick={(q) => void send(q)} disabled={blocked || sending} />
            </div>
          )}

          {messages.map((m) => (
            <CopilotMessage
              key={m.key}
              role={m.role}
              content={m.content}
              consulted={m.consulted}
              conversationId={m.conversationId}
              rating={m.rating}
              onRate={handleRate}
            />
          ))}

          {sending && (
            <div className="flex justify-start">
              <div
                role="status"
                aria-label="Progreso de la consulta"
                className="flex items-center gap-2 rounded-2xl rounded-tl-none border border-border bg-card p-3 text-sm text-muted-foreground shadow-sm"
              >
                <Loader2 className="h-4 w-4 animate-spin text-primary" aria-hidden="true" />
                <span>{PROGRESS_TEXT[progressStep]}</span>
              </div>
            </div>
          )}
        </div>
      </CardContent>

      <div className="flex flex-col gap-2 border-t bg-muted/20 p-3 sm:p-4">
        {notice?.kind === "error" && (
          <div role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-foreground">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" aria-hidden="true" />
            <span>{notice.text}</span>
          </div>
        )}
        {notice?.kind === "rate" && (
          <p role="status" className="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-foreground">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
            <span>{`Esperá ${plural(notice.seconds, "segundo", "segundos")} y volvé a intentar.`}</span>
          </p>
        )}
        {exhausted && (
          <p role="status" className="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-foreground">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
            <span>{`Usaste tus ${quotaLimit} consultas del mes. Se renuevan el ${renewalText(quotaBlock?.resetAt ?? null)}.`}</span>
          </p>
        )}

        <form onSubmit={handleSubmit} className="flex gap-2">
          <Input
            aria-label="Escribí tu consulta"
            placeholder="Preguntame sobre tu negocio…"
            value={text}
            maxLength={MAX_QUESTION_LENGTH}
            onChange={(e) => setText(e.target.value)}
            disabled={exhausted}
            autoComplete="off"
            className="min-w-0 flex-1 bg-background"
          />
          <Button type="submit" aria-label="Enviar consulta" disabled={blocked || sending || !text.trim()}>
            {sending ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" /> : <Send className="h-4 w-4" aria-hidden="true" />}
            <span className="ml-2 hidden sm:inline" aria-hidden="true">Enviar</span>
          </Button>
        </form>

        {!empty && <CopilotSuggestions variant="chips" className="sm:hidden" onPick={(q) => void send(q)} disabled={blocked || sending} />}
      </div>
    </Card>
  )
}
