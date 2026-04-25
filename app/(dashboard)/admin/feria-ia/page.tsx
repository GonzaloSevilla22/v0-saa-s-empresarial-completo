"use client"

import { useState, useEffect } from "react"
import { fairAiToolsService, FairAiTool } from "@/lib/services/fairAiToolsService"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
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
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { Plus, Edit2, Trash2, Sparkles, Activity, Loader2, MousePointer2, TrendingUp, CheckCircle, XCircle } from "lucide-react"
import { toast } from "sonner"
import TimeSeriesLinesChart from "@/components/admin/charts/TimeSeriesLinesChart"

export default function AdminFeriaIaPage() {
  const [tools, setTools] = useState<FairAiTool[]>([])
  const [loading, setLoading] = useState(true)
  const [stats, setStats] = useState<any>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [selectedTool, setSelectedTool] = useState<Partial<FairAiTool> | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<FairAiTool | null>(null)
  const [isDeleting, setIsDeleting] = useState(false)
  
  const [formData, setFormData] = useState<Partial<FairAiTool>>({
    name: "",
    category: "",
    description: "",
    link: "",
    status: 'active'
  })

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    try {
      setLoading(true)
      const [list, metrics] = await Promise.all([
        fairAiToolsService.getAllTools(),
        fairAiToolsService.getAdminStats()
      ])
      setTools(list)
      setStats(metrics)
    } catch (error) {
      console.error("Error loading tools:", error)
      toast.error("Error al cargar herramientas IA")
    } finally {
      setLoading(false)
    }
  }

  function handleOpenDialog(tool?: FairAiTool) {
    if (tool) {
      setSelectedTool(tool)
      setFormData(tool)
    } else {
      setSelectedTool(null)
      setFormData({
        name: "",
        category: "",
        description: "",
        link: "",
        status: 'active'
      })
    }
    setIsDialogOpen(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    try {
      if (selectedTool?.id) {
        await fairAiToolsService.updateTool(selectedTool.id, formData)
        toast.success("Herramienta actualizada")
      } else {
        await fairAiToolsService.createTool(formData)
        toast.success("Herramienta creada")
      }
      setIsDialogOpen(false)
      loadData()
    } catch (error) {
      console.error("Error saving tool:", error)
      toast.error("Error al guardar")
    }
  }

  async function handleDelete() {
    if (!deleteTarget) return
    try {
      setIsDeleting(true)
      await fairAiToolsService.deleteTool(deleteTarget.id)
      toast.success("Herramienta eliminada")
      setDeleteTarget(null)
      loadData()
    } catch (error) {
      toast.error("Error al eliminar")
    } finally {
      setIsDeleting(false)
    }
  }

  if (loading && !stats) return (
    <div className="flex flex-col items-center justify-center py-32 gap-4">
      <Loader2 className="h-8 w-8 animate-spin text-emerald-500" />
      <p className="text-slate-400 text-sm italic">Preparando ecosistema IA...</p>
    </div>
  )

  return (
    <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700 pb-20 space-y-8">
      <header className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold text-slate-100 tracking-tight flex items-center gap-3">
             <Sparkles className="w-8 h-8 text-purple-500" />
             Gestión Feria IA
          </h1>
          <p className="text-slate-400 mt-1">Administra las herramientas predictivas disponibles para feriantes.</p>
        </div>
        <Button onClick={() => handleOpenDialog()} className="bg-purple-600 hover:bg-purple-700 text-white gap-2 shadow-lg shadow-purple-500/20">
          <Plus className="h-5 w-5" />
          Agregar Herramienta IA
        </Button>
      </header>

      {/* Metrics Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <KpiSummaryCard 
          title="Total Herramientas" 
          value={stats?.total || 0} 
          subtext="En el repositorio IA" 
          icon={Sparkles} 
          badge="Catálogo" 
          iconColor="text-purple-400" 
        />
        <KpiSummaryCard 
          title="Herramientas Activas" 
          value={stats?.active || 0} 
          subtext="Visibles para usuarios" 
          icon={CheckCircle} 
          badge="Ready" 
          iconColor="text-emerald-400" 
        />
        <KpiSummaryCard 
          title="Clicks en Herramientas" 
          value={stats?.totalClicks || 0} 
          subtext="Interacción acumulada" 
          icon={MousePointer2} 
          badge="Growth" 
          iconColor="text-blue-400" 
        />
        <KpiSummaryCard 
          title="Nuevas (Mes)" 
          value={stats?.newThisMonth || 0} 
          subtext="Agregadas recientemente" 
          icon={Plus} 
          badge="Update" 
          iconColor="text-amber-400" 
        />
      </div>

      {/* Chart */}
      <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
        <div className="flex items-center gap-2 mb-6">
          <TrendingUp className="w-5 h-5 text-purple-500" />
          <h2 className="text-xl font-bold text-slate-100">Evolución temporal</h2>
        </div>
        <div className="aspect-[21/9] w-full flex items-center justify-center p-4">
          {stats?.timeSeries && stats.timeSeries.length > 0 ? (
            <TimeSeriesLinesChart data={stats.timeSeries} width={1000} height={350} />
          ) : (
            <span className="text-slate-500 italic">Esperando recolección de datos...</span>
          )}
        </div>
      </section>

      {/* Table */}
      <Card className="border-slate-800 bg-slate-900/40 backdrop-blur-md overflow-hidden rounded-2xl">
        <CardHeader>
          <CardTitle className="text-lg">Herramientas IA Configuradas</CardTitle>
          <CardDescription className="text-slate-400">Controla la visibilidad y metadata de cada recurso IA.</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader className="bg-slate-800/50">
              <TableRow className="border-slate-800">
                <TableHead className="text-slate-300">Herramienta</TableHead>
                <TableHead className="text-slate-300">Categoría</TableHead>
                <TableHead className="text-slate-300">Descripción</TableHead>
                <TableHead className="text-slate-300 text-center">Estado</TableHead>
                <TableHead className="text-slate-300">Clicks</TableHead>
                <TableHead className="text-slate-300 text-right">Acciones</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {tools.length === 0 ? (
                <TableRow className="border-slate-800">
                  <TableCell colSpan={6} className="text-center py-10 text-slate-500 italic">
                    Sin herramientas IA registradas.
                  </TableCell>
                </TableRow>
              ) : (
                tools.map((item) => (
                  <TableRow key={item.id} className="border-slate-800 hover:bg-slate-800/30 transition-colors">
                    <TableCell className="font-medium text-slate-200">{item.name}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className="text-[10px] uppercase border-purple-500/30 text-purple-400 bg-purple-500/5">
                        {item.category}
                      </Badge>
                    </TableCell>
                    <TableCell className="max-w-[180px] truncate text-slate-400 text-xs">{item.description}</TableCell>
                    <TableCell className="text-center">
                      {item.status === 'active' ? (
                        <div className="flex items-center gap-1.5 justify-center text-emerald-500 text-xs">
                          <CheckCircle className="h-4 w-4" /> Activa
                        </div>
                      ) : (
                        <div className="flex items-center gap-1.5 justify-center text-amber-500 text-xs">
                          <XCircle className="h-4 w-4" /> Inactiva
                        </div>
                      )}
                    </TableCell>
                    <TableCell className="text-slate-300 font-mono text-xs">{item.clicks_count || 0}</TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-2">
                        <Button variant="outline" size="icon" className="h-8 w-8 border-slate-700" onClick={() => handleOpenDialog(item)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                        <Button variant="outline" size="icon" className="h-8 w-8 text-red-400 border-slate-700" onClick={() => setDeleteTarget(item)}>
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <AlertDialog open={!!deleteTarget} onOpenChange={(o) => !o && setDeleteTarget(null)}>
        <AlertDialogContent className="bg-slate-900 border-slate-800 text-slate-100">
          <AlertDialogHeader>
            <AlertDialogTitle>¿Eliminar herramienta?</AlertDialogTitle>
            <AlertDialogDescription className="text-slate-400">
              Estás a punto de eliminar <strong className="text-slate-200">"{deleteTarget?.name}"</strong>. Esta acción no se puede deshacer.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-slate-700 text-slate-400 hover:bg-slate-800 bg-transparent" disabled={isDeleting}>
              Cancelar
            </AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete} disabled={isDeleting} className="bg-red-600 hover:bg-red-700 text-white">
              {isDeleting ? "Eliminando..." : "Eliminar"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
        <DialogContent className="max-w-md bg-slate-900 border-slate-800 text-slate-100">
          <form onSubmit={handleSubmit}>
            <DialogHeader>
              <DialogTitle className="text-xl font-bold">{selectedTool ? "Editar Herramienta" : "Nueva Herramienta IA"}</DialogTitle>
            </DialogHeader>
            <div className="grid gap-5 py-6">
              <div className="grid gap-2">
                <Label htmlFor="name">Nombre de la Herramienta</Label>
                <Input
                  id="name"
                  value={formData.name}
                  onChange={(e) => setFormData({ ...formData, name: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                  required
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="category">Categoría</Label>
                <Input
                  id="category"
                  placeholder="Ej: Análisis de Ventas"
                  value={formData.category}
                  onChange={(e) => setFormData({ ...formData, category: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                  required
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="description">Descripción</Label>
                <Textarea
                  id="description"
                  value={formData.description}
                  onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="link">Enlace de acceso</Label>
                <Input
                  id="link"
                  placeholder="/ferias/ia/..."
                  value={formData.link}
                  onChange={(e) => setFormData({ ...formData, link: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                />
              </div>
              <div className="flex items-center justify-between p-3 rounded-lg bg-slate-800 border border-slate-700">
                <Label htmlFor="status">Estado Activo</Label>
                <Switch
                  id="status"
                  checked={formData.status === 'active'}
                  onCheckedChange={(checked) => setFormData({ ...formData, status: checked ? 'active' : 'inactive' })}
                />
              </div>
            </div>
            <DialogFooter>
              <Button type="submit" className="bg-purple-600 hover:bg-purple-700 w-full text-white">
                {selectedTool ? "Guardar Cambios" : "Crear Recurso IA"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function KpiSummaryCard({ title, value, subtext, icon: Icon, badge, iconColor = "text-emerald-500" }: any) {
    return (
        <div className="bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800 relative overflow-hidden group">
            <div className={`absolute top-0 right-0 p-4 opacity-5 group-hover:opacity-10 transition-opacity ${iconColor}`}>
                <Icon className="w-12 h-12" />
            </div>
            <div className="flex items-center space-x-2 text-slate-400 mb-2">
                <Icon className={`w-4 h-4 ${iconColor}`} />
                <p className="text-xs font-medium uppercase tracking-wider text-slate-500">{title}</p>
            </div>
            <div className="flex items-end justify-between">
                <div>
                    <p className="text-3xl font-bold text-slate-100">{value}</p>
                    <p className="text-xs text-slate-500 mt-1">{subtext}</p>
                </div>
                <span className={`flex items-center text-[10px] font-bold px-2 py-0.5 rounded uppercase ${iconColor} bg-current/10 border border-current/20`}>
                    {badge}
                </span>
            </div>
        </div>
    )
}
