"use client"

import { useState, useEffect, use } from "react"
import Link from "next/link"
import { useAuth } from "@/contexts/auth-context"
import { courseService } from "@/lib/services/courseService"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { PlanGate } from "@/components/shared/plan-gate"
import { ArrowLeft, CheckCircle2, Circle, Clock, Crown, Star, Users, Pencil, PlayCircle, CheckCircle, Video } from "lucide-react"

export default function CourseDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params)
  const { user } = useAuth()
  const [course, setCourse] = useState<any>(null)
  const [loading, setLoading] = useState(true)
  const [enrolled, setEnrolled] = useState(false)
  const [progress, setProgress] = useState(0)
  const [selectedLesson, setSelectedLesson] = useState<any>(null)

  useEffect(() => {
    async function init() {
      try {
        const detail = await courseService.getCourseDetail(id)
        setCourse(detail)
        
        if (user) {
          const isEnrolled = await courseService.isEnrolled(user.id, id)
          setEnrolled(isEnrolled)
          if (isEnrolled) {
            const p = await courseService.getCourseProgress(user.id, id)
            setProgress(p)
          }
        }
      } catch (e) {
        console.error(e)
      } finally {
        setLoading(false)
      }
    }
    init()
  }, [id, user])

  const handleEnroll = async () => {
    if (!user) return
    try {
      await courseService.enrollUser(user.id, id)
      setEnrolled(true)
      const p = await courseService.getCourseProgress(user.id, id)
      setProgress(p)
    } catch (e) {
      console.error(e)
    }
  }

  const toggleLesson = async (lessonId: string, completed: boolean) => {
    if (!user) return
    try {
      await courseService.updateLessonProgress(user.id, lessonId, !completed)
      // Refresh course detail to get updated lesson status if needed, 
      // or just update local state
      const detail = await courseService.getCourseDetail(id)
      setCourse(detail)
      const p = await courseService.getCourseProgress(user.id, id)
      setProgress(p)
    } catch (e) {
      console.error(e)
    }
  }

  if (loading) return <div className="py-20 text-center text-muted-foreground">Cargando curso...</div>

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

  const lessonsCount = course.modules?.reduce((acc: number, m: any) => acc + (m.lessons?.length || 0), 0) || 0

  const content = (
    <div className="flex flex-col gap-6">
      <div className="flex items-center gap-2">
        <Button asChild variant="ghost" size="icon" className="h-8 w-8 text-muted-foreground hover:text-foreground">
          <Link href="/cursos"><ArrowLeft className="h-4 w-4" /></Link>
        </Button>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold text-foreground tracking-tight">{course.title}</h1>
            {course.is_pro && (
              <Badge className="bg-yellow-500/20 text-yellow-500 border-yellow-500/30">
                <Crown className="h-3 w-3 mr-0.5" />
                Pro
              </Badge>
            )}
            {user?.role === "admin" && (
              <Button asChild variant="outline" size="sm" className="ml-2 border-primary/30 text-primary hover:bg-primary/10 h-7 text-[10px] px-2">
                <Link href={`/admin/cursos`}>
                  <Pencil className="h-3 w-3 mr-1" />
                  Editar
                </Link>
              </Button>
            )}
          </div>
          <p className="text-sm text-muted-foreground mt-1">{course.description}</p>
        </div>
      </div>

      <div className="flex items-center gap-6 text-sm text-muted-foreground">
        <div className="flex items-center gap-1.5">
          <Users className="h-4 w-4" />
          {course.students?.toLocaleString() || 0} estudiantes
        </div>
        <div className="flex items-center gap-1.5">
          <Star className="h-4 w-4 text-yellow-500" />
          {course.rating || 5}
        </div>
        <Badge variant="outline" className="capitalize border-border text-muted-foreground">{course.level}</Badge>
      </div>

      <div className="grid gap-4 grid-cols-1 lg:grid-cols-3">
        <div className="lg:col-span-2 flex flex-col gap-6">
          {selectedLesson && (
            <Card className="border-primary/30 bg-primary/5 p-6 flex flex-col gap-4">
               <div className="flex items-center justify-between">
                  <h3 className="font-semibold text-foreground flex items-center gap-2">
                    <Video className="h-4 w-4" /> {selectedLesson.title}
                  </h3>
                  <Button variant="ghost" size="sm" onClick={() => setSelectedLesson(null)}>Cerrar</Button>
               </div>
               <div className="aspect-video bg-black rounded-lg flex items-center justify-center text-muted-foreground border border-border">
                  {selectedLesson.content_url ? (
                    <p>Vid: {selectedLesson.content_url}</p>
                  ) : (
                    <p>Contenido de la lección no disponible</p>
                  )}
               </div>
               <div className="flex items-center justify-between">
                  <p className="text-sm text-muted-foreground">{selectedLesson.description || "Sin descripción"}</p>
                  <Button size="sm" className="gap-2" onClick={() => toggleLesson(selectedLesson.id, false)}>
                    Marcar como completada
                  </Button>
               </div>
            </Card>
          )}

          <div className="flex flex-col gap-3">
            <h2 className="text-lg font-semibold text-foreground">Programa del curso</h2>
            {course.modules?.map((mod: any, i: number) => (
              <div key={mod.id} className="flex flex-col gap-2">
                <h3 className="text-sm font-medium text-muted-foreground px-1 mt-2">{i+1}. {mod.title}</h3>
                <div className="flex flex-col gap-2">
                  {mod.lessons?.map((lesson: any) => (
                    <Card key={lesson.id} className={`border-border bg-card hover:border-primary/20 transition-colors ${selectedLesson?.id === lesson.id ? "border-primary/40 bg-primary/5" : ""}`}>
                      <CardContent className="flex items-center gap-3 p-4">
                        <Button variant="ghost" size="icon" className="h-8 w-8 shrink-0" onClick={() => setSelectedLesson(lesson)}>
                          <PlayCircle className="h-5 w-5 text-primary" />
                        </Button>
                        <div className="flex-1 cursor-pointer" onClick={() => setSelectedLesson(lesson)}>
                          <p className="text-sm font-medium text-card-foreground line-clamp-1">{lesson.title}</p>
                          <p className="text-[10px] text-muted-foreground">{lesson.duration}</p>
                        </div>
                        <Button variant="ghost" size="icon" className="h-8 w-8 shrink-0" onClick={() => toggleLesson(lesson.id, false)}>
                           <Circle className="h-5 w-5 text-muted-foreground" />
                        </Button>
                      </CardContent>
                    </Card>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        <div>
          <Card className="border-border bg-card sticky top-4">
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-card-foreground">Tu progreso</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              {!enrolled ? (
                <div className="flex flex-col gap-4">
                  <p className="text-xs text-muted-foreground">Inscríbete para seguir tu progreso y acceder a todo el material.</p>
                  <Button className="w-full bg-primary text-primary-foreground hover:bg-primary/90" onClick={handleEnroll}>
                    Inscribirme ahora
                  </Button>
                </div>
              ) : (
                <>
                  <div className="text-3xl font-bold text-foreground">
                    {progress}%
                  </div>
                  <div className="h-2 w-full rounded-full bg-secondary">
                    <div
                      className="h-full rounded-full bg-primary transition-all"
                      style={{ width: `${progress}%` }}
                    />
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {progress === 100
                      ? "¡Felicidades! Curso completado"
                      : "Sigue aprendiendo para completar el curso"}
                  </p>
                </>
              )}
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  )

  if (course.is_pro && user?.plan !== "pro") {
    return <PlanGate requiredPlan="pro" featureName="este curso">{content}</PlanGate>
  }

  return content
}
