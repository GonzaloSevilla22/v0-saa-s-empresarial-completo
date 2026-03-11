"use client"

import { useState, useEffect } from "react"
import { copilotPromptsService, CopilotPrompt } from "@/lib/services/copilotPromptsService"
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
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import { Label } from "@/components/ui/label"
import { Plus, Edit2, Trash2, Bot, Activity, Loader2, MessageSquare, TrendingUp, CheckCircle, XCircle } from "lucide-react"
import { toast } from "sonner"
import TimeSeriesLinesChart from "@/components/admin/charts/TimeSeriesLinesChart"

export default function AdminCopilotIaPage() {
  const [prompts, setPrompts] = useState<CopilotPrompt[]>([])
  const [loading, setLoading] = useState(true)
  const [stats, setStats] = useState<any>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [selectedPrompt, setSelectedPrompt] = useState<Partial<CopilotPrompt> | null>(null)
  
  const [formData, setFormData] = useState<Partial<CopilotPrompt>>({
    name: "",
    category: "",
    description: "",
    prompt_text: "",
    status: 'active'
  })

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    try {
      setLoading(true)
      const [list, metrics] = await Promise.all([
        copilotPromptsService.getAllPrompts(),
        copilotPromptsService.getAdminStats()
      ])
      setPrompts(list)
      setStats(metrics)
    } catch (error) {
      console.error("Error loading prompts:", error)
      toast.error("Error al cargar prompts de IA")
    } finally {
      setLoading(false)
    }
  }

  function handleOpenDialog(prompt?: CopilotPrompt) {
    if (prompt) {
      setSelectedPrompt(prompt)
      setFormData(prompt)
    } else {
      setSelectedPrompt(null)
      setFormData({
        name: "",
        category: "",
        description: "",
        prompt_text: "",
        status: 'active'
      })
    }
    setIsDialogOpen(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    try {
      if (selectedPrompt?.id) {
        await copilotPromptsService.updatePrompt(selectedPrompt.id, formData)
        toast.success("Prompt actualizado")
      } else {
        await copilotPromptsService.createPrompt(formData)
        toast.success("Prompt creado")
      }
      setIsDialogOpen(false)
      loadData()
    } catch (error) {
      console.error("Error saving prompt:", error)
      toast.error("Error al guardar")
    }
  }

  async function handleDelete(id: string) {
    if (!confirm("¿Eliminar este prompt?")) return
    try {
      await copilotPromptsService.deletePrompt(id)
      toast.success("Eliminado")
      loadData()
    } catch (error) {
      toast.error("Error al eliminar")
    }
  }

  if (loading && !stats) return (
    <div className="flex flex-col items-center justify-center py-32 gap-4">
      <Loader2 className="h-8 w-8 animate-spin text-emerald-500" />
      <p className="text-slate-400 text-sm italic">Sincronizando modelos de IA...</p>
    </div>
  )

  return (
    <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700 pb-20 space-y-8">
      <header className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold text-slate-100 tracking-tight flex items-center gap-3">
             <Bot className="w-8 h-8 text-blue-500" />
             Gestión de Copiloto IA
          </h1>
          <p className="text-slate-400 mt-1">Configura los asistentes y comportamientos de la IA.</p>
        </div>
        <Button onClick={() => handleOpenDialog()} className="bg-blue-600 hover:bg-blue-700 text-white gap-2 shadow-lg shadow-blue-500/20">
          <Plus className="h-5 w-5" />
          Crear Nuevo Prompt
        </Button>
      </header>

      {/* Metrics Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <KpiSummaryCard 
          title="Total Prompts" 
          value={stats?.total || 0} 
          subtext="Configuraciones de IA" 
          icon={Bot} 
          badge="Core" 
          iconColor="text-blue-400" 
        />
        <KpiSummaryCard 
          title="Prompts Activos" 
          value={stats?.active || 0} 
          subtext="Disponibles en el chat" 
          icon={CheckCircle} 
          badge="Live" 
          iconColor="text-emerald-400" 
        />
        <KpiSummaryCard 
          title="Consultas Totales" 
          value={stats?.totalUsage || 0} 
          subtext="Histórico total" 
          icon={MessageSquare} 
          badge="Usage" 
          iconColor="text-indigo-400" 
        />
        <KpiSummaryCard 
          title="Más Usado" 
          value={stats?.mostUsed || "N/A"} 
          subtext="Prompt preferido" 
          icon={Activity} 
          badge="Popular" 
          iconColor="text-amber-400" 
        />
      </div>

      {/* Chart */}
      <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
        <div className="flex items-center gap-2 mb-6">
          <TrendingUp className="w-5 h-5 text-blue-500" />
          <h2 className="text-xl font-bold text-slate-100">Uso de Prompts</h2>
        </div>
        <div className="aspect-[21/9] w-full flex items-center justify-center p-4">
          {stats?.timeSeries && stats.timeSeries.length > 0 ? (
            <TimeSeriesLinesChart data={stats.timeSeries} width={1000} height={350} />
          ) : (
            <span className="text-slate-500 italic">Datos de uso en proceso de carga...</span>
          )}
        </div>
      </section>

      {/* Table */}
      <Card className="border-slate-800 bg-slate-900/40 backdrop-blur-md overflow-hidden rounded-2xl">
        <CardHeader>
          <CardTitle className="text-lg">Asistentes Configurables</CardTitle>
          <CardDescription className="text-slate-400">Administra las instrucciones del sistema para cada asistente.</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader className="bg-slate-800/50">
              <TableRow className="border-slate-800">
                <TableHead className="text-slate-300">Nombre</TableHead>
                <TableHead className="text-slate-300">Categoría</TableHead>
                <TableHead className="text-slate-300">Descripción</TableHead>
                <TableHead className="text-slate-300 text-center">Consultas</TableHead>
                <TableHead className="text-slate-300">Estado</TableHead>
                <TableHead className="text-slate-300 text-right">Acciones</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {prompts.length === 0 ? (
                <TableRow className="border-slate-800">
                  <TableCell colSpan={6} className="text-center py-10 text-slate-500 italic">
                    Sin prompts definidos.
                  </TableCell>
                </TableRow>
              ) : (
                prompts.map((item) => (
                  <TableRow key={item.id} className="border-slate-800 hover:bg-slate-800/30 transition-colors">
                    <TableCell className="font-medium text-slate-200">{item.name}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className="text-[10px] uppercase border-blue-500/30 text-blue-400 bg-blue-500/5">
                        {item.category}
                      </Badge>
                    </TableCell>
                    <TableCell className="max-w-[180px] truncate text-slate-400 text-xs">{item.description}</TableCell>
                    <TableCell className="text-center font-mono text-xs text-slate-300">{item.usage_count || 0}</TableCell>
                    <TableCell>
                      {item.status === 'active' ? (
                        <div className="flex items-center gap-1.5 text-emerald-500 text-xs">
                          <CheckCircle className="h-4 w-4" /> Activo
                        </div>
                      ) : (
                        <div className="flex items-center gap-1.5 text-amber-500 text-xs">
                          <XCircle className="h-4 w-4" /> Inactivo
                        </div>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-2">
                        <Button variant="outline" size="icon" className="h-8 w-8 border-slate-700" onClick={() => handleOpenDialog(item)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                        <Button variant="outline" size="icon" className="h-8 w-8 text-red-400 border-slate-700" onClick={() => handleDelete(item.id)}>
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

      <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
        <DialogContent className="max-w-md bg-slate-900 border-slate-800 text-slate-100">
          <form onSubmit={handleSubmit}>
            <DialogHeader>
              <DialogTitle className="text-xl font-bold">{selectedPrompt ? "Editar Prompt" : "Nuevo Prompt de Sistema"}</DialogTitle>
            </DialogHeader>
            <div className="grid gap-5 py-6">
              <div className="grid gap-2">
                <Label htmlFor="name">Nombre del Asistente</Label>
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
                  placeholder="Ej: Finanzas, Ventas..."
                  value={formData.category}
                  onChange={(e) => setFormData({ ...formData, category: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                  required
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="description">Breve explicación</Label>
                <Textarea
                  id="description"
                  value={formData.description}
                  onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                  className="bg-slate-800 border-slate-700"
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="prompt_text">System Prompt (Instrucciones de la IA)</Label>
                <Textarea
                  id="prompt_text"
                  placeholder="Eres un experto en... tu tono es... responde a..."
                  value={formData.prompt_text}
                  onChange={(e) => setFormData({ ...formData, prompt_text: e.target.value })}
                  className="bg-slate-800 border-slate-700 min-h-[120px]"
                  required
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
              <Button type="submit" className="bg-blue-600 hover:bg-blue-700 w-full text-white">
                {selectedPrompt ? "Guardar Cambios" : "Crear Config IA"}
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
