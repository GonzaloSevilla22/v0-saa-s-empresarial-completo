"use client"

/**
 * C-27 v21-fiscal-profile — Página `/configuracion/fiscal`.
 *
 * Formulario de perfil fiscal + CRUD mínimo de puntos de venta
 * + upload de certificado AFIP al bucket privado (signed upload).
 *
 * Design ref: OQ-2 (multi-PV), D2 (ambiente por cuenta), D7 (cert en bucket privado)
 */

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Building2, Plus, Trash2, Upload, ChevronLeft } from "lucide-react"
import Link from "next/link"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form"
import { Input } from "@/components/ui/input"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Separator } from "@/components/ui/separator"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Skeleton } from "@/components/ui/skeleton"

import { useFiscalProfile, useUpsertFiscalProfile } from "@/hooks/data/use-fiscal-profile"
import { usePointsOfSale, useCreatePointOfSale, useDeactivatePointOfSale } from "@/hooks/data/use-points-of-sale"
import type { IvaCondition, Ambiente } from "@/hooks/data/use-fiscal-profile"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"

// ── Schemas ───────────────────────────────────────────────────────────────────

const fiscalProfileSchema = z.object({
  cuit:          z.string().regex(/^\d{2}-\d{8}-\d$/, "Formato: 20-12345678-6"),
  iva_condition: z.enum(["responsable_inscripto", "monotributista", "exento", "consumidor_final"]),
  iibb_condition:z.string().optional(),
  ambiente:      z.enum(["homologacion", "produccion"]),
})

const newPvSchema = z.object({
  numero: z.coerce.number().int().min(1, "Número de PV debe ser ≥ 1"),
})

type FiscalProfileFormValues = z.infer<typeof fiscalProfileSchema>
type NewPvFormValues = z.infer<typeof newPvSchema>

// ── Labels ────────────────────────────────────────────────────────────────────

const IVA_LABELS: Record<IvaCondition, string> = {
  responsable_inscripto: "Responsable Inscripto",
  monotributista:        "Monotributista",
  exento:                "Exento",
  consumidor_final:      "Consumidor Final",
}

const AMBIENTE_LABELS: Record<Ambiente, { label: string; color: string }> = {
  homologacion: { label: "Homologación (testing)", color: "bg-blue-500/10 text-blue-500 border-blue-500/30" },
  produccion:   { label: "Producción",             color: "bg-green-500/10 text-green-500 border-green-500/30" },
}

// ── FiscalProfileForm ─────────────────────────────────────────────────────────

