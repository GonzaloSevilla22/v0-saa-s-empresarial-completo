"use client"

import { useState, useEffect, useRef } from "react"
import { aiCopilotService } from "@/lib/services/aiCopilotService"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Send, Bot, User, Loader2, Sparkles } from "lucide-react"

interface Message {
  role: 'user' | 'assistant'
  content: string
  created_at?: string
}

export default function CopilotoPage() {
  const { user } = useAuth()
  const [messages, setMessages] = useState<Message[]>([])
  const [input, setInput] = useState("")
  const [isLoading, setIsLoading] = useState(false)
  const [isHistoryLoading, setIsHistoryLoading] = useState(true)
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (user) {
      loadHistory()
    }
  }, [user])

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollIntoView({ behavior: "smooth" })
    }
  }, [messages])

  async function loadHistory() {
    try {
      const supabase = createClient()
      const history = await aiCopilotService.getConversationHistory(supabase)
      const formatted = history.flatMap((h: any) => [
        { role: 'user' as const, content: h.question, created_at: h.created_at },
        { role: 'assistant' as const, content: h.answer, created_at: h.created_at }
      ])
      setMessages(formatted)
    } catch (error) {
      console.error("Error loading chat history:", error)
    } finally {
      setIsHistoryLoading(false)
    }
  }

  async function handleSend() {
    if (!input.trim() || isLoading) return

    const userQuestion = input.trim()
    setInput("")
    setMessages(prev => [...prev, { role: 'user', content: userQuestion }])
    setIsLoading(true)

    try {
      const res = await fetch('/api/ai/copilot', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ question: userQuestion })
      })

      const data = await res.json()
      if (data.error) throw new Error(data.error)

      setMessages(prev => [...prev, { role: 'assistant', content: data.answer }])
    } catch (error: any) {
      console.error("Chat error:", error)
      setMessages(prev => [...prev, { role: 'assistant', content: "Lo siento, hubo un error al procesar tu consulta. Por favor intenta de nuevo." }])
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="flex flex-col gap-6 max-w-4xl mx-auto h-[calc(100vh-140px)]">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Copiloto IA</h1>
        <p className="text-muted-foreground mt-2">
          Tu asesor de negocios personalizado. Pregúntame sobre ventas, stock o cómo mejorar tus márgenes.
        </p>
      </div>

      <Card className="flex-1 flex flex-col overflow-hidden border-2 border-primary/10 shadow-xl bg-gradient-to-b from-background to-primary/5">
        <CardHeader className="border-b bg-muted/30 backdrop-blur-sm">
          <div className="flex items-center gap-2">
            <div className="p-2 rounded-full bg-primary/10">
              <Bot className="w-5 h-5 text-primary" />
            </div>
            <div>
              <CardTitle className="text-lg">Chat con ALIADA Copilot</CardTitle>
              <CardDescription>Basado en los datos reales de tu negocio</CardDescription>
            </div>
          </div>
        </CardHeader>
        
        <CardContent className="flex-1 overflow-hidden p-0 relative">
          <ScrollArea className="h-full p-4">
            <div className="flex flex-col gap-4">
              {isHistoryLoading ? (
                <div className="flex justify-center p-8">
                  <Loader2 className="w-6 h-6 animate-spin text-primary" />
                </div>
              ) : messages.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-12 text-center">
                  <div className="w-16 h-16 rounded-full bg-primary/5 flex items-center justify-center mb-4">
                    <Sparkles className="w-8 h-8 text-primary/40" />
                  </div>
                  <h3 className="text-lg font-medium">¿En qué puedo ayudarte hoy?</h3>
                  <p className="text-sm text-muted-foreground mt-1 max-w-xs">
                    Prueba preguntando:<br/>
                    "¿Cuál es mi producto más rentable?" o<br/>
                    "¿Tengo alertas de stock para esta semana?"
                  </p>
                </div>
              ) : (
                messages.map((msg, idx) => (
                  <div 
                    key={idx} 
                    className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
                  >
                    <div className={`flex gap-3 max-w-[80%] ${msg.role === 'user' ? 'flex-row-reverse' : ''}`}>
                      <div className={`mt-1 flex-shrink-0 w-8 h-8 rounded-full flex items-center justify-center ${
                        msg.role === 'user' ? 'bg-primary text-primary-foreground' : 'bg-muted border border-primary/20'
                      }`}>
                        {msg.role === 'user' ? <User className="w-4 h-4" /> : <Bot className="w-4 h-4 text-primary" />}
                      </div>
                      <div className={`rounded-2xl p-4 shadow-sm ${
                        msg.role === 'user' 
                          ? 'bg-primary text-primary-foreground rounded-tr-none' 
                          : 'bg-card text-card-foreground border border-border rounded-tl-none'
                      }`}>
                        <p className="text-sm leading-relaxed whitespace-pre-wrap">{msg.content}</p>
                      </div>
                    </div>
                  </div>
                ))
              )}
              {isLoading && (
                <div className="flex justify-start">
                  <div className="flex gap-3 max-w-[80%]">
                    <div className="mt-1 flex-shrink-0 w-8 h-8 rounded-full bg-muted border border-primary/20 flex items-center justify-center">
                      <Bot className="w-4 h-4 text-primary" />
                    </div>
                    <div className="rounded-2xl p-4 bg-card border border-border rounded-tl-none shadow-sm flex items-center gap-2">
                      <Loader2 className="w-4 h-4 animate-spin text-primary" />
                      <span className="text-sm text-muted-foreground italic">Analizando tus datos...</span>
                    </div>
                  </div>
                </div>
              )}
              <div ref={scrollRef} />
            </div>
          </ScrollArea>
        </CardContent>

        <div className="p-4 border-t bg-muted/20 backdrop-blur-sm">
          <form 
            onSubmit={(e) => { e.preventDefault(); handleSend(); }}
            className="flex gap-2"
          >
            <Input
              placeholder="Escribe tu consulta de negocios..."
              value={input}
              onChange={(e) => setInput(e.target.value)}
              disabled={isLoading}
              className="flex-1 bg-background border-primary/20 focus-visible:ring-primary shadow-inner"
            />
            <Button 
              type="submit" 
              disabled={isLoading || !input.trim()}
              className="px-6 shadow-md hover:shadow-lg transition-all"
            >
              {isLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />}
              <span className="ml-2 hidden sm:inline">Enviar</span>
            </Button>
          </form>
        </div>
      </Card>
    </div>
  )
}
