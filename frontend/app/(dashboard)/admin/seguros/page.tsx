"use client"

import { useState, useEffect } from "react"
import {
  insuranceService,
  Insurance,
  AdminStats,
  CONTACT_CHANNELS,
  serviceLinesSchema,
  pillarsSchema,
} from "@/lib/services/insuranceService"
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  Plus, Edit2, Trash2, Shield, Eye, EyeOff, Loader2, MousePointer2, TrendingUp,
  ShieldCheck, ShieldAlert, UserRound, MessageCircle, Mail, Phone, Globe,
} from "lucide-react"
import { toast } from "sonner"
import TimeSeriesLinesChart from "@/components/admin/charts/TimeSeriesLinesChart"
import { AdvisorListEditor } from "@/components/seguros/AdvisorListEditor"
import { CoverageAreaEditor } from "@/components/seguros/CoverageAreaEditor"

const EMPTY_FORM: Partial<Insurance> = {
  title: "",
  description: "",
  coverage: "",
  price: "",
  contact_url: "",
  is_visible: true,
  entry_type: "offer",
  slug: "",
  advisor_name: "",
  advisor_role: "",
  license_number: "",
  license_authority: "",
  headline: "",
  bio: "",
  photo_url: "",
  contact_phone: "",
  contact_whatsapp: "",
  contact_email: "",
  service_lines: [],
  pillars: [],
  coverage_areas: [],
  disclaimer: "",
  is_featured: false,
  sort_order: 0,
}

const CHANNEL_LABELS: Record<(typeof CONTACT_CHANNELS)[number], { label: string; Icon: typeof MessageCircle }> = {
  whatsapp: { label: "WhatsApp", Icon: MessageCircle },
  email: { label: "Email", Icon: Mail },
  phone: { label: "Teléfono", Icon: Phone },
  web: { label: "Web", Icon: Globe },
}

/** Traduce el error crudo de guardar una entrada a un mensaje accionable. Nunca deja pasar el texto de Postgres tal cual (task 7.6). */
function friendlySaveError(error: unknown): string {
  const code = (error as { code?: string } | null)?.code
  const message = (error as { message?: string } | null)?.message ?? ""
  if (code === "23505" || /duplicate key|unique constraint/i.test(message)) {
    return "Ese slug ya está en uso por otro asesor. Elegí uno distinto."
  }
  return "Error al guardar seguro"
}

