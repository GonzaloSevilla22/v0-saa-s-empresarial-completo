"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { MessageSquare, Heart, Crown, Plus } from "lucide-react"
import { toast } from "sonner"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"

const categoryColors: Record<string, string> = {
  General: "border-border text-muted-foreground",
  "Casos de éxito": "border-emerald-500/30 text-emerald-400",
  Tips: "border-cyan-500/30 text-cyan-400",
  Preguntas: "border-yellow-500/30 text-yellow-400",
  "Educación": "border-blue-500/30 text-blue-400",
}

export default function ComunidadPage() {
  const { posts, addPost } = useData()
  const { user } = useAuth()
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState("")
  const [content, setContent] = useState("")
  const [category, setCategory] = useState("General")

  const isPro = user?.plan === "pro"

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!title || !content) {
      toast.error("Completá todos los campos")
      return
    }
    addPost({
      author: user?.name || "Anónimo",
      title,
      content,
      category,
      date: new Date().toISOString().split("T")[0],
      replies: 0,
      likes: 0,
    })
    toast.success("Post publicado")
    setOpen(false)
    setTitle("")
    setContent("")
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Comunidad</h1>
          <p className="text-sm text-muted-foreground mt-1">Conecta con otros emprendedores</p>
        </div>
        {isPro ? (
          <Button onClick={() => setOpen(true)} size="sm">
            <Plus className="h-4 w-4 mr-1" />
            Nuevo post
          </Button>
        ) : (
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger asChild>
                <Button size="sm" disabled className="opacity-60">
                  <Crown className="h-4 w-4 mr-1 text-yellow-500" />
                  Nuevo post
                </Button>
              </TooltipTrigger>
              <TooltipContent className="bg-popover border-border">
                <p className="text-xs">Solo disponible en plan Pro</p>
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
        )}
      </div>

      <div className="flex flex-col gap-4">
        {posts.map((post) => (
          <Card key={post.id} className="border-border bg-card hover:border-primary/20 transition-colors">
            <CardHeader className="pb-2">
              <div className="flex items-start justify-between">
                <div className="flex flex-col gap-1">
                  <CardTitle className="text-base text-card-foreground">{post.title}</CardTitle>
                  <div className="flex items-center gap-2">
                    <span className="text-xs text-muted-foreground">{post.author}</span>
                    <span className="text-xs text-muted-foreground">
                      {new Date(post.date + "T12:00:00").toLocaleDateString("es-AR")}
                    </span>
                  </div>
                </div>
                <Badge variant="outline" className={`text-[10px] shrink-0 ${categoryColors[post.category] || categoryColors.General}`}>
                  {post.category}
                </Badge>
              </div>
            </CardHeader>
            <CardContent>
              <p className="text-sm text-muted-foreground leading-relaxed line-clamp-3">{post.content}</p>
              <div className="mt-3 flex items-center gap-4">
                <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
                  <MessageSquare className="h-3.5 w-3.5" />
                  {post.replies} respuestas
                </div>
                <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
                  <Heart className="h-3.5 w-3.5" />
                  {post.likes}
                </div>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border">
          <DialogHeader>
            <DialogTitle className="text-card-foreground">Nuevo post</DialogTitle>
          </DialogHeader>
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <Input
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Título del post"
              className="bg-background border-border text-foreground"
            />
            <Textarea
              value={content}
              onChange={(e) => setContent(e.target.value)}
              placeholder="Compartí tu experiencia, pregunta o consejo..."
              rows={4}
              className="bg-background border-border text-foreground resize-none"
            />
            <div className="flex gap-2">
              {Object.keys(categoryColors).map((cat) => (
                <Button
                  key={cat}
                  type="button"
                  size="sm"
                  variant={category === cat ? "default" : "outline"}
                  onClick={() => setCategory(cat)}
                  className={category === cat ? "" : "border-border text-muted-foreground"}
                >
                  {cat}
                </Button>
              ))}
            </div>
            <Button type="submit" className="w-full">
              Publicar
            </Button>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  )
}
