"use client"

/**
 * documentos-marca-empresa (D10, task 11.3) — pestaña «Documentos» de /configuracion.
 *
 * La marca de la CUENTA para sus papeles (comprobante de venta, presupuestos y remitos):
 * logo, datos de la empresa y paleta, con una vista previa en vivo de lo que se está
 * editando. Tres reglas de fondo:
 *
 *  - Lo que ya manda el perfil fiscal (razón social, CUIT, domicilio, condición de IVA) se
 *    MUESTRA como tal, de sólo lectura y con el enlace para cambiarlo en «Datos fiscales»:
 *    así nunca hay dos lugares para editar el mismo dato.
 *  - El color personalizado avisa EN VIVO si no se lee sobre blanco (>= 4,5:1) y bloquea
 *    «Guardar»; la vista previa lo dibuja como lo dibujaría el servidor (si no se lee, Neutro).
 *  - Sólo owner/admin editan (`CAN_CONFIGURE`, igual que el backend); el resto lo ve todo.
 *
 * La validación es un `safeParse` SÍNCRONO del mismo esquema que usa el resolver, así el
 * estado de «Guardar» nunca depende de que termine una validación asíncrona.
 */

import { useId, useMemo, useState } from "react"
import Link from "next/link"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { toast } from "sonner"
import { Check, Loader2, Save, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group"
import { DocumentHeaderPreview } from "@/components/settings/DocumentHeaderPreview"
import { DocumentLogoUpload } from "@/components/settings/DocumentLogoUpload"
import {
  useDocumentBranding,
  useDocumentLogoDataUri,
  useUpdateDocumentBranding,
} from "@/hooks/data/use-document-branding"
import { useOrgRole } from "@/hooks/useOrgRole"
import { PythonApiError } from "@/lib/api/python-api-error"
import { contrastRatio, hexToRgb, MIN_ACCENT_CONTRAST, WHITE } from "@/lib/color-contrast"
import { IVA_CONDITION_OPTIONS } from "@/lib/constants"
import {
  documentBrandingFormSchema,
  formFromSettings,
  formatContrast,
  formToPayload,
  isSafeHexColor,
  ISSUER_IVA_LEGEND,
  NEUTRAL_PALETTE,
  paletteForPreview,
  previewIssuer,
  type BrandingForm,
  type DocumentBranding,
  type FiscalData,
  type PaletteChoice,
  type PaletteKey,
} from "@/lib/document-branding"
import { CAN_CONFIGURE, hasCapability } from "@/lib/rbac-capabilities"
import { cn } from "@/lib/utils"

const HEX = /^#[0-9a-f]{6}$/i

/** El código del color como lo entiende el selector nativo (siempre `#rrggbb` minúsculas). */
function nativeColorValue(value: string): string {
  return HEX.test(value.trim()) ? value.trim().toLowerCase() : "#000000"
}

type TextField = Exclude<keyof BrandingForm, "palette_preset">

export function DocumentBrandingSettings() {
  const { branding, isLoading } = useDocumentBranding()

  if (isLoading) {
    return (
      <Card>
        <CardContent className="flex items-center gap-2 py-8 text-sm text-muted-foreground" aria-live="polite">
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
          Cargando…
        </CardContent>
      </Card>
    )
  }
  return <BrandingEditor branding={branding} />
}

function FiscalReadOnlyBlock({ fiscal }: { fiscal: FiscalData }) {
  // La condición de IVA se muestra como se imprime: la leyenda del papel.
  const iva =
    ISSUER_IVA_LEGEND[fiscal.iva_condition ?? ""] ??
    IVA_CONDITION_OPTIONS.find((option) => option.value === fiscal.iva_condition)?.label ??
    fiscal.iva_condition
  const rows: Array<[string, string | null]> = [
    ["Razón social", fiscal.razon_social],
    ["Nombre de fantasía", fiscal.nombre_fantasia],
    ["CUIT", fiscal.cuit],
    ["Domicilio comercial", fiscal.domicilio_comercial],
    ["Condición frente al IVA", iva],
  ]
  return (
    <section className="rounded-md border border-border bg-muted/40 p-3" aria-labelledby="documentos-fiscal-title">
      <h4 id="documentos-fiscal-title" className="text-sm font-semibold text-foreground">
        Sale de Datos fiscales (AFIP)
      </h4>
      <dl className="mt-2 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_minmax(0,1fr)]">
        {rows.map(([label, value]) =>
          value ? (
            <div key={label} className="contents">
              <dt className="text-muted-foreground">{label}</dt>
              <dd className="break-words font-medium text-foreground">{value}</dd>
            </div>
          ) : null,
        )}
      </dl>
      <p className="mt-2 text-xs text-muted-foreground">
        Estos datos se imprimen tal como están en tu perfil fiscal.{" "}
        <Link href="/configuracion?tab=fiscal" className="font-medium text-primary underline underline-offset-2">
          Cambiarlos en Datos fiscales
        </Link>
      </p>
    </section>
  )
}

function PaletteSwatch({ choice, color, disabled }: { choice: PaletteChoice; color: string | null; disabled: boolean }) {
  const swatch = paletteForPreview(color, NEUTRAL_PALETTE, choice.key)
  const background = isSafeHexColor(color) ? color : NEUTRAL_PALETTE.surface
  const mark = isSafeHexColor(swatch.table_head_text) ? swatch.table_head_text : NEUTRAL_PALETTE.ink
  const id = `documentos-palette-${choice.key}`
  return (
    <Label
      htmlFor={id}
      className={cn(
        "flex min-w-0 cursor-pointer items-center gap-2 rounded-md border border-border p-2 text-sm font-normal",
        "has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:ring-1 has-[[data-state=checked]]:ring-primary",
        disabled && "cursor-not-allowed opacity-70",
      )}
    >
      <RadioGroupItem
        id={id}
        value={choice.key}
        aria-label={choice.label}
        disabled={disabled}
        className="h-7 w-7 shrink-0 rounded-md border-2 border-border"
        style={{ backgroundColor: background, color: mark }}
      />
      <span className="min-w-0 break-words">{choice.label}</span>
    </Label>
  )
}

function BrandingEditor({ branding }: { branding: DocumentBranding }) {
  const fieldId = useId()
  const { roles, rolesResolved } = useOrgRole()
  const canEdit = hasCapability(roles, CAN_CONFIGURE, rolesResolved)
  const { mutateAsync: save, isPending } = useUpdateDocumentBranding()
  const { dataUri } = useDocumentLogoDataUri(branding.logo?.sha256 ?? null)
  const [serverAccentError, setServerAccentError] = useState<string | null>(null)

  const form = useForm<BrandingForm>({
    resolver: zodResolver(documentBrandingFormSchema),
    defaultValues: formFromSettings(branding.settings),
    mode: "onChange",
  })
  const values = form.watch()
  const { dirtyFields } = form.formState
  const dirty = Object.keys(dirtyFields).length > 0

  const parsed = useMemo(() => documentBrandingFormSchema.safeParse(values), [values])
  const fieldErrors: Partial<Record<keyof BrandingForm, string>> = {}
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const key = issue.path[0] as keyof BrandingForm | undefined
      if (key && !(key in fieldErrors)) fieldErrors[key] = issue.message
    }
  }

  const customSelected = values.palette_preset === "personalizado"
  const typedColor = values.accent_color.trim()
  const colorIsHex = HEX.test(typedColor)
  const ratio = colorIsHex ? contrastRatio(hexToRgb(typedColor)!, WHITE) : null
  const readable = ratio !== null && ratio >= MIN_ACCENT_CONTRAST

  const catalogAccent = (key: PaletteKey): string | null =>
    branding.palettes.find((choice) => choice.key === key)?.accent ?? null
  const previewAccent = customSelected ? (colorIsHex ? typedColor : null) : catalogAccent(values.palette_preset)
  const previewPalette = paletteForPreview(previewAccent, branding.palette, values.palette_preset)
  const issuerPreview = previewIssuer(values, branding.fiscal, branding.owner_fallback)

  function setPalette(next: string) {
    const key = next as PaletteKey
    setServerAccentError(null)
    form.setValue("palette_preset", key, { shouldDirty: true, shouldValidate: true })
    // «Personalizado» arranca desde el color de la paleta que se estaba viendo; las demás
    // no llevan color propio.
    const seed = key === "personalizado" ? (previewAccent ?? "") : ""
    form.setValue("accent_color", seed, { shouldDirty: true, shouldValidate: true })
  }

  function setAccent(next: string) {
    setServerAccentError(null)
    form.setValue("accent_color", next, { shouldDirty: true, shouldValidate: true })
  }

  async function onSubmit() {
    if (!parsed.success) return
    try {
      await save(formToPayload(values))
      toast.success("Guardamos los datos de tus documentos. Ya salen en los papeles nuevos.")
      form.reset(values)
    } catch (err: unknown) {
      if (err instanceof PythonApiError && err.code === "branding_accent_low_contrast") {
        setServerAccentError(err.message)
        toast.error(err.message)
      } else if (err instanceof PythonApiError && err.status === 403) {
        toast.error("Sólo el dueño o un administrador puede cambiar los datos de los documentos.")
      } else if (err instanceof PythonApiError && err.status === 422) {
        toast.error(err.message)
      } else {
        toast.error("No se pudieron guardar los datos. Probá de nuevo en un momento.")
      }
    }
  }

  function textField(
    name: TextField,
    label: string,
    opts: { hint?: string; placeholder?: string; inputMode?: "tel" | "email" | "url" | "text" } = {},
  ) {
    const id = `${fieldId}-${name}`
    const error = dirtyFields[name] ? fieldErrors[name] : undefined
    return (
      <div className="grid gap-1.5">
        <Label htmlFor={id}>{label}</Label>
        <Input
          id={id}
          placeholder={opts.placeholder}
          inputMode={opts.inputMode}
          autoComplete="off"
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? `${id}-error` : opts.hint ? `${id}-hint` : undefined}
          {...form.register(name)}
        />
        {error ? (
          <p id={`${id}-error`} className="text-xs text-destructive">{error}</p>
        ) : opts.hint ? (
          <p id={`${id}-hint`} className="text-xs text-muted-foreground">{opts.hint}</p>
        ) : null}
      </div>
    )
  }

  // El mensaje del esquema sólo se muestra para un código mal formado; el aviso de contraste
  // ya lo da el indicador en vivo (no se repite).
  const accentError =
    serverAccentError ??
    (dirtyFields.accent_color && customSelected && typedColor !== "" && !colorIsHex ? fieldErrors.accent_color : undefined)
  const footerId = `${fieldId}-footer_note`
  const footerError = dirtyFields.footer_note ? fieldErrors.footer_note : undefined

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,26rem)]">
      <form className="grid min-w-0 gap-6" onSubmit={form.handleSubmit(onSubmit)} noValidate>
        <Card>
          <CardHeader>
            <CardTitle>Documentos</CardTitle>
            <CardDescription>
              Tu logo, tus datos y tus colores salen en el comprobante de venta, presupuestos y remitos.
            </CardDescription>
          </CardHeader>
          <CardContent className="grid gap-6">
            {!canEdit && (
              <p className="rounded-md border border-border bg-muted/40 p-3 text-sm text-muted-foreground">
                Sólo el dueño o un administrador puede cambiar estos datos. Acá ves cómo salen tus documentos.
              </p>
            )}

            <div className="grid gap-2">
              <h3 className="text-sm font-semibold text-foreground">Logo</h3>
              <DocumentLogoUpload logo={branding.logo} dataUri={dataUri} canEdit={canEdit} />
            </div>

            <fieldset disabled={!canEdit} className="grid min-w-0 gap-6 border-0 p-0">
              <div className="grid gap-4">
                <h3 className="text-sm font-semibold text-foreground">Datos de la empresa</h3>
                {textField("display_name", "Nombre comercial", {
                  hint: "Si lo dejás vacío usamos el de tu perfil fiscal o el nombre de tu negocio.",
                })}

                {branding.fiscal ? (
                  <FiscalReadOnlyBlock fiscal={branding.fiscal} />
                ) : (
                  <>
                    {textField("legal_name", "Razón social")}
                    {textField("tax_id", "CUIT", { placeholder: "20-12345678-6", inputMode: "text" })}
                    {textField("address", "Domicilio")}
                  </>
                )}

                <div className="grid gap-4 sm:grid-cols-2">
                  {textField("phone", "Teléfono", { inputMode: "tel", hint: "Vacío = el del perfil del dueño." })}
                  {textField("email", "Email del negocio", {
                    inputMode: "email",
                    hint: "Es el que se imprime en los papeles; no es el email con el que entrás a la app.",
                  })}
                </div>
                {textField("website", "Sitio web", { inputMode: "url", placeholder: "www.minegocio.com.ar" })}

                <div className="grid gap-1.5">
                  <Label htmlFor={footerId}>Leyenda al pie de los papeles</Label>
                  <Textarea
                    id={footerId}
                    rows={3}
                    aria-invalid={footerError ? true : undefined}
                    placeholder="Ej.: Alias para transferencias: mi.negocio"
                    {...form.register("footer_note")}
                  />
                  {footerError && <p className="text-xs text-destructive">{footerError}</p>}
                </div>
              </div>

              <div className="grid gap-3">
                <h3 className="text-sm font-semibold text-foreground">Colores</h3>
                <RadioGroup
                  aria-label="Paleta de colores"
                  value={values.palette_preset}
                  onValueChange={setPalette}
                  disabled={!canEdit}
                  className="grid-cols-1 sm:grid-cols-2"
                >
                  {branding.palettes.map((choice) => (
                    <PaletteSwatch
                      key={choice.key}
                      choice={choice}
                      color={choice.key === "personalizado" ? (colorIsHex ? typedColor : null) : choice.accent}
                      disabled={!canEdit}
                    />
                  ))}
                </RadioGroup>

                {customSelected && (
                  <div className="grid gap-1.5">
                    <Label htmlFor={`${fieldId}-accent`}>Código del color (#rrggbb)</Label>
                    <div className="flex items-center gap-2">
                      <input
                        type="color"
                        value={nativeColorValue(values.accent_color)}
                        onChange={(event) => setAccent(event.target.value)}
                        aria-label="Elegir color con el selector"
                        className="h-9 w-12 shrink-0 cursor-pointer rounded-md border border-input bg-background p-1 disabled:cursor-not-allowed disabled:opacity-50"
                      />
                      <Input
                        id={`${fieldId}-accent`}
                        value={values.accent_color}
                        onChange={(event) => setAccent(event.target.value)}
                        placeholder="#7c2d12"
                        autoComplete="off"
                        spellCheck={false}
                        aria-invalid={accentError ? true : undefined}
                        className="max-w-40 font-mono"
                      />
                    </div>
                    {ratio !== null ? (
                      <p
                        role="status"
                        className={cn(
                          "flex items-center gap-1.5 text-xs font-medium",
                          readable ? "text-success" : "text-destructive",
                        )}
                      >
                        {readable ? (
                          <Check className="h-3.5 w-3.5" aria-hidden="true" />
                        ) : (
                          <TriangleAlert className="h-3.5 w-3.5" aria-hidden="true" />
                        )}
                        {readable ? "Se lee bien sobre blanco" : "No se lee bien sobre blanco"} · {formatContrast(ratio)}
                      </p>
                    ) : typedColor === "" ? (
                      <p className="text-xs text-muted-foreground">Elegí el color con el selector o escribí su código.</p>
                    ) : null}
                    {accentError && <p className="text-xs text-destructive">{accentError}</p>}
                    <p className="text-xs text-muted-foreground">
                      Para que se lea al imprimir, el color tiene que tener un contraste de al menos 4,5:1 sobre blanco.
                    </p>
                  </div>
                )}
              </div>
            </fieldset>

            {canEdit && (
              <div className="flex justify-end">
                <Button type="submit" disabled={!dirty || !parsed.success || isPending}>
                  {isPending ? (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />
                  ) : (
                    <Save className="mr-2 h-4 w-4" aria-hidden="true" />
                  )}
                  Guardar
                </Button>
              </div>
            )}
          </CardContent>
        </Card>
      </form>

      <aside className="min-w-0 lg:sticky lg:top-4 lg:self-start">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Vista previa</CardTitle>
            <CardDescription>Así sale el encabezado de un presupuesto con lo que estás editando.</CardDescription>
          </CardHeader>
          <CardContent>
            <DocumentHeaderPreview
              issuer={issuerPreview.issuer}
              footerNote={issuerPreview.footer_note}
              palette={previewPalette}
              logoDataUri={branding.logo ? dataUri : null}
            />
          </CardContent>
        </Card>
      </aside>
    </div>
  )
}
