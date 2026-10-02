"use client"

/**
 * presupuestos-modulo (D9) — menú "Compartir" de un documento comercial en PDF.
 *
 * Reúne las tres salidas que el PO pidió para el presupuesto ("se descarga
 * para enviárselo o se envía por WhatsApp") en un componente que los remitos
 * van a reutilizar sin cambios:
 *
 *  - **Ver / imprimir**: abre la pestaña DENTRO del gesto del usuario (si se
 *    abre después del `await` del PDF, Safari iOS la bloquea) y le carga el
 *    blob cuando llega. No marca el documento como enviado: mirar el PDF propio
 *    antes de mandarlo es el uso más común.
 *  - **Descargar PDF**: baja el archivo y avisa `onShared`.
 *  - **Enviar por WhatsApp**: en el celular, share nativo con el ARCHIVO; en
 *    escritorio, descarga + `wa.me/<teléfono>?text=`; sin número válido,
 *    `wa.me/?text=` con aviso.
 *
 * El share nativo exige la activación del gesto, que en iOS expira después de
 * los `await` del fetch. Por eso el PDF se **precarga al abrir el menú** y el
 * toque de WhatsApp llama a `sharePdf` SINCRÓNICAMENTE con el blob listo; si
 * todavía no llegó, el ítem dice "Preparando…" y el menú queda abierto para un
 * segundo toque.
 *
 * `onShared` se pasa sólo cuando el llamador tiene permiso para marcar el
 * documento como enviado: Descargar y WhatsApp (con "shared" o con el fallback
 * de descarga + wa.me, nunca con "cancelled") lo llaman; "Ver" no. Sin él, todo
 * funciona igual (un rol sin permiso descarga sin cambiar el estado).
 */
import { useCallback, useEffect, useRef, useState } from "react"
import { Download, Eye, Loader2, MessageCircle, Share2 } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { downloadBlob, openWhatsAppText, sharePdf } from "@/lib/document-share"
import type { PdfDisposition } from "@/lib/api/document-pdf"

export interface DocumentShareMenuProps {
  /** El PDF del documento; `null` si la sesión venció (el 401 ya navegó al login). */
  fetchPdf: (disposition: PdfDisposition) => Promise<Blob | null>
  fileName: string
  /** Texto corto que acompaña al PDF por WhatsApp. */
  shareText: string
  /** Título del share nativo. */
  shareTitle: string
  /** Teléfono crudo del cliente; se normaliza internamente. */
  clientPhone?: string | null
  /** Se llama cuando el documento salió hacia el cliente (descarga o WhatsApp). */
  onShared?: () => void
  className?: string
}

const NO_PHONE_NOTICE =
  "No hay número de WhatsApp registrado para este cliente. Seleccioná el contacto en WhatsApp."
const ATTACH_NOTICE = "Descargamos el PDF. Adjuntalo en el chat de WhatsApp que se abrió."
const PREPARING_NOTICE = "Preparando el PDF… tocá de nuevo en un instante."

function errorMessage(err: unknown): string {
  return err instanceof Error && err.message ? err.message : "No se pudo obtener el documento. Probá de nuevo."
}

