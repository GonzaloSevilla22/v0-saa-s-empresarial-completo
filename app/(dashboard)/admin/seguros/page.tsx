"use client"

import { useState, useEffect } from "react"
import { insuranceService, Insurance } from "@/lib/services/insuranceService"
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
import { Plus, Edit2, Trash2, Shield, Eye, EyeOff, Loader2, MousePointer2, TrendingUp, ShieldCheck, ShieldAlert } from "lucide-react"
import { toast } from "sonner"
import TimeSeriesLinesChart from "@/components/admin/charts/TimeSeriesLinesChart"

export default function AdminSegurosPage() {
  const [insurances, setInsurances] = useState<Insurance[]>([])
  const [loading, setLoading] = useState(true)
  const [stats, setStats] = useState<any>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [isDeleting, setIsDeleting] = useState(false)
  const [selectedInsurance, setSelectedInsurance] = useState<Partial<Insurance> | null>(null)
  
  const [formData, setFormData] = useState<Partial<Insurance>>({
    title: "",
    description: "",
    coverage: "",
    price: "",
    contact_url: "",
    is_visible: true
  })

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    try {
      setLoading(true)
      const [list, metrics] = await Promise.all([
        insuranceService.getAllInsurances(),
        insuranceService.getAdminStats()
      ])
      setInsurances(list)
      setStats(metrics)
    } catch (error) {
      console.error("Error loading data:", error)
      toast.error("Error al cargar datos de seguros")
    } finally {
      setLoading(false)
    }
  }

  function handleOpenDialog(seguro?: Insurance) {
    if (seguro) {
      setSelectedInsurance(seguro)
      setFormData(seguro)
    } else {
      setSelectedInsurance(null)
      setFormData({
        title: "",
        description: "",
        coverage: "",
        price: "",
        contact_url: "",
        is_visible: true
      })
    }
    setIsDialogOpen(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    try {
      if (selectedInsurance?.id) {
        await insuranceService.updateInsurance(selectedInsurance.id, formData)
        toast.success("Seguro actualizado correctamente")
      } else {
        await insuranceService.createInsurance(formData)
        toast.success("Seguro creado correctamente")
      }
      setIsDialogOpen(false)
      loadData()
    } catch (error) {
      console.error("Error saving insurance:", error)
      toast.error("Error al guardar seguro")
    }
  }

  async function handleDelete(id: string) {
    if (!confirm("¿Estás seguro de que deseas eliminar este seguro?")) return
    try {
      setIsDeleting(true)
      await insuranceService.deleteInsurance(id)
      toast.success("Seguro eliminado")
      loadData()
    } catch (error) {
      console.error("Error deleting insurance:", error)
      toast.error("Error al eliminar seguro")
    } finally {
      setIsDeleting(false)
    }
  }

  async function handleToggleVisibility(id: string, current: boolean) {
    try {
      await insuranceService.toggleInsuranceVisibility(id, current)
      toast.success(current ? "Seguro oculto" : "Seguro visible")
      loadData()
    } catch (error) {
      console.error("Error toggling visibility:", error)
      toast.error("Error al cambiar visibilidad")
    }
  }

  if (loading && !stats) return (
    <div className="flex flex-col items-center justify-center py-32 gap-4">
      <Loader2 className="h-8 w-8 animate-spin text-emerald-500" />
      <p className="text-slate-400 text-sm animate-pulse">Cargando panel de seguros...</p>
    </div>
  )

  return (
    <div className="container mx-auto p-6 max-w-7xl animate-in fade-in duration-700 pb-20 space-y-8">
      <header className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold text-slate-100 tracking-tight flex items-center gap-3">
             <Shield className="w-8 h-8 text-emerald-500" />
             Administración de Seguros
          </h1>
          <p className="text-slate-400 mt-1">Monitorea y gestiona las ofertas de seguros en la plataforma.</p>
        </div>
        <Button onClick={() => handleOpenDialog()} className="bg-emerald-600 hover:bg-emerald-700 text-white gap-2 h-11 px-6 shadow-lg shadow-emerald-500/20">
          <Plus className="h-5 w-5" />
          Crear Seguro
        </Button>
      </header>

      {/* Metrics Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <KpiSummaryCard 
          title="Total Seguros" 
          value={stats?.total || 0} 
          subtext="En el catálogo" 
          icon={Shield} 
          badge="General" 
          iconColor="text-blue-500" 
        />
        <KpiSummaryCard 
          title="Visibles" 
          value={stats?.visible || 0} 
          subtext="En la página pública" 
          icon={ShieldCheck} 
          badge="Activos" 
          iconColor="text-emerald-500" 
        />
        <KpiSummaryCard 
          title="Ocultos" 
          value={stats?.hidden || 0} 
          subtext="No visibles" 
          icon={ShieldAlert} 
          badge="Borradores" 
          iconColor="text-amber-500" 
        />
        <KpiSummaryCard 
          title="Clicks Totales" 
          value={stats?.totalClicks || 0} 
          subtext="Interés de usuarios" 
          icon={MousePointer2} 
          badge="Interacción" 
          iconColor="text-purple-500" 
        />
      </div>

      {/* Chart Section */}
      <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
        <div className="flex items-center gap-2 mb-6">
          <TrendingUp className="w-5 h-5 text-emerald-500" />
          <h2 className="text-xl font-bold text-slate-100">Evolución temporal</h2>
        </div>
        <div className="aspect-[21/9] w-full flex items-center justify-center p-4">
          {stats?.timeSeries && stats.timeSeries.length > 0 ? (
            <TimeSeriesLinesChart data={stats.timeSeries} width={1000} height={350} />
          ) : (
            <span className="text-slate-500">Datos insuficientes para el gráfico (Se requieren datos históricos)</span>
          )}
        </div>
      </section>

      {/* Table Section */}
      <Card className="border-slate-800 bg-slate-900/40 backdrop-blur-md overflow-hidden rounded-2xl">
        <CardHeader>
          <CardTitle className="text-lg">Listado Detallado</CardTitle>
          <CardDescription className="text-slate-400">Gestiona cada entrada del catálogo de seguros.</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader className="bg-slate-800/50">
              <TableRow className="border-slate-800 hover:bg-transparent">
                <TableHead className="text-slate-300">Título</TableHead>
                <TableHead className="text-slate-300">Cobertura</TableHead>
                <TableHead className="text-slate-300">Precio</TableHead>
                <TableHead className="text-slate-300 text-center">Visibilidad</TableHead>
                <TableHead className="text-slate-300">Creado</TableHead>
                <TableHead className="text-slate-300 text-right">Acciones</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {insurances.length === 0 ? (
                <TableRow className="border-slate-800">
                  <TableCell colSpan={6} className="text-center py-10 text-slate-500">
                    No hay seguros registrados. Procede a crear uno nuevo.
                  </TableCell>
                </TableRow>
              ) : (
                insurances.map((item) => (
                  <TableRow key={item.id} className="border-slate-800 hover:bg-slate-800/30 transition-colors">
                    <TableCell className="font-medium text-slate-200">
                      <div className="flex flex-col">
                        <span>{item.title}</span>
                        <span className="text-[10px] text-slate-500 font-normal">{item.id}</span>
                      </div>
                    </TableCell>
                    <TableCell className="max-w-[200px] truncate text-slate-400 text-xs italic">{item.coverage}</TableCell>
                    <TableCell className="text-slate-300 font-semibold">{item.price}</TableCell>
                    <TableCell className="text-center">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleToggleVisibility(item.id, item.is_visible)}
                        className={item.is_visible ? "text-emerald-500 hover:bg-emerald-500/10" : "text-amber-500 hover:bg-amber-500/10"}
                      >
                        {item.is_visible ? (
                          <div className="flex items-center gap-1.5 justify-center w-full">
                            <Eye className="h-4 w-4" />
                            <span className="text-xs">Visible</span>
                          </div>
                        ) : (
                          <div className="flex items-center gap-1.5 justify-center w-full">
                            <EyeOff className="h-4 w-4" />
                            <span className="text-xs">Oculto</span>
                          </div>
                        )}
                      </Button>
                    </TableCell>
                    <TableCell className="text-slate-500 text-xs">
                      {new Date(item.created_at).toLocaleDateString()}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex justify-end gap-2">
                        <Button variant="outline" size="icon" className="h-8 w-8 border-slate-700 bg-slate-800/50 hover:bg-slate-700 text-slate-300" onClick={() => handleOpenDialog(item)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                        <Button variant="outline" size="icon" className="h-8 w-8 text-red-400 hover:text-red-500 hover:bg-red-500/10 border-slate-700 bg-slate-800/50" onClick={() => handleDelete(item.id)}>
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
              <DialogTitle className="text-xl font-bold">{selectedInsurance ? "Editar Seguro" : "Nuevo Seguro"}</DialogTitle>
              <DialogDescription className="text-slate-400">Completa la información técnica del seguro.</DialogDescription>
            </DialogHeader>
            <div className="grid gap-5 py-6">
              <div className="grid gap-2">
                <Label htmlFor="title" className="text-slate-300">Título del Seguro</Label>
                <Input
                  id="title"
                  placeholder="Ej: Seguro contra Incendio"
                  value={formData.title}
                  onChange={(e) => setFormData({ ...formData, title: e.target.value })}
                  className="bg-slate-800 border-slate-700 text-slate-100"
                  required
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="description" className="text-slate-300">Descripción Estratégica</Label>
                <Textarea
                  id="description"
                  placeholder="Describe brevemente el valor para el emprendedor..."
                  value={formData.description}
                  onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                  className="bg-slate-800 border-slate-700 text-slate-100 min-h-[80px]"
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="coverage" className="text-slate-300">Detalle de Cobertura</Label>
                <Textarea
                  id="coverage"
                  placeholder="Qué incluye técnicamente..."
                  value={formData.coverage}
                  onChange={(e) => setFormData({ ...formData, coverage: e.target.value })}
                  className="bg-slate-800 border-slate-700 text-slate-100 min-h-[60px]"
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="price" className="text-slate-300">Pricing / Rango</Label>
                <Input
                  id="price"
                  placeholder="Ej: $1.500 / mes"
                  value={formData.price}
                  onChange={(e) => setFormData({ ...formData, price: e.target.value })}
                  className="bg-slate-800 border-slate-700 text-slate-100"
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="contact_url" className="text-slate-300">URL del Partner (Más info)</Label>
                <Input
                  id="contact_url"
                  placeholder="https://..."
                  value={formData.contact_url}
                  onChange={(e) => setFormData({ ...formData, contact_url: e.target.value })}
                  className="bg-slate-800 border-slate-700 text-slate-100"
                />
              </div>
              <div className="flex items-center justify-between p-3 rounded-lg bg-slate-800/50 border border-slate-700 mt-2">
                <div className="space-y-0.5">
                  <Label htmlFor="is_visible" className="text-sm font-medium cursor-pointer">Visibilidad Pública</Label>
                  <p className="text-[10px] text-slate-500 italic">Determina si aparecerá en la web principal.</p>
                </div>
                <Switch
                  id="is_visible"
                  checked={formData.is_visible}
                  onCheckedChange={(checked) => setFormData({ ...formData, is_visible: checked })}
                />
              </div>
            </div>
            <DialogFooter className="gap-2">
              <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)} className="border-slate-700 text-slate-400 hover:bg-slate-800">Cancelar</Button>
              <Button type="submit" className="bg-emerald-600 hover:bg-emerald-700 text-white min-w-[120px]">
                {selectedInsurance ? "Guardar Cambios" : "Crear Seguro"}
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
