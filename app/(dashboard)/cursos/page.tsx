"use client"

import { useState } from "react"
import Link from "next/link"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Crown, Star, Users, Lock, BookOpen } from "lucide-react"

const levelColors: Record<string, string> = {
  básico: "border-emerald-500/30 text-emerald-400",
  intermedio: "border-yellow-500/30 text-yellow-400",
  avanzado: "border-red-500/30 text-red-400",
}

export default function CursosPage() {
  const { courses } = useData()
  const { user } = useAuth()
  const [filter, setFilter] = useState("todos")

  const isPro = user?.plan === "pro"

  const filtered = filter === "todos"
    ? courses
    : filter === "básicos"
      ? courses.filter((c) => !c.isPro)
      : filter === "pro"
        ? courses.filter((c) => c.isPro)
        : courses

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Cursos</h1>
        <p className="text-sm text-muted-foreground mt-1">Aprende a gestionar y hacer crecer tu negocio</p>
      </div>

      <Tabs value={filter} onValueChange={setFilter}>
        <TabsList className="bg-secondary border border-border">
          <TabsTrigger value="todos" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground">Todos</TabsTrigger>
          <TabsTrigger value="básicos" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground">Gratuitos</TabsTrigger>
          <TabsTrigger value="pro" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground">Pro</TabsTrigger>
        </TabsList>
      </Tabs>

      <div className="grid gap-4 grid-cols-1 md:grid-cols-2 lg:grid-cols-3">
        {filtered.map((course) => {
          const isLocked = course.isPro && !isPro
          const completedModules = course.modules.filter((m) => m.completed).length
          const progress = course.modules.length > 0 ? (completedModules / course.modules.length) * 100 : 0

          return (
            <Card key={course.id} className={`border-border bg-card relative overflow-hidden group hover:border-primary/30 transition-colors ${isLocked ? "opacity-80" : ""}`}>
              <div className="h-2 bg-secondary">
                <div
                  className="h-full bg-primary transition-all"
                  style={{ width: `${progress}%` }}
                />
              </div>
              <CardHeader className="pb-2">
                <div className="flex items-start justify-between gap-2">
                  <CardTitle className="text-base text-card-foreground leading-tight">{course.title}</CardTitle>
                  {course.isPro && (
                    <Badge className="shrink-0 bg-yellow-500/20 text-yellow-500 border-yellow-500/30">
                      <Crown className="h-3 w-3 mr-0.5" />
                      Pro
                    </Badge>
                  )}
                </div>
                <div className="flex items-center gap-3 mt-1">
                  <Badge variant="outline" className={`text-[10px] capitalize ${levelColors[course.level]}`}>
                    {course.level}
                  </Badge>
                  <span className="text-[10px] text-muted-foreground">{course.category}</span>
                </div>
              </CardHeader>
              <CardContent className="flex flex-col gap-3">
                <p className="text-sm text-muted-foreground leading-relaxed line-clamp-2">{course.description}</p>
                <div className="flex items-center gap-4 text-xs text-muted-foreground">
                  <div className="flex items-center gap-1">
                    <Users className="h-3 w-3" />
                    {course.students.toLocaleString()}
                  </div>
                  <div className="flex items-center gap-1">
                    <Star className="h-3 w-3 text-yellow-500" />
                    {course.rating}
                  </div>
                  <div className="flex items-center gap-1">
                    <BookOpen className="h-3 w-3" />
                    {course.modules.length} módulos
                  </div>
                </div>
                {isLocked ? (
                  <Button disabled size="sm" variant="outline" className="w-full opacity-60 border-border text-muted-foreground">
                    <Lock className="h-3.5 w-3.5 mr-1" />
                    Solo Pro
                  </Button>
                ) : (
                  <Button asChild size="sm" variant="outline" className="w-full border-primary/30 text-primary hover:bg-primary/10 hover:text-primary">
                    <Link href={`/cursos/detail?id=${course.id}`}>
                      {progress > 0 ? "Continuar" : "Empezar"}
                    </Link>
                  </Button>
                )}
              </CardContent>
            </Card>
          )
        })}
      </div>
    </div>
  )
}