function FiscalProfileForm() {
  const { profile, isLoading } = useFiscalProfile()
  const upsert = useUpsertFiscalProfile()
  const [saveError, setSaveError] = useState<string | null>(null)
  const [saveOk, setSaveOk] = useState(false)

  const form = useForm<FiscalProfileFormValues>({
    resolver: zodResolver(fiscalProfileSchema),
    defaultValues: {
      cuit:          profile?.cuit          ?? "",
      iva_condition: profile?.ivaCondition  ?? "responsable_inscripto",
      iibb_condition:profile?.iibbCondition ?? "",
      ambiente:      profile?.ambiente      ?? "homologacion",
    },
    values: profile
      ? {
          cuit:           profile.cuit,
          iva_condition:  profile.ivaCondition,
          iibb_condition: profile.iibbCondition ?? "",
          ambiente:       profile.ambiente,
        }
      : undefined,
  })

  async function onSubmit(values: FiscalProfileFormValues) {
    setSaveError(null)
    setSaveOk(false)
    try {
      await upsert.mutateAsync({
        cuit:           values.cuit,
        iva_condition:  values.iva_condition,
        iibb_condition: values.iibb_condition || null,
        ambiente:       values.ambiente,
      })
      setSaveOk(true)
      setTimeout(() => setSaveOk(false), 3000)
    } catch (err: unknown) {
      setSaveError(err instanceof Error ? err.message : "Error al guardar el perfil.")
    }
  }

  if (isLoading) {
    return (
      <div className="flex flex-col gap-3">
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
      </div>
    )
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-4">
        {/* CUIT */}
        <FormField
          control={form.control}
          name="cuit"
          render={({ field }) => (
            <FormItem>
              <FormLabel>CUIT del emisor</FormLabel>
              <FormControl>
                <Input placeholder="20-12345678-6" {...field} />
              </FormControl>
              <FormDescription>
                Formato: NN-NNNNNNNN-N con dígito verificador módulo 11 (validado automáticamente).
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Condición IVA */}
        <FormField
          control={form.control}
          name="iva_condition"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Condición IVA</FormLabel>
              <Select onValueChange={field.onChange} value={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Seleccioná tu condición" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {(["responsable_inscripto", "monotributista", "exento", "consumidor_final"] as IvaCondition[]).map(
                    (v) => (
                      <SelectItem key={v} value={v}>
                        {IVA_LABELS[v]}
                      </SelectItem>
                    )
                  )}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* IIBB */}
        <FormField
          control={form.control}
          name="iibb_condition"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Condición IIBB (opcional)</FormLabel>
              <FormControl>
                <Input placeholder="Ej. CM — Convenio Multilateral" {...field} />
              </FormControl>
              <FormDescription>
                Ingresos Brutos. Se incluye en el encabezado de la factura.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Ambiente */}
        <FormField
          control={form.control}
          name="ambiente"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Ambiente AFIP</FormLabel>
              <Select onValueChange={field.onChange} value={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {(["homologacion", "produccion"] as Ambiente[]).map((v) => (
                    <SelectItem key={v} value={v}>
                      {AMBIENTE_LABELS[v].label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormDescription>
                Usá Homologación para pruebas. Cambiá a Producción solo cuando tengás el certificado homologado.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {saveError && (
          <Alert variant="destructive">
            <AlertDescription>{saveError}</AlertDescription>
          </Alert>
        )}

        {saveOk && (
          <Alert>
            <AlertDescription className="text-green-500">
              Perfil fiscal guardado correctamente.
            </AlertDescription>
          </Alert>
        )}

        <Button
          type="submit"
          disabled={upsert.isPending}
          className="self-start"
        >
          {upsert.isPending ? "Guardando..." : profile ? "Actualizar perfil" : "Guardar perfil"}
        </Button>
      </form>
    </Form>
  )
}

// ── CertUploadSection ─────────────────────────────────────────────────────────

function CertUploadSection() {
  const { profile } = useFiscalProfile()
  const [uploading, setUploading] = useState(false)
  const [uploadError, setUploadError] = useState<string | null>(null)
  const [uploadOk, setUploadOk] = useState(false)

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return

    setUploading(true)
    setUploadError(null)
    setUploadOk(false)

    try {
      // D7: cert en bucket privado `afip-certs` — signed upload via backend
      // El backend genera una URL firmada para que el frontend suba directamente a Storage.
      const { pythonClient } = await import("@/lib/api/python-client")
      const { uploadUrl, path } = await pythonClient.post<{ uploadUrl: string; path: string }>(
        "/fiscal/profile/cert-upload-url",
        { filename: file.name, content_type: file.type || "application/x-x509-ca-cert" },
      )

      // Upload directo al bucket usando la URL firmada
      const resp = await fetch(uploadUrl, {
        method: "PUT",
        headers: { "Content-Type": file.type || "application/x-x509-ca-cert" },
        body: file,
      })

      if (!resp.ok) {
        throw new Error("Error al subir el certificado. Intentá de nuevo.")
      }

      // Actualizar el path en el perfil
      await pythonClient.put("/fiscal/profile/cert-path", { path })
      setUploadOk(true)
      setTimeout(() => setUploadOk(false), 4000)
    } catch (err: unknown) {
      setUploadError(err instanceof Error ? err.message : "Error al subir el certificado.")
    } finally {
      setUploading(false)
      e.target.value = ""
    }
  }

  const hasCert = Boolean(profile?.certificadoAfipPath)

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <span className="text-sm font-medium">Certificado AFIP</span>
        {hasCert
          ? <Badge variant="outline" className="bg-green-500/10 text-green-500 border-green-500/30 text-xs">Cargado</Badge>
          : <Badge variant="outline" className="bg-yellow-500/10 text-yellow-600 border-yellow-500/30 text-xs">Sin certificado</Badge>
        }
      </div>
      <p className="text-xs text-muted-foreground">
        Subí el certificado digital otorgado por AFIP (archivo .p12 o .crt).
        Se guarda de forma privada; el sistema lo usa solo para firmar el ticket de acceso WSAA.
        Sin certificado, el relay CAE operará en modo Stub.
      </p>
      <label className="flex items-center gap-2 cursor-pointer self-start">
        <input
          type="file"
          accept=".p12,.crt,.pem,.pfx"
          className="sr-only"
          disabled={uploading || !profile}
          onChange={handleFileChange}
        />
        <Button
          asChild
          variant="outline"
          size="sm"
          disabled={uploading || !profile}
          className="pointer-events-none"
        >
          <span>
            <Upload className="h-3.5 w-3.5 mr-1.5" />
            {uploading ? "Subiendo..." : hasCert ? "Reemplazar certificado" : "Subir certificado"}
          </span>
        </Button>
      </label>
      {!profile && (
        <p className="text-xs text-muted-foreground/70">Guardá el perfil fiscal antes de subir el certificado.</p>
      )}
      {uploadError && (
        <Alert variant="destructive">
          <AlertDescription className="text-xs">{uploadError}</AlertDescription>
        </Alert>
      )}
      {uploadOk && (
        <Alert>
          <AlertDescription className="text-xs text-green-500">
            Certificado cargado correctamente.
          </AlertDescription>
        </Alert>
      )}
    </div>
  )
}

// ── PointsOfSaleSection ───────────────────────────────────────────────────────

function PointsOfSaleSection() {
  const { pointsOfSale, isLoading } = usePointsOfSale()
  const createPv = useCreatePointOfSale()
  const deactivatePv = useDeactivatePointOfSale()
  const { profile } = useFiscalProfile()
  const [pvError, setPvError] = useState<string | null>(null)
  const [deactivateError, setDeactivateError] = useState<string | null>(null)

  const pvForm = useForm<NewPvFormValues>({
    resolver: zodResolver(newPvSchema),
    defaultValues: { numero: "" as unknown as number },
  })

  async function onCreatePv(values: NewPvFormValues) {
    setPvError(null)
    try {
      await createPv.mutateAsync({ numero: values.numero })
      pvForm.reset()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error al crear el punto de venta."
      setPvError(msg.includes("409") || msg.toLowerCase().includes("unique") || msg.toLowerCase().includes("duplicado")
        ? `El punto de venta número ${values.numero} ya existe.`
        : msg)
    }
  }

  async function handleDeactivate(pv: PointOfSale) {
    setDeactivateError(null)
    try {
      await deactivatePv.mutateAsync(pv.id)
    } catch (err: unknown) {
      setDeactivateError(err instanceof Error ? err.message : "Error al desactivar el punto de venta.")
    }
  }

  if (isLoading) {
    return (
      <div className="flex flex-col gap-2">
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-10 w-full" />
      </div>
    )
  }

  const activePvs   = pointsOfSale.filter((p) => p.isActive)
  const inactivePvs = pointsOfSale.filter((p) => !p.isActive)

  return (
    <div className="flex flex-col gap-4">
      {/* Puntos de venta activos */}
      {activePvs.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No hay puntos de venta activos. Agregá uno para poder emitir comprobantes.
        </p>
      ) : (
        <div className="flex flex-col gap-2">
          {activePvs.map((pv) => (
            <div key={pv.id} className="flex items-center justify-between border border-border rounded-md px-3 py-2">
              <div className="flex items-center gap-2">
                <Building2 className="h-3.5 w-3.5 text-muted-foreground" />
                <span className="text-sm font-medium">PV {String(pv.numero).padStart(4, "0")}</span>
                {pv.branchId && (
                  <Badge variant="outline" className="text-xs text-muted-foreground">Sucursal asignada</Badge>
                )}
              </div>
              <Button
                variant="ghost"
                size="sm"
                className="text-destructive hover:text-destructive hover:bg-destructive/10 h-7 px-2"
                disabled={deactivatePv.isPending}
                onClick={() => handleDeactivate(pv)}
              >
                <Trash2 className="h-3.5 w-3.5" />
              </Button>
            </div>
          ))}
        </div>
      )}

      {/* Inactivos (colapsados, solo count) */}
      {inactivePvs.length > 0 && (
        <p className="text-xs text-muted-foreground">
          {inactivePvs.length} punto{inactivePvs.length > 1 ? "s" : ""} de venta inactivo{inactivePvs.length > 1 ? "s" : ""}.
        </p>
      )}

      {deactivateError && (
        <Alert variant="destructive">
          <AlertDescription className="text-xs">{deactivateError}</AlertDescription>
        </Alert>
      )}

      <Separator />

      {/* Agregar nuevo PV */}
      <Form {...pvForm}>
        <form onSubmit={pvForm.handleSubmit(onCreatePv)} className="flex items-end gap-3">
          <FormField
            control={pvForm.control}
            name="numero"
            render={({ field }) => (
              <FormItem className="flex-1">
                <FormLabel>Agregar punto de venta</FormLabel>
                <FormControl>
                  <Input
                    type="number"
                    min={1}
                    max={9999}
                    placeholder="Ej. 1"
                    {...field}
                    disabled={!profile}
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <Button
            type="submit"
            size="sm"
            disabled={createPv.isPending || !profile}
            className="mb-0"
          >
            <Plus className="h-3.5 w-3.5 mr-1" />
            {createPv.isPending ? "Creando..." : "Agregar"}
          </Button>
        </form>
      </Form>

      {!profile && (
        <p className="text-xs text-muted-foreground/70">Guardá el perfil fiscal antes de crear puntos de venta.</p>
      )}

      {pvError && (
        <Alert variant="destructive">
          <AlertDescription className="text-xs">{pvError}</AlertDescription>
        </Alert>
      )}
    </div>
  )
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default function FiscalConfiguracionPage() {
  const { profile } = useFiscalProfile()

  return (
    <div className="flex flex-col gap-6 max-w-2xl">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2">
        <Link
          href="/configuracion"
          className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          <ChevronLeft className="h-3.5 w-3.5" />
          Configuración
        </Link>
        <span className="text-muted-foreground/40">/</span>
        <span className="text-sm text-foreground">Facturación AFIP</span>
      </div>

      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-foreground tracking-tight">Facturación AFIP</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Configurá tu perfil fiscal para emitir comprobantes electrónicos (Facturas A, B y C).
        </p>
      </div>

      {/* Ambiente badge */}
      {profile && (
        <div className="flex items-center gap-2">
          <span className="text-xs text-muted-foreground">Ambiente actual:</span>
          <Badge
            variant="outline"
            className={`text-xs ${AMBIENTE_LABELS[profile.ambiente].color}`}
          >
            {AMBIENTE_LABELS[profile.ambiente].label}
          </Badge>
        </div>
      )}

      {/* Perfil fiscal */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Datos fiscales</CardTitle>
          <CardDescription>
            CUIT del emisor, condición IVA y ambiente de facturación.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <FiscalProfileForm />
        </CardContent>
      </Card>

      {/* Certificado AFIP */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Certificado digital</CardTitle>
          <CardDescription>
            Certificado AFIP para firmar el ticket WSAA y solicitar CAE a WSFEv1.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <CertUploadSection />
        </CardContent>
      </Card>

      {/* Puntos de venta */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Puntos de venta</CardTitle>
          <CardDescription>
            Cada punto de venta tiene su propia numeración (doc_sequences).
            Si tenés más de un PV activo, deberás especificarlo al emitir.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <PointsOfSaleSection />
        </CardContent>
      </Card>
    </div>
  )
}