export function DocumentShareMenu({
  fetchPdf,
  fileName,
  shareText,
  shareTitle,
  clientPhone,
  onShared,
  className,
}: DocumentShareMenuProps) {
  const [blob, setBlob] = useState<Blob | null>(null)
  const [preparing, setPreparing] = useState(false)
  const [notice, setNotice] = useState("")
  // Descarta la respuesta de una precarga vieja (el menú se cerró o se reabrió).
  const preloadToken = useRef(0)
  const mounted = useRef(true)

  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  const announce = useCallback((message: string) => setNotice(message), [])

  const preload = useCallback(async () => {
    const token = ++preloadToken.current
    setBlob(null)
    setPreparing(true)
    try {
      const result = await fetchPdf("attachment")
      if (!mounted.current || token !== preloadToken.current) return
      // `null`: la sesión venció y ya se navegó al login. Sin toast.
      setBlob(result)
    } catch (err: unknown) {
      if (!mounted.current || token !== preloadToken.current) return
      toast.error(errorMessage(err))
    } finally {
      if (mounted.current && token === preloadToken.current) setPreparing(false)
    }
  }, [fetchPdf])

  const handleOpenChange = useCallback(
    (open: boolean) => {
      if (open) {
        setNotice("")
        void preload()
      } else {
        // Un blob de otra apertura no debe sobrevivir: el documento pudo cambiar.
        preloadToken.current += 1
      }
    },
    [preload],
  )

  /** El PDF para una acción que no necesita el gesto: el precargado o uno nuevo. */
  const resolveBlob = useCallback(
    async (disposition: PdfDisposition): Promise<Blob | null> => {
      if (blob) return blob
      try {
        return await fetchPdf(disposition)
      } catch (err: unknown) {
        toast.error(errorMessage(err))
        return null
      }
    },
    [blob, fetchPdf],
  )

  // ── Ver / imprimir ──────────────────────────────────────────────────────────
  const handleView = useCallback(async () => {
    // La pestaña se abre YA, dentro del gesto: abrirla después del `await` la
    // bloquean los navegadores móviles. Se le carga el PDF cuando llega.
    const tab = window.open("", "_blank")
    let pdf: Blob | null
    try {
      pdf = blob ?? (await fetchPdf("inline"))
    } catch (err: unknown) {
      tab?.close()
      toast.error(errorMessage(err))
      return
    }
    if (!pdf) {
      tab?.close() // la sesión venció: ya se navegó al login
      return
    }
    if (tab) {
      // Visor de PDF del navegador (imprime desde ahí): un blob application/pdf
      // no ejecuta scripts, la CSP no interviene.
      const url = URL.createObjectURL(pdf)
      tab.location.href = url
      setTimeout(() => URL.revokeObjectURL(url), 60_000)
      return
    }
    // El navegador bloqueó la pestaña: se descarga para que no quede sin salida.
    downloadBlob(pdf, fileName)
    toast.info("Descargamos el PDF. Abrilo para imprimirlo.")
  }, [blob, fetchPdf, fileName])

  // ── Descargar ───────────────────────────────────────────────────────────────
  const handleDownload = useCallback(async () => {
    const pdf = await resolveBlob("attachment")
    if (!pdf) return
    downloadBlob(pdf, fileName)
    onShared?.()
  }, [resolveBlob, fileName, onShared])

  // ── WhatsApp ────────────────────────────────────────────────────────────────
  const handleWhatsApp = useCallback(
    async (event: Event) => {
      if (!blob) {
        // El PDF todavía no llegó: se avisa y el menú queda abierto para el
        // segundo toque (el share nativo necesita el blob dentro del gesto).
        event.preventDefault()
        announce(PREPARING_NOTICE)
        return
      }
      const file = new File([blob], fileName, { type: "application/pdf" })
      // `sharePdf` llama a `navigator.share` en esta misma vuelta del gesto.
      const result = await sharePdf(file, shareText, shareTitle)
      if (result === "shared") {
        onShared?.()
        return
      }
      if (result === "cancelled") return

      // Sin share de archivos: descarga + chat con el texto.
      downloadBlob(blob, fileName)
      const hadNumber = openWhatsAppText(clientPhone, shareText)
      if (hadNumber) {
        toast.info(ATTACH_NOTICE)
        announce(ATTACH_NOTICE)
      } else {
        toast.info(NO_PHONE_NOTICE, { duration: 4000 })
        announce(NO_PHONE_NOTICE)
      }
      onShared?.()
    },
    [blob, fileName, shareText, shareTitle, clientPhone, onShared, announce],
  )

  const whatsAppReady = blob !== null
  const whatsAppPreparing = !whatsAppReady && preparing

  return (
    <>
      <DropdownMenu onOpenChange={handleOpenChange}>
        <DropdownMenuTrigger asChild>
          <Button type="button" variant="outline" size="sm" className={className}>
            <Share2 className="h-4 w-4" aria-hidden="true" />
            Compartir
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-60 bg-popover border-border">
          <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={() => void handleView()}>
            <Eye className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
            <span>Ver / imprimir</span>
          </DropdownMenuItem>
          <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={() => void handleDownload()}>
            <Download className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
            <span>Descargar PDF</span>
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            className="gap-2 cursor-pointer"
            aria-busy={whatsAppPreparing}
            onSelect={(event) => void handleWhatsApp(event)}
          >
            {whatsAppPreparing ? (
              <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" aria-hidden="true" />
            ) : (
              <MessageCircle className="h-4 w-4 text-success" aria-hidden="true" />
            )}
            <span>{whatsAppPreparing ? "Preparando…" : "Enviar por WhatsApp"}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {/* Avisos para lectores de pantalla: el menú se cierra al elegir y el
          toast no siempre se anuncia. */}
      <p role="status" aria-live="polite" className="sr-only">
        {notice}
      </p>
    </>
  )
}
