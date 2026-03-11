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
  DialogTrigger,
} from "@/components/ui/dialog"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Switch } from "@/components/ui/switch"
import { Label } from "@/components/ui/label"
import { Plus, Edit2, Trash2, Shield, Eye, EyeOff, Loader2 } from "lucide-react"
import { toast } from "sonner"

export default function AdminSegurosPage() {
  const [insurances, setInsurances] = useState<Insurance[]>([])
  const [loading, setLoading] = useState(true)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [isDeleting, setIsDeleting] = useState(false)
  const [selectedInsurance, setSelectedInsurance] = useState<Partial<Insurance> | null>(null)
  
  // Form State
  const [formData, setFormData] = useState<Partial<Insurance>>({
    title: "",
    description: "",
    coverage: "",
    price: "",
    contact_url: "",
    is_visible: true
  })

  useEffect(() => {
    loadInsurances()
  }, [])

  async function loadInsurances() {
    try {
      setLoading(true)
      const data = await insuranceService.getAllInsurances()
      setInsurances(data)
    } catch (error) {
      console.error("Error loading insurances:", error)
      toast.error("Error al cargar seguros")
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
      loadInsurances()
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
      loadInsurances()
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
      loadInsurances()
    } catch (error) {
      console.error("Error toggling visibility:", error)
      toast.error("Error al cambiar visibilidad")
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Gestionar Seguros</h1>
          <p className="text-sm text-muted-foreground mt-1">Administra las opciones de seguros para los emprendedores.</p>
        </div>
        <Button onClick={() => handleOpenDialog()} className="bg-emerald-600 hover:bg-emerald-700 text-white gap-2">
          <Plus className="h-4 w-4" />
          Nuevo Seguro
        </Button>
      </div>

      <Card className="border-border">
        <CardHeader className="pb-0">
          <CardTitle className="text-lg">Listado de Seguros</CardTitle>
          <CardDescription>Visualiza y edita los seguros disponibles en la plataforma.</CardDescription>
        </CardHeader>
        <CardContent className="pt-6">
          {loading ? (
            <div className="flex justify-center py-8">
              <Loader2 className="h-8 w-8 animate-spin text-emerald-500" />
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Título</TableHead>
                  <TableHead>Cobertura</TableHead>
                  <TableHead>Precio</TableHead>
                  <TableHead className="text-center">Visibilidad</TableHead>
                  <TableHead className="text-right">Acciones</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {insurances.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={5} className="text-center py-10 text-muted-foreground">
                      No hay seguros registrados.
                    </TableCell>
                  </TableRow>
                ) : (
                  insurances.map((item) => (
                    <TableRow key={item.id}>
                      <TableCell className="font-medium">{item.title}</TableCell>
                      <TableCell className="max-w-[200px] truncate">{item.coverage}</TableCell>
                      <TableCell>{item.price}</TableCell>
                      <TableCell className="text-center">
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => handleToggleVisibility(item.id, item.is_visible)}
                          className={item.is_visible ? "text-emerald-500" : "text-amber-500"}
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
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-2">
                          <Button variant="outline" size="icon" className="h-8 w-8 border-border" onClick={() => handleOpenDialog(item)}>
                            <Edit2 className="h-3.5 w-3.5" />
                          </Button>
                          <Button variant="outline" size="icon" className="h-8 w-8 text-red-500 hover:text-red-600 hover:bg-red-50 border-border" onClick={() => handleDelete(item.id)}>
                            <Trash2 className="h-3.5 w-3.5" />
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
        <DialogContent className="max-w-md">
          <form onSubmit={handleSubmit}>
            <DialogHeader>
              <DialogTitle>{selectedInsurance ? "Editar Seguro" : "Nuevo Seguro"}</DialogTitle>
              <DialogDescription>Completa la información del seguro para los emprendedores.</DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              <div className="grid gap-2">
                <Label htmlFor="title">Título del Seguro</Label>
                <Input
                  id="title"
                  placeholder="Ej: Seguro contra Incendio"
                  value={formData.title}
                  onChange={(e) => setFormData({ ...formData, title: e.target.value })}
                  required
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="description">Descripción Corta</Label>
                <Textarea
                  id="description"
                  placeholder="Describe brevemente de qué trata el seguro..."
                  value={formData.description}
                  onChange={(e) => setFormData({ ...formData, description: e.target.value })}
                  rows={2}
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="coverage">Detalle de Cobertura</Label>
                <Textarea
                  id="coverage"
                  placeholder="Qué incluye este seguro..."
                  value={formData.coverage}
                  onChange={(e) => setFormData({ ...formData, coverage: e.target.value })}
                  rows={2}
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="price">Precio Estimado / Rango</Label>
                <Input
                  id="price"
                  placeholder="Ej: Desde $1.500 / mes"
                  value={formData.price}
                  onChange={(e) => setFormData({ ...formData, price: e.target.value })}
                />
              </div>
              <div className="grid gap-2">
                <Label htmlFor="contact_url">Link de Contacto / Más info</Label>
                <Input
                  id="contact_url"
                  placeholder="https://..."
                  value={formData.contact_url}
                  onChange={(e) => setFormData({ ...formData, contact_url: e.target.value })}
                />
              </div>
              <div className="flex items-center space-x-2 pt-2">
                <Switch
                  id="is_visible"
                  checked={formData.is_visible}
                  onCheckedChange={(checked) => setFormData({ ...formData, is_visible: checked })}
                />
                <Label htmlFor="is_visible" className="cursor-pointer font-normal">Hacer visible en la lista pública</Label>
              </div>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)}>Cancelar</Button>
              <Button type="submit" className="bg-emerald-600 hover:bg-emerald-700 text-white">
                {selectedInsurance ? "Guardar Cambios" : "Crear Seguro"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  )
}
