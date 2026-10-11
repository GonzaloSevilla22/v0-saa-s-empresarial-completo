"use client"

/**
 * documentos-marca-empresa (D10, task 11.2) — subir, ver y quitar el logo de la cuenta.
 *
 * Patrón de `AvatarUpload`, pero el archivo va al BACKEND (`PUT /document-branding/logo`, cuerpo
 * binario): el servidor reconoce el formato por contenido, rechaza bombas de descompresión,
 * lo reduce a <= 1000 px, le quita los metadatos y lo guarda normalizado. Acá sólo se hace un
 * chequeo previo de tipo y peso para dar el mensaje ANTES de subir, y se muestra el logo que
 * DEVOLVIÓ el servidor (no el archivo elegido).
 *
 * Sólo owner/admin cambian el logo (`canEdit`); el resto lo ve y nada más.
 */

import { useRef, useState } from "react"
import { ImagePlus, Loader2, Trash2 } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
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
import { useDeleteDocumentLogo, useUploadDocumentLogo } from "@/hooks/data/use-document-branding"
import { logoErrorMessage, validateLogoFile } from "@/lib/api/document-logo"
import { isSafeLogoDataUri, type LogoDescriptor } from "@/lib/document-branding"

interface DocumentLogoUploadProps {
  logo: LogoDescriptor | null
  /** El logo normalizado como `data:` URI (lo baja el hook por huella). */
  dataUri: string | undefined
  canEdit: boolean
}

export function DocumentLogoUpload({ logo, dataUri, canEdit }: DocumentLogoUploadProps) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [confirmingRemoval, setConfirmingRemoval] = useState(false)
  const { mutateAsync: upload, isPending: uploading } = useUploadDocumentLogo()
  const { mutateAsync: remove, isPending: removing } = useDeleteDocumentLogo()
  const busy = uploading || removing

  async function handleFile(file: File | undefined) {
    if (!file) return
    const problem = validateLogoFile(file)
    if (problem) {
      toast.error(problem)
      resetInput()
      return
    }
    try {
      const result = await upload(file)
      if (result) toast.success("Logo actualizado. Ya aparece en tus documentos.")
    } catch (err: unknown) {
      toast.error(logoErrorMessage(err))
    } finally {
      resetInput()
    }
  }

  function resetInput() {
    if (inputRef.current) inputRef.current.value = ""   // permite elegir el mismo archivo de nuevo
  }

  async function handleRemove() {
    try {
      await remove()
      toast.success("Quitamos el logo de tus documentos.")
    } catch (err: unknown) {
      toast.error(logoErrorMessage(err))
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-4">
        <div className="flex h-20 w-40 shrink-0 items-center justify-center rounded-md border border-border bg-white p-2">
          {isSafeLogoDataUri(dataUri) ? (
            // eslint-disable-next-line @next/next/no-img-element -- data: URI normalizado por el servidor
            <img src={dataUri} alt="Logo de la empresa" className="max-h-full max-w-full object-contain" />
          ) : logo ? (
            <span className="text-xs text-neutral-600">Cargando logo…</span>
          ) : (
            <span className="text-center text-xs text-neutral-600">Todavía no hay logo.</span>
          )}
        </div>
        {logo && <p className="text-xs text-muted-foreground">{logo.width} × {logo.height} px</p>}
      </div>

      {canEdit && (
        <>
          <div className="flex flex-wrap items-center gap-2">
            <input
              ref={inputRef}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              className="sr-only"
              aria-label="Elegir archivo de logo"
              tabIndex={-1}
              onChange={(event) => void handleFile(event.target.files?.[0])}
            />
            <Button type="button" variant="outline" size="sm" disabled={busy} onClick={() => inputRef.current?.click()}>
              {uploading ? <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" /> : <ImagePlus className="mr-1.5 h-3.5 w-3.5" />}
              {uploading ? "Subiendo…" : logo ? "Cambiar logo" : "Subir logo"}
            </Button>
            {logo && (
              <Button type="button" variant="ghost" size="sm" disabled={busy} onClick={() => setConfirmingRemoval(true)}>
                <Trash2 className="mr-1.5 h-3.5 w-3.5" />
                Quitar logo
              </Button>
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            PNG, JPEG o WebP de hasta 2 MB. Lo reducimos y optimizamos solos; un PNG con fondo transparente queda mejor
            sobre el papel blanco.
          </p>
        </>
      )}

      <AlertDialog open={confirmingRemoval} onOpenChange={setConfirmingRemoval}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Quitar el logo?</AlertDialogTitle>
            <AlertDialogDescription>
              Tus comprobantes, presupuestos y remitos van a salir sin logo hasta que subas otro.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction onClick={() => void handleRemove()}>Quitar</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
