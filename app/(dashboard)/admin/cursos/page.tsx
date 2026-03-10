"use client"

import { useState } from "react"
import { useData } from "@/contexts/data-context"
import { useAuth } from "@/contexts/auth-context"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select"
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogFooter,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog"
import {
    AlertDialog,
    AlertDialogAction,
    AlertDialogCancel,
    AlertDialogContent,
    AlertDialogDescription,
    AlertDialogFooter,
    AlertDialogHeader,
    AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { BookOpen, Crown, Pencil, Plus, Trash2, ListTree, Video, Save, ChevronRight, ChevronDown, MoveUp, MoveDown } from "lucide-react"
import type { Course } from "@/lib/types"

type CourseForm = {
    title: string
    description: string
    category: string
    level: "basico" | "intermedio" | "avanzado"
    isPro: boolean
    students: number
    rating: number
}

const emptyForm: CourseForm = {
    title: "",
    description: "",
    category: "General",
    level: "basico",
    isPro: false,
    students: 0,
    rating: 5,
}

const levelLabels: Record<string, string> = {
    basico: "Básico",
    intermedio: "Intermedio",
    avanzado: "Avanzado",
}

const levelColors: Record<string, string> = {
    basico: "border-emerald-500/30 text-emerald-400",
    intermedio: "border-yellow-500/30 text-yellow-400",
    avanzado: "border-red-500/30 text-red-400",
}

export default function AdminCursosPage() {
    const { courses, addCourse, updateCourse, deleteCourse } = useData()
    const { user } = useAuth()

    const [dialogOpen, setDialogOpen] = useState(false)
    const [editingCourse, setEditingCourse] = useState<Course | null>(null)
    const [form, setForm] = useState<CourseForm>(emptyForm)
    const [saving, setSaving] = useState(false)
    const [deleteTarget, setDeleteTarget] = useState<Course | null>(null)
    const [deleting, setDeleting] = useState(false)

    // Module & Lesson management state
    const [contentDialogOpen, setContentDialogOpen] = useState(false)
    const [activeCourse, setActiveCourse] = useState<Course | null>(null)
    const [modules, setModules] = useState<any[]>([])
    const [loadingContent, setLoadingContent] = useState(false)

    const openContentManager = async (course: Course) => {
        setActiveCourse(course)
        setContentDialogOpen(true)
        setLoadingContent(true)
        try {
            const { data, error } = await supabase.from('course_modules').select('*, lessons:course_lessons(*)').eq('course_id', course.id).order('order_index', { ascending: true })
            if (error) throw error
            setModules(data.map(m => ({
                ...m,
                lessons: (m.lessons || []).sort((a: any, b: any) => a.order_index - b.order_index)
            })))
        } catch (e) {
            console.error(e)
        } finally {
            setLoadingContent(false)
        }
    }

    const addModule = async () => {
        if (!activeCourse) return
        const newModule = {
            course_id: activeCourse.id,
            title: "Nuevo Módulo",
            order_index: modules.length
        }
        const { data, error } = await supabase.from('course_modules').insert([newModule]).select().single()
        if (error) return console.error(error)
        setModules([...modules, { ...data, lessons: [] }])
    }

    const deleteModule = async (moduleId: string) => {
        const { error } = await supabase.from('course_modules').delete().eq('id', moduleId)
        if (error) return console.error(error)
        setModules(modules.filter(m => m.id !== moduleId))
    }

    const addLesson = async (moduleId: string) => {
        const mod = modules.find(m => m.id === moduleId)
        if (!mod) return
        const newLesson = {
            module_id: moduleId,
            title: "Nueva Lección",
            order_index: mod.lessons.length,
            duration: "10 min"
        }
        const { data, error } = await supabase.from('course_lessons').insert([newLesson]).select().single()
        if (error) return console.error(error)
        setModules(modules.map(m => m.id === moduleId ? { ...m, lessons: [...m.lessons, data] } : m))
    }

    const deleteLesson = async (moduleId: string, lessonId: string) => {
        const { error } = await supabase.from('course_lessons').delete().eq('id', lessonId)
        if (error) return console.error(error)
        setModules(modules.map(m => m.id === moduleId ? { ...m, lessons: m.lessons.filter((l: any) => l.id !== lessonId) } : m))
    }

    const updateItem = async (table: string, id: string, updates: any) => {
        await supabase.from(table).update(updates).eq('id', id)
    }

    if (user?.role !== "admin") {
        return (
            <div className="flex flex-col items-center justify-center gap-4 py-20">
                <p className="text-muted-foreground text-lg font-medium">Acceso restringido a administradores.</p>
                <div className="p-4 bg-secondary/50 border border-border rounded-lg text-xs text-muted-foreground max-w-md text-center">
                    <p>Tu rol actual: <span className="text-primary font-mono">{user?.role || "no definido"}</span></p>
                    <p className="mt-2">Si deberías tener acceso, verificá que tu perfil en Supabase tenga el rol <code className="text-primary">'admin'</code>.</p>
                </div>
            </div>
        )
    }

    const openCreate = () => {
        setEditingCourse(null)
        setForm(emptyForm)
        setDialogOpen(true)
    }

    const openEdit = (course: Course) => {
        setEditingCourse(course)
        setForm({
            title: course.title,
            description: course.description,
            category: course.category,
            level: course.level,
            isPro: course.isPro,
            students: course.students,
            rating: course.rating,
        })
        setDialogOpen(true)
    }

    const handleSave = async () => {
        if (!form.title.trim() || !form.description.trim()) return
        setSaving(true)
        try {
            if (editingCourse) {
                await updateCourse({ id: editingCourse.id, ...form })
            } else {
                await addCourse(form)
            }
            setDialogOpen(false)
            setForm(emptyForm)
        } catch (e) {
            console.error(e)
        } finally {
            setSaving(false)
        }
    }

    const handleDelete = async () => {
        if (!deleteTarget) return
        setDeleting(true)
        try {
            await deleteCourse(deleteTarget.id)
        } catch (e) {
            console.error(e)
        } finally {
            setDeleting(false)
            setDeleteTarget(null)
        }
    }

    return (
        <div className="flex flex-col gap-6">
            {/* Header */}
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-2xl font-bold text-foreground tracking-tight">Gestión de Cursos</h1>
                    <p className="text-sm text-muted-foreground mt-1">
                        Crea, edita y elimina cursos de la plataforma
                    </p>
                </div>
                <Button
                    onClick={openCreate}
                    className="bg-primary text-primary-foreground hover:bg-primary/90 gap-2"
                >
                    <Plus className="h-4 w-4" />
                    Nuevo Curso
                </Button>
            </div>

            {/* Stats summary */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                <Card className="border-border bg-card">
                    <CardContent className="flex flex-col gap-1 p-4">
                        <p className="text-xs text-muted-foreground">Total cursos</p>
                        <p className="text-2xl font-bold text-foreground">{courses.length}</p>
                    </CardContent>
                </Card>
                <Card className="border-border bg-card">
                    <CardContent className="flex flex-col gap-1 p-4">
                        <p className="text-xs text-muted-foreground">Gratuitos</p>
                        <p className="text-2xl font-bold text-emerald-400">{courses.filter(c => !c.isPro).length}</p>
                    </CardContent>
                </Card>
                <Card className="border-border bg-card">
                    <CardContent className="flex flex-col gap-1 p-4">
                        <p className="text-xs text-muted-foreground">Pro</p>
                        <p className="text-2xl font-bold text-yellow-400">{courses.filter(c => c.isPro).length}</p>
                    </CardContent>
                </Card>
                <Card className="border-border bg-card">
                    <CardContent className="flex flex-col gap-1 p-4">
                        <p className="text-xs text-muted-foreground">Estudiantes totales</p>
                        <p className="text-2xl font-bold text-foreground">{courses.reduce((acc, c) => acc + c.students, 0).toLocaleString()}</p>
                    </CardContent>
                </Card>
            </div>

            {/* Courses table */}
            {courses.length === 0 ? (
                <Card className="border-border bg-card">
                    <CardContent className="flex flex-col items-center justify-center gap-4 py-16">
                        <BookOpen className="h-12 w-12 text-muted-foreground/30" />
                        <p className="text-muted-foreground text-sm">No hay cursos todavía. Crea el primero.</p>
                        <Button onClick={openCreate} variant="outline" className="border-primary/30 text-primary hover:bg-primary/10">
                            <Plus className="h-4 w-4 mr-2" />
                            Crear Curso
                        </Button>
                    </CardContent>
                </Card>
            ) : (
                <Card className="border-border bg-card">
                    <CardHeader className="pb-2">
                        <CardTitle className="text-sm text-card-foreground">Todos los cursos</CardTitle>
                    </CardHeader>
                    <CardContent className="p-0">
                        <div className="divide-y divide-border">
                            {courses.map((course) => (
                                <div
                                    key={course.id}
                                    className="flex items-center gap-4 px-6 py-4 hover:bg-secondary/30 transition-colors"
                                >
                                    {/* Course info */}
                                    <div className="flex-1 min-w-0">
                                        <div className="flex items-center gap-2 flex-wrap">
                                            <p className="text-sm font-medium text-card-foreground truncate">{course.title}</p>
                                            {course.isPro && (
                                                <Badge className="shrink-0 bg-yellow-500/20 text-yellow-500 border-yellow-500/30 text-[10px] px-1.5 py-0">
                                                    <Crown className="h-2.5 w-2.5 mr-0.5" />
                                                    Pro
                                                </Badge>
                                            )}
                                        </div>
                                        <p className="text-xs text-muted-foreground truncate mt-0.5">{course.description}</p>
                                    </div>

                                    {/* Metadata */}
                                    <div className="hidden md:flex items-center gap-3 shrink-0">
                                        <Badge variant="outline" className={`text-[10px] capitalize ${levelColors[course.level]}`}>
                                            {levelLabels[course.level] || course.level}
                                        </Badge>
                                        <span className="text-xs text-muted-foreground">{course.category}</span>
                                        <span className="text-xs text-muted-foreground">{course.students.toLocaleString()} estudiantes</span>
                                        <Badge
                                            variant="outline"
                                            className={`text-[10px] ${course.isPro ? "border-yellow-500/30 text-yellow-400" : "border-emerald-500/30 text-emerald-400"}`}
                                        >
                                            {course.isPro ? "Pro" : "Gratuito"}
                                        </Badge>
                                    </div>

                                    {/* Actions */}
                                    <div className="flex items-center gap-2 shrink-0">
                                        <Button
                                            size="icon"
                                            variant="ghost"
                                            className="h-8 w-8 text-primary hover:text-primary hover:bg-primary/10"
                                            onClick={() => openContentManager(course)}
                                            title="Gestionar Contenido (Módulos y Lecciones)"
                                        >
                                            <ListTree className="h-3.5 w-3.5" />
                                        </Button>
                                        <Button
                                            size="icon"
                                            variant="ghost"
                                            className="h-8 w-8 text-muted-foreground hover:text-foreground hover:bg-secondary"
                                            onClick={() => openEdit(course)}
                                        >
                                            <Pencil className="h-3.5 w-3.5" />
                                        </Button>
                                        <Button
                                            size="icon"
                                            variant="ghost"
                                            className="h-8 w-8 text-muted-foreground hover:text-red-400 hover:bg-red-500/10"
                                            onClick={() => setDeleteTarget(course)}
                                        >
                                            <Trash2 className="h-3.5 w-3.5" />
                                        </Button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </CardContent>
                </Card>
            )}

            {/* Create / Edit Dialog */}
            <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
                <DialogContent className="sm:max-w-lg bg-card border-border text-card-foreground">
                    <DialogHeader>
                        <DialogTitle>{editingCourse ? "Editar Curso" : "Nuevo Curso"}</DialogTitle>
                        <DialogDescription className="text-muted-foreground">
                            {editingCourse
                                ? "Modifica los datos del curso y guarda los cambios."
                                : "Completa los datos del nuevo curso."}
                        </DialogDescription>
                    </DialogHeader>

                    <div className="flex flex-col gap-4 py-1">
                        {/* Title */}
                        <div className="flex flex-col gap-1.5">
                            <Label htmlFor="course-title" className="text-sm text-card-foreground">
                                Título <span className="text-red-400">*</span>
                            </Label>
                            <Input
                                id="course-title"
                                placeholder="Ej: Finanzas para Emprendedores"
                                value={form.title}
                                onChange={(e) => setForm((f) => ({ ...f, title: e.target.value }))}
                                className="bg-secondary border-border text-foreground placeholder:text-muted-foreground focus-visible:ring-primary"
                            />
                        </div>

                        {/* Description */}
                        <div className="flex flex-col gap-1.5">
                            <Label htmlFor="course-desc" className="text-sm text-card-foreground">
                                Descripción <span className="text-red-400">*</span>
                            </Label>
                            <Textarea
                                id="course-desc"
                                placeholder="Describe brevemente el curso..."
                                rows={3}
                                value={form.description}
                                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
                                className="bg-secondary border-border text-foreground placeholder:text-muted-foreground focus-visible:ring-primary resize-none"
                            />
                        </div>

                        {/* Category */}
                        <div className="flex flex-col gap-1.5">
                            <Label htmlFor="course-category" className="text-sm text-card-foreground">
                                Categoría
                            </Label>
                            <Input
                                id="course-category"
                                placeholder="Ej: Finanzas, Marketing, Ventas..."
                                value={form.category}
                                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
                                className="bg-secondary border-border text-foreground placeholder:text-muted-foreground focus-visible:ring-primary"
                            />
                        </div>

                        <div className="grid grid-cols-2 gap-4">
                            {/* Level */}
                            <div className="flex flex-col gap-1.5">
                                <Label className="text-sm text-card-foreground">Nivel</Label>
                                <Select
                                    value={form.level}
                                    onValueChange={(v: "basico" | "intermedio" | "avanzado") =>
                                        setForm((f) => ({ ...f, level: v }))
                                    }
                                >
                                    <SelectTrigger className="bg-secondary border-border text-foreground focus:ring-primary">
                                        <SelectValue />
                                    </SelectTrigger>
                                    <SelectContent className="bg-card border-border text-card-foreground">
                                        <SelectItem value="basico">Básico</SelectItem>
                                        <SelectItem value="intermedio">Intermedio</SelectItem>
                                        <SelectItem value="avanzado">Avanzado</SelectItem>
                                    </SelectContent>
                                </Select>
                            </div>

                            {/* Plan */}
                            <div className="flex flex-col gap-1.5">
                                <Label className="text-sm text-card-foreground">Plan</Label>
                                <Select
                                    value={form.isPro ? "pro" : "free"}
                                    onValueChange={(v) => setForm((f) => ({ ...f, isPro: v === "pro" }))}
                                >
                                    <SelectTrigger className="bg-secondary border-border text-foreground focus:ring-primary">
                                        <SelectValue />
                                    </SelectTrigger>
                                    <SelectContent className="bg-card border-border text-card-foreground">
                                        <SelectItem value="free">Gratuito</SelectItem>
                                        <SelectItem value="pro">Pro</SelectItem>
                                    </SelectContent>
                                </Select>
                            </div>
                        </div>
                    </div>

                    <DialogFooter className="gap-2">
                        <Button
                            variant="ghost"
                            className="text-muted-foreground hover:text-foreground"
                            onClick={() => setDialogOpen(false)}
                            disabled={saving}
                        >
                            Cancelar
                        </Button>
                        <Button
                            onClick={handleSave}
                            disabled={saving || !form.title.trim() || !form.description.trim()}
                            className="bg-primary text-primary-foreground hover:bg-primary/90"
                        >
                            {saving ? "Guardando..." : editingCourse ? "Guardar cambios" : "Crear curso"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

            {/* Content Management Dialog */}
            <Dialog open={contentDialogOpen} onOpenChange={setContentDialogOpen}>
                <DialogContent className="sm:max-w-4xl max-h-[90vh] overflow-y-auto bg-card border-border text-card-foreground">
                    <DialogHeader>
                        <DialogTitle>Gestionar Contenido: {activeCourse?.title}</DialogTitle>
                        <DialogDescription>
                            Organiza los módulos y lecciones del curso.
                        </DialogDescription>
                    </DialogHeader>

                    <div className="flex flex-col gap-6 py-4">
                        {loadingContent ? (
                            <div className="flex justify-center py-10 text-muted-foreground">Cargando contenido...</div>
                        ) : (
                            <div className="flex flex-col gap-4">
                                {modules.map((mod, modIdx) => (
                                    <div key={mod.id} className="border border-border rounded-lg bg-secondary/20 overflow-hidden">
                                        <div className="flex items-center gap-3 p-3 bg-secondary/40 border-b border-border">
                                            <Input 
                                                className="h-8 bg-transparent border-none text-sm font-semibold focus-visible:ring-0 p-0" 
                                                value={mod.title}
                                                onChange={(e) => {
                                                    const newTitle = e.target.value
                                                    setModules(modules.map(m => m.id === mod.id ? { ...m, title: newTitle } : m))
                                                }}
                                                onBlur={(e) => updateItem('course_modules', mod.id, { title: e.target.value })}
                                            />
                                            <div className="flex items-center gap-1">
                                                <Button size="icon" variant="ghost" className="h-7 w-7 text-muted-foreground" onClick={() => deleteModule(mod.id)}>
                                                    <Trash2 className="h-3 w-3" />
                                                </Button>
                                            </div>
                                        </div>
                                        <div className="p-3 flex flex-col gap-2">
                                            {mod.lessons.map((lesson: any, lessonIdx: number) => (
                                                <div key={lesson.id} className="flex items-center gap-2 p-2 bg-card border border-border rounded-md group">
                                                    <Video className="h-3.5 w-3.5 text-muted-foreground" />
                                                    <Input 
                                                        className="flex-1 h-7 bg-transparent border-none text-xs focus-visible:ring-0 p-0" 
                                                        value={lesson.title}
                                                        onChange={(e) => {
                                                            const newTitle = e.target.value
                                                            setModules(modules.map(m => m.id === mod.id ? {
                                                                ...m,
                                                                lessons: m.lessons.map((l: any) => l.id === lesson.id ? { ...l, title: newTitle } : l)
                                                            } : m))
                                                        }}
                                                        onBlur={(e) => updateItem('course_lessons', lesson.id, { title: e.target.value })}
                                                    />
                                                    <Input 
                                                        className="w-20 h-7 bg-secondary/50 border-none text-[10px] text-center focus-visible:ring-0" 
                                                        value={lesson.duration}
                                                        placeholder="Duración"
                                                        onChange={(e) => {
                                                            const newDur = e.target.value
                                                            setModules(modules.map(m => m.id === mod.id ? {
                                                                ...m,
                                                                lessons: m.lessons.map((l: any) => l.id === lesson.id ? { ...l, duration: newDur } : l)
                                                            } : m))
                                                        }}
                                                        onBlur={(e) => updateItem('course_lessons', lesson.id, { duration: e.target.value })}
                                                    />
                                                    <Button size="icon" variant="ghost" className="h-7 w-7 text-muted-foreground opacity-0 group-hover:opacity-100 transition-opacity" onClick={() => deleteLesson(mod.id, lesson.id)}>
                                                        <Trash2 className="h-3 w-3" />
                                                    </Button>
                                                </div>
                                            ))}
                                            <Button variant="ghost" size="sm" className="w-fit h-8 text-[10px] text-primary hover:bg-primary/5 gap-1.5" onClick={() => addLesson(mod.id)}>
                                                <Plus className="h-3 w-3" />
                                                Añadir Lección
                                            </Button>
                                        </div>
                                    </div>
                                ))}
                                <Button variant="outline" className="w-full border-dashed border-primary/30 text-primary hover:bg-primary/5 gap-2" onClick={addModule}>
                                    <Plus className="h-4 w-4" />
                                    Añadir Módulo
                                </Button>
                            </div>
                        )}
                    </div>
                </DialogContent>
            </Dialog>

            {/* Delete Confirmation */}
            <AlertDialog open={!!deleteTarget} onOpenChange={(o) => !o && setDeleteTarget(null)}>
                <AlertDialogContent className="bg-card border-border text-card-foreground">
                    <AlertDialogHeader>
                        <AlertDialogTitle>¿Eliminar curso?</AlertDialogTitle>
                        <AlertDialogDescription className="text-muted-foreground">
                            Estás a punto de eliminar <strong className="text-foreground">"{deleteTarget?.title}"</strong>. Esta acción no se puede deshacer y eliminará el progreso de todos los estudiantes.
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel
                            className="border-border text-muted-foreground hover:text-foreground bg-transparent"
                            disabled={deleting}
                        >
                            Cancelar
                        </AlertDialogCancel>
                        <AlertDialogAction
                            onClick={handleDelete}
                            disabled={deleting}
                            className="bg-red-500 text-white hover:bg-red-600"
                        >
                            {deleting ? "Eliminando..." : "Eliminar"}
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>
        </div>
    )
}
