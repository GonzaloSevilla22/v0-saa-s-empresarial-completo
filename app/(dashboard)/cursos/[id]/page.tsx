"use client"

import { use } from "react"
import Link from "next/link"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { PlanGate } from "@/components/shared/plan-gate"
import { ArrowLeft, CheckCircle2, Circle, Clock, Crown, Star, Users } from "lucide-react"

export default function CourseDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params)
  const { courses } = useData()
  const { user } = useAuth()
  const course = courses.find((c) => c.id === id)

  if (!course) {
    return (
      <div className="flex flex-col items-center justify-center gap-4 py-20">
        <p className="text-muted-foreground">Curso no encontrado</p>
        <Button asChild variant="outline" className="border-border text-foreground">
          <Link href="/cursos">Volver a cursos</Link>
        </Button>
      </div>
    )
  }

  const completedModules = course.modules.filter((m) => m.completed).length

  const content = (
    <div className="flex flex-col gap-6">
      <div className="flex items-center gap-2">
        <Button asChild variant="ghost" size="icon" className="h-8 w-8 text-muted-foreground hover:text-foreground">
          <Link href="/cursos"><ArrowLeft className="h-4 w-4" /></Link>
        </Button>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold text-foreground tracking-tight">{course.title}</h1>
            {course.isPro && (
              <Badge className="bg-yellow-500/20 text-yellow-500 border-yellow-500/30">
                <Crown className="h-3 w-3 mr-0.5" />
                Pro
              </Badge>
            )}
          </div>
          <p className="text-sm text-muted-foreground mt-1">{course.description}</p>
        </div>
      </div>

      <div className="flex items-center gap-6 text-sm text-muted-foreground">
        <div className="flex items-center gap-1.5">
          <Users className="h-4 w-4" />
          {course.students.toLocaleString()} estudiantes
        </div>
        <div className="flex items-center gap-1.5">
          <Star className="h-4 w-4 text-yellow-500" />
          {course.rating}
        </div>
        <Badge variant="outline" className="capitalize border-border text-muted-foreground">{course.level}</Badge>
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 flex flex-col gap-3">
          <h2 className="text-lg font-semibold text-foreground">Modulos</h2>
          {course.modules.map((mod, i) => (
            <Card key={mod.id} className={`border-border bg-card ${mod.completed ? "border-primary/30" : ""}`}>
              <CardContent className="flex items-center gap-3 p-4">
                {mod.completed ? (
                  <CheckCircle2 className="h-5 w-5 shrink-0 text-primary" />
                ) : (
                  <Circle className="h-5 w-5 shrink-0 text-muted-foreground" />
                )}
                <div className="flex-1">
                  <p className={`text-sm font-medium ${mod.completed ? "text-primary" : "text-card-foreground"}`}>
                    {i + 1}. {mod.title}
                  </p>
                </div>
                <div className="flex items-center gap-1 text-xs text-muted-foreground">
                  <Clock className="h-3 w-3" />
                  {mod.duration}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>

        <div>
          <Card className="border-border bg-card sticky top-4">
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-card-foreground">Tu progreso</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              <div className="text-3xl font-bold text-foreground">
                {completedModules}/{course.modules.length}
              </div>
              <div className="h-2 w-full rounded-full bg-secondary">
                <div
                  className="h-full rounded-full bg-primary transition-all"
                  style={{ width: `${(completedModules / course.modules.length) * 100}%` }}
                />
              </div>
              <p className="text-xs text-muted-foreground">
                {completedModules === course.modules.length
                  ? "Curso completado"
                  : `${course.modules.length - completedModules} modulos restantes`}
              </p>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  )

  if (course.isPro && user?.plan !== "pro") {
    return <PlanGate requiredPlan="pro" featureName="este curso">{content}</PlanGate>
  }

  return content
}