export default function AdminSegurosPage() {
  const [insurances, setInsurances] = useState<Insurance[]>([])
  const [loading, setLoading] = useState(true)
  const [stats, setStats] = useState<AdminStats | null>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [isDeleting, setIsDeleting] = useState(false)
  const [selectedInsurance, setSelectedInsurance] = useState<Partial<Insurance> | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<Insurance | null>(null)

  const [formData, setFormData] = useState<Partial<Insurance>>(EMPTY_FORM)

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
      setFormData({ ...EMPTY_FORM, ...seguro })
    } else {
      setSelectedInsurance(null)
      setFormData(EMPTY_FORM)
    }
    setIsDialogOpen(true)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()

    if (formData.entry_type === "advisor") {
      if (!formData.slug?.trim()) {
        toast.error("El slug es obligatorio para publicar el perfil de un asesor.")
        return
      }
      if (!serviceLinesSchema.safeParse(formData.service_lines ?? []).success) {
        toast.error("Revisá las líneas de servicio: cada una necesita título y descripción.")
        return
      }
      if (!pillarsSchema.safeParse(formData.pillars ?? []).success) {
        toast.error("Revisá los pilares: cada uno necesita título y contenido.")
        return
      }
    }

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
      toast.error(friendlySaveError(error))
    }
  }

  async function handleDelete() {
    if (!deleteTarget) return
    try {
      setIsDeleting(true)
      await insuranceService.deleteInsurance(deleteTarget.id)
      toast.success("Seguro eliminado")
      setDeleteTarget(null)
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

  const isAdvisorForm = formData.entry_type === "advisor"

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
          <p className="text-slate-400 mt-1">Monitorea y gestiona las ofertas y los perfiles de asesores en la plataforma.</p>
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
          value={stats?.total ?? 0}
          subtext="En el catálogo"
          icon={Shield}
          badge="General"
          iconColor="text-blue-500"
        />
        <KpiSummaryCard
          title="Visibles"
          value={stats?.visible ?? 0}
          subtext="En la página pública"
          icon={ShieldCheck}
          badge="Activos"
          iconColor="text-emerald-500"
        />
        <KpiSummaryCard
          title="Ocultos"
          value={stats?.hidden ?? 0}
          subtext="No visibles"
          icon={ShieldAlert}
          badge="Borradores"
          iconColor="text-amber-500"
        />
        <KpiSummaryCard
          title="Clicks Totales"
          value={stats?.totalClicks ?? 0}
          subtext="Interés de usuarios"
          icon={MousePointer2}
          badge="Interacción"
          iconColor="text-purple-500"
        />
      </div>

      {/* Desglose de clicks por vía de contacto (task 7.5) */}
      <section
        data-testid="contact-clicks-breakdown"
        className="grid grid-cols-2 md:grid-cols-4 gap-4 bg-slate-900/40 backdrop-blur-md p-6 rounded-2xl shadow-xl border border-slate-800"
      >
        {CONTACT_CHANNELS.map((channel) => {
          const { label, Icon } = CHANNEL_LABELS[channel]
          return (
            <div key={channel} className="flex items-center gap-2">
              <Icon className="h-4 w-4 text-slate-400 shrink-0" />
              <div>
                <p className="text-lg font-bold text-slate-100">{stats?.channelClicks?.[channel] ?? 0}</p>
                <p className="text-[10px] uppercase tracking-wide text-slate-500">{label}</p>
              </div>
            </div>
          )
        })}
      </section>

      {/* Chart Section */}
      <section className="bg-slate-900/40 backdrop-blur-md p-8 rounded-2xl shadow-xl border border-slate-800">
        <div className="flex items-center gap-2 mb-6">
          <TrendingUp className="w-5 h-5 text-emerald-500" />
          <h2 className="text-xl font-bold text-slate-100">Evolución temporal</h2>
        </div>
        <div className="aspect-[21/9] w-full flex items-center justify-center p-4">
          {stats?.timeSeries && stats.timeSeries.length > 0 ? (
            // Pre-existente (no lo introduce este change): TimeSeriesLinesChart
            // espera { period: string parseable como Date; activations;
            // umv_achieved }, pero processTimeSeries produce { name: "Ene".."Dic";
            // value } — antes quedaba invisible porque `stats` era `any`. El
            // adapter de abajo sólo hace compilar el tipo correcto que agregamos
            // acá (task 7.7); no corrige el desajuste real del chart (fuera de
            // alcance de seguros-perfil-asesor).
            <TimeSeriesLinesChart
              data={stats.timeSeries.map((point) => ({
                period: point.name,
                activations: point.value,
                umv_achieved: 0,
              }))}
              width={1000}
              height={350}
            />
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
                <TableHead className="text-slate-300">Tipo</TableHead>
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
                  <TableCell colSpan={7} className="text-center py-10 text-slate-500">
                    No hay seguros registrados. Procede a crear uno nuevo.
                  </TableCell>
                </TableRow>
              ) : (
                insurances.map((item) => (
                  <TableRow key={item.id} className="border-slate-800 hover:bg-slate-800/30 transition-colors">
                    <TableCell>
                      {item.entry_type === "advisor" ? (
                        <span className="inline-flex items-center gap-1 text-[10px] font-medium text-emerald-400">
                          <UserRound className="h-3 w-3" /> Asesor
                        </span>
                      ) : (
                        <span className="inline-flex items-center gap-1 text-[10px] font-medium text-slate-400">
                          <Shield className="h-3 w-3" /> Oferta
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="font-medium text-slate-200">
                      <div className="flex flex-col">
                        <span>{item.title}</span>
                        <span className="text-[10px] text-slate-500 font-normal">{item.id}</span>
                      </div>
                    </TableCell>
                    <TableCell className="max-w-[200px] truncate text-slate-400 text-xs italic">{item.coverage || "—"}</TableCell>
                    <TableCell className="text-slate-300 font-semibold">{item.price || "—"}</TableCell>
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
                        <Button variant="outline" size="icon" aria-label="Editar" className="h-8 w-8 border-slate-700 bg-slate-800/50 hover:bg-slate-700 text-slate-300" onClick={() => handleOpenDialog(item)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                        <Button variant="outline" size="icon" aria-label="Eliminar" className="h-8 w-8 text-red-400 hover:text-red-500 hover:bg-red-500/10 border-slate-700 bg-slate-800/50" onClick={() => setDeleteTarget(item)}>
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
            <AlertDialogTitle>¿Eliminar seguro?</AlertDialogTitle>
            <AlertDialogDescription className="text-slate-400">
              Estás a punto de eliminar <strong className="text-slate-200">"{deleteTarget?.title}"</strong>. Esta acción no se puede deshacer.
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
        <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto bg-slate-900 border-slate-800 text-slate-100">
          <form onSubmit={handleSubmit}>
            <DialogHeader>
              <DialogTitle className="text-xl font-bold">{selectedInsurance ? "Editar Seguro" : "Nuevo Seguro"}</DialogTitle>
              <DialogDescription className="text-slate-400">Completa la información del seguro o del perfil de asesor.</DialogDescription>
            </DialogHeader>
            <div className="grid gap-5 py-6">
              <div className="grid gap-2">
                <Label htmlFor="entry_type" className="text-slate-300">Tipo de entrada</Label>
                <Select
                  value={formData.entry_type ?? "offer"}
                  onValueChange={(value) => setFormData({ ...formData, entry_type: value as Insurance["entry_type"] })}
                >
                  <SelectTrigger id="entry_type" aria-label="Tipo de entrada" className="bg-slate-800 border-slate-700 text-slate-100">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="offer">Oferta</SelectItem>
                    <SelectItem value="advisor">Asesor</SelectItem>
                  </SelectContent>
                </Select>
              </div>

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

              {!isAdvisorForm ? (
                <>
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
                </>
              ) : (
                <>
                  <div className="grid grid-cols-2 gap-4">
                    <div className="grid gap-2">
                      <Label htmlFor="advisor_name" className="text-slate-300">Nombre del asesor</Label>
                      <Input
                        id="advisor_name"
                        value={formData.advisor_name ?? ""}
                        onChange={(e) => setFormData({ ...formData, advisor_name: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="advisor_role" className="text-slate-300">Rol</Label>
                      <Input
                        id="advisor_role"
                        placeholder="Ej: Productor Asesor de Seguros"
                        value={formData.advisor_role ?? ""}
                        onChange={(e) => setFormData({ ...formData, advisor_role: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                  </div>

                  <div className="grid grid-cols-2 gap-4">
                    <div className="grid gap-2">
                      <Label htmlFor="slug" className="text-slate-300">Slug</Label>
                      <Input
                        id="slug"
                        placeholder="julian-dupas"
                        value={formData.slug ?? ""}
                        onChange={(e) => setFormData({ ...formData, slug: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                      <p className="text-[10px] text-slate-500">Es la URL pública del perfil (/seguros/{formData.slug || "…"}). Es estable: evitá renombrarlo una vez publicado.</p>
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="license_number" className="text-slate-300">Matrícula</Label>
                      <Input
                        id="license_number"
                        placeholder="98506"
                        value={formData.license_number ?? ""}
                        onChange={(e) => setFormData({ ...formData, license_number: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="license_authority" className="text-slate-300">Leyenda del organismo (opcional)</Label>
                    <Input
                      id="license_authority"
                      placeholder="Ej: SSN"
                      value={formData.license_authority ?? ""}
                      onChange={(e) => setFormData({ ...formData, license_authority: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100"
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="headline" className="text-slate-300">Frase ancla</Label>
                    <Input
                      id="headline"
                      value={formData.headline ?? ""}
                      onChange={(e) => setFormData({ ...formData, headline: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100"
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="bio" className="text-slate-300">Presentación</Label>
                    <Textarea
                      id="bio"
                      value={formData.bio ?? ""}
                      onChange={(e) => setFormData({ ...formData, bio: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100 min-h-[100px]"
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="photo_url" className="text-slate-300">Foto (URL, opcional)</Label>
                    <Input
                      id="photo_url"
                      placeholder="/julian-dupas.jpg"
                      value={formData.photo_url ?? ""}
                      onChange={(e) => setFormData({ ...formData, photo_url: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100"
                    />
                    <p className="text-[10px] text-slate-500">Sin foto, el perfil muestra las iniciales del nombre.</p>
                  </div>

                  <div className="grid grid-cols-3 gap-4">
                    <div className="grid gap-2">
                      <Label htmlFor="contact_whatsapp" className="text-slate-300">WhatsApp</Label>
                      <Input
                        id="contact_whatsapp"
                        placeholder="5492266474348"
                        value={formData.contact_whatsapp ?? ""}
                        onChange={(e) => setFormData({ ...formData, contact_whatsapp: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="contact_email" className="text-slate-300">Email</Label>
                      <Input
                        id="contact_email"
                        type="email"
                        value={formData.contact_email ?? ""}
                        onChange={(e) => setFormData({ ...formData, contact_email: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="contact_phone" className="text-slate-300">Teléfono</Label>
                      <Input
                        id="contact_phone"
                        value={formData.contact_phone ?? ""}
                        onChange={(e) => setFormData({ ...formData, contact_phone: e.target.value })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="contact_url" className="text-slate-300">Sitio web</Label>
                    <Input
                      id="contact_url"
                      placeholder="https://..."
                      value={formData.contact_url ?? ""}
                      onChange={(e) => setFormData({ ...formData, contact_url: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100"
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label className="text-slate-300">Líneas de servicio</Label>
                    <AdvisorListEditor
                      label="línea de servicio"
                      textFieldLabel="Descripción"
                      titlePlaceholder="Ej: Autos y motos"
                      textPlaceholder="Bajada de la línea de servicio..."
                      items={(formData.service_lines ?? []).map((l) => ({ title: l.title, text: l.description }))}
                      onChange={(items) =>
                        setFormData({
                          ...formData,
                          service_lines: items.map((i) => ({ title: i.title, description: i.text })),
                        })
                      }
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label className="text-slate-300">Pilares de asesoramiento</Label>
                    <AdvisorListEditor
                      label="pilar"
                      textFieldLabel="Contenido"
                      titlePlaceholder="Ej: Transparencia y asesoramiento"
                      textPlaceholder="Desarrollo del pilar..."
                      items={(formData.pillars ?? []).map((p) => ({ title: p.title, text: p.body }))}
                      onChange={(items) =>
                        setFormData({
                          ...formData,
                          pillars: items.map((i) => ({ title: i.title, body: i.text })),
                        })
                      }
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label className="text-slate-300">Zonas de cobertura</Label>
                    <CoverageAreaEditor
                      areas={formData.coverage_areas ?? []}
                      onChange={(areas) => setFormData({ ...formData, coverage_areas: areas })}
                    />
                  </div>

                  <div className="grid gap-2">
                    <Label htmlFor="disclaimer" className="text-slate-300">Deslinde de Aliadata</Label>
                    <Textarea
                      id="disclaimer"
                      value={formData.disclaimer ?? ""}
                      onChange={(e) => setFormData({ ...formData, disclaimer: e.target.value })}
                      className="bg-slate-800 border-slate-700 text-slate-100 min-h-[60px]"
                    />
                  </div>

                  <div className="grid grid-cols-2 gap-4">
                    <div className="flex items-center justify-between p-3 rounded-lg bg-slate-800/50 border border-slate-700">
                      <Label htmlFor="is_featured" className="text-sm font-medium cursor-pointer">Destacado</Label>
                      <Switch
                        id="is_featured"
                        checked={formData.is_featured ?? false}
                        onCheckedChange={(checked) => setFormData({ ...formData, is_featured: checked })}
                      />
                    </div>
                    <div className="grid gap-2">
                      <Label htmlFor="sort_order" className="text-slate-300">Orden</Label>
                      <Input
                        id="sort_order"
                        type="number"
                        value={formData.sort_order ?? 0}
                        onChange={(e) => setFormData({ ...formData, sort_order: Number(e.target.value) })}
                        className="bg-slate-800 border-slate-700 text-slate-100"
                      />
                    </div>
                  </div>
                </>
              )}

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

interface KpiSummaryCardProps {
  title: string
  value: number
  subtext: string
  icon: typeof Shield
  badge: string
  iconColor?: string
}

function KpiSummaryCard({ title, value, subtext, icon: Icon, badge, iconColor = "text-emerald-500" }: KpiSummaryCardProps) {
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
