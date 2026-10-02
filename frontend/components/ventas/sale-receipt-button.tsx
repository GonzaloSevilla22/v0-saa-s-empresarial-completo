"use client"

/**
 * SaleReceiptButton
 *
 * Renders a compact action group for a SaleOperation:
 *  - "Comprobante" → dropdown with "Descargar / Imprimir" and "Copiar texto"
 *  - "Enviar por WhatsApp" → direct deep-link to the client's number (wa.me/<phone>?text=…).
 *    Falls back to WhatsApp contact picker if no phone is available.
 *
 * factura-fiscal-imprimible (D10): con el comprobante AUTORIZADO el menú pasa a
 * "Factura" (ver/imprimir, descargar, duplicado, verificar en ARCA) y el
 * comprobante interno queda rotulado "sin validez fiscal"; WhatsApp comparte
 * la FACTURA (y, si todavía no se puede imprimir, el comprobante interno con un
 * aviso del motivo). El PDF lo genera el backend (`GET /fiscal/documents/{id}/pdf`)
 * desde lo autorizado; el compartir/descargar es el MISMO flujo del
 * comprobante interno (helpers de abajo), no una copia.
 */

import { useState, useCallback } from "react"
import {
  FileText,
  Copy,
  Check,
  Loader2,
  MessageCircle,
  ChevronDown,
  Download,
  Files,
  ShieldCheck,
  Receipt,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { toast } from "sonner"
import { useAuth } from "@/contexts/auth-context"
import { getAuthHeaders, redirectedOnUnauthorized, tokenFromHeaders } from "@/lib/api/auth-headers"
import {
  generateReceiptHTML,
  generateReceiptText,
  generateReceiptShortText,
  buildSalesReceiptPdfPayload,
} from "@/lib/receipt"
import { getDocumentScriptNonce } from "@/lib/script-nonce"
import { normalizeWhatsAppPhone } from "@/lib/phone-utils"
import { downloadBlob, openWhatsAppText as openWhatsAppChat, sharePdf, type SharePdfResult } from "@/lib/document-share"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { resolveUnit } from "@/lib/unit-utils"
import type { SaleOperation } from "@/lib/group-operations"
import { FiscalInvoiceError, fetchFiscalInvoicePdf, type InvoiceCopy } from "@/lib/api/fiscal-invoice"
import {
  ARCA_CONSTATACION_URL,
  hasPrintableInvoice,
  invoiceDisplayName,
  invoiceFileName,
} from "@/lib/fiscal-comprobante"

/** Adónde lleva el aviso de datos del emisor incompletos. */
const FISCAL_SETTINGS_PATH = "/configuracion/fiscal"

// Los helpers de archivo y de compartir (`downloadBlob`, `sharePdf`,
// `openWhatsAppText`) viven en `lib/document-share.ts` (presupuestos-modulo D9):
// los comparten el comprobante, la factura y el menú de los documentos
// comerciales.

/** Compartido o cancelado por el usuario: el menú nativo ya resolvió el envío. */
function wasHandledByShare(result: SharePdfResult): boolean {
  return result === "shared" || result === "cancelled"
}

function invoiceErrorMessage(err: unknown): string {
  return err instanceof Error && err.message ? err.message : "No se pudo obtener la factura."
}

/** Con datos del emisor incompletos, el aviso lleva a completarlos. */
function issuerDataAction(err: unknown) {
  return err instanceof FiscalInvoiceError && err.code === "issuer_data_incomplete"
    ? {
        action: {
          label: "Completar datos fiscales",
          onClick: () => window.location.assign(FISCAL_SETTINGS_PATH),
        },
      }
    : undefined
}

interface SaleReceiptButtonProps {
  op: SaleOperation
  /** Raw phone string from the client record — normalised internally before use */
  clientPhone?: string | null
  /** Client's first name for the personalised WhatsApp greeting */
  clientFirstName?: string | null
}

export function SaleReceiptButton({
  op,
  clientPhone,
  clientFirstName,
}: SaleReceiptButtonProps) {
  const { user } = useAuth()
  const fiscal = op.fiscal
  const invoice = hasPrintableInvoice(fiscal) ? fiscal : null
  const [loadingPrint, setLoadingPrint] = useState(false)
  const [loadingWa, setLoadingWa]       = useState(false)
  const [copied, setCopied]             = useState(false)

  // ventas-unidades-conversion (D8): la unidad de cada línea, desde el mismo
  // mapa cacheado que usan los formularios.
  const { unitsById } = useUnitsOfMeasure()
  const unitSymbolFor = useCallback(
    (unitId?: string) => resolveUnit(unitId, unitsById)?.symbol,
    [unitsById],
  )

  // ── Receipt options derived from user profile ────────────────────────────
  const receiptOpts = {
    businessName:    user?.businessName || user?.name || "Mi Negocio",
    businessPhone:   user?.phone,
    businessEmail:   user?.email,
    logoUrl:         user?.avatar,
    clientFirstName: clientFirstName ?? undefined,
    unitSymbolFor,
  }

  // Does the client have a valid WhatsApp-capable phone number?
  const hasValidPhone = !!normalizeWhatsAppPhone(clientPhone)

  // ── Download / print ─────────────────────────────────────────────────────
  const handleDownload = useCallback(async () => {
    setLoadingPrint(true)
    try {
      // fix/comprobante-print-csp-nonce: la pestaña `blob:` que abrimos más
      // abajo HEREDA la CSP de este documento (script-src sin
      // 'unsafe-inline'). Sin el nonce vigente, el <script> de auto-impresión
      // del comprobante queda bloqueado — se abre la pestaña pero nunca
      // dispara window.print(). El helper lee el nonce del <script> que Next
      // ya montó con la política de ESTA carga.
      const scriptNonce = getDocumentScriptNonce()
      const html = generateReceiptHTML(op, { ...receiptOpts, scriptNonce })
      const blob = new Blob([html], { type: "text/html;charset=utf-8" })
      const url  = URL.createObjectURL(blob)

      const win = window.open(url, "_blank")
      if (!win) {
        // Popup blocked — fall back to anchor download
        const a = document.createElement("a")
        a.href = url
        a.download = `comprobante-${op.operationId ?? op.key}.html`
        document.body.appendChild(a)
        a.click()
        document.body.removeChild(a)
        toast.info("Comprobante descargado. Abrilo en tu navegador para imprimir o guardar como PDF.")
      }

      // Revoke after enough time for the new tab to read the blob
      setTimeout(() => URL.revokeObjectURL(url), 10_000)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : undefined
      toast.error(message || "No se pudo generar el comprobante.")
    } finally {
      setLoadingPrint(false)
    }
  }, [op, receiptOpts])

  // ── Copy text to clipboard ───────────────────────────────────────────────
  const handleCopy = useCallback(async () => {
    const text = generateReceiptText(op, receiptOpts)
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      toast.success("Texto copiado al portapapeles")
      setTimeout(() => setCopied(false), 2000)
    } catch {
      toast.error("No se pudo copiar el texto")
    }
  }, [op, receiptOpts])

  // ── Send via WhatsApp (mensaje corto + PDF adjunto) ──────────────────────
  // En el celular: abre el menú de compartir con el PDF real + el mensaje corto
  // → el usuario elige WhatsApp y se manda el comprobante adjunto. WhatsApp no
  // permite adjuntar archivos vía link wa.me, por eso se usa el share nativo.
  // Fallback (compu / sin soporte): descarga el PDF y abre WhatsApp con el texto.
  const openWhatsAppText = useCallback(
    (text: string) => {
      const hadNumber = openWhatsAppChat(clientPhone, text)
      if (!hadNumber) {
        toast.info(
          "No hay número de WhatsApp registrado para este cliente. Seleccioná el contacto en WhatsApp.",
          { duration: 4000 },
        )
      }
    },
    [clientPhone],
  )

  // ── Factura (comprobante autorizado) ─────────────────────────────────────
  const showInvoiceError = useCallback((err: unknown) => {
    toast.error(invoiceErrorMessage(err), issuerDataAction(err))
  }, [])

  const handleInvoice = useCallback(
    async (mode: "view" | "download" | "duplicate") => {
      if (!invoice) return
      const copy: InvoiceCopy = mode === "duplicate" ? "duplicado" : "original"
      // La pestaña se abre YA, dentro del gesto del usuario: abrirla después
      // del `await` del PDF la bloquean los navegadores móviles (Safari iOS).
      // Se le carga el PDF cuando llega; si falla, se cierra.
      const tab = mode === "view" ? window.open("", "_blank") : null
      setLoadingPrint(true)
      try {
        const blob = await fetchFiscalInvoicePdf(invoice.documentId, {
          disposition: mode === "view" ? "inline" : "attachment",
          copy,
        })
        if (!blob) {
          tab?.close() // la sesión venció: ya se navegó al login
          return
        }
        const fileName = invoiceFileName(invoice, copy)
        if (mode === "view" && tab) {
          // Visor de PDF del navegador (imprime desde ahí). Un blob
          // application/pdf no ejecuta scripts: la CSP no interviene.
          const url = URL.createObjectURL(blob)
          tab.location.href = url
          setTimeout(() => URL.revokeObjectURL(url), 60_000)
        } else {
          downloadBlob(blob, fileName)
          if (mode === "view") toast.info("Descargamos la factura en PDF. Abrila para imprimirla.")
        }
      } catch (err: unknown) {
        tab?.close()
        showInvoiceError(err)
      } finally {
        setLoadingPrint(false)
      }
    },
    [invoice, showInvoiceError],
  )

  const handleVerifyInArca = useCallback(() => {
    window.open(ARCA_CONSTATACION_URL, "_blank", "noopener,noreferrer")
  }, [])

  const handleWhatsApp = useCallback(async () => {
    const shortText = generateReceiptShortText(op, receiptOpts)
    setLoadingWa(true)
    try {
      const payload = buildSalesReceiptPdfPayload(op, receiptOpts)
      // auth-hardening-jwt-cookies (D21/14.8): antes se mandaba
      // `Bearer ` VACÍO cuando no había sesión, en vez de omitir el
      // encabezado. Los encabezados los arma ahora el helper compartido.
      const headers = await getAuthHeaders({ "Content-Type": "application/json" })
      const res = await fetch(`${process.env.NEXT_PUBLIC_BACKEND_URL}/sales/receipt-pdf`, {
        method:  "POST",
        headers,
        body: JSON.stringify(payload),
      })
      // D7: un 401 sin sesión lleva al login en vez de morir en un toast.
      // Revisión adversarial (MINOR 2 de seguridad): hay que CORTAR cuando ya se
      // navegó. `window.location.assign()` es asíncrono, así que sin el `return`
      // el usuario veía el toast de error mientras la navegación salía.
      if (await redirectedOnUnauthorized(res, tokenFromHeaders(headers))) return
      if (!res.ok) throw new Error("pdf")

      const blob = await res.blob()
      const fileName = `comprobante-${payload.receipt_number}.pdf`
      const file = new File([blob], fileName, { type: "application/pdf" })

      if (wasHandledByShare(await sharePdf(file, shortText, "Comprobante de venta"))) return

      // Fallback: descargar el PDF + abrir WhatsApp con el mensaje corto
      downloadBlob(blob, fileName)
      openWhatsAppText(shortText)
      toast.info("Descargamos el comprobante en PDF. Adjuntalo en el chat de WhatsApp que se abrió.")
    } catch {
      // Último recurso: solo el mensaje de texto por WhatsApp
      openWhatsAppText(shortText)
    } finally {
      setLoadingWa(false)
    }
  }, [op, receiptOpts, openWhatsAppText])

  // Con una factura que todavía no se puede imprimir (sin fecha confirmada,
  // datos del emisor incompletos, …) WhatsApp NO se queda sin nada que mandar:
  // avisa por qué y manda el comprobante interno, como antes de la factura
  // imprimible. Una sesión vencida (null) ya navegó al login: no manda nada.
  const handleWhatsAppInvoice = useCallback(async () => {
    if (!invoice) return
    const shortText = generateReceiptShortText(op, {
      ...receiptOpts,
      documentName: `la ${invoiceDisplayName(invoice) ?? "factura"}`,
    })
    setLoadingWa(true)
    let fallbackToInternal = false
    try {
      const blob = await fetchFiscalInvoicePdf(invoice.documentId, { disposition: "attachment", copy: "original" })
      if (!blob) return
      const fileName = invoiceFileName(invoice)
      const file = new File([blob], fileName, { type: "application/pdf" })
      if (wasHandledByShare(await sharePdf(file, shortText, "Factura"))) return
      downloadBlob(blob, fileName)
      openWhatsAppText(shortText)
      toast.info("Descargamos la factura en PDF. Adjuntala en el chat de WhatsApp que se abrió.")
    } catch (err: unknown) {
      fallbackToInternal = true
      toast.info(
        `${invoiceErrorMessage(err)} Te enviamos el comprobante interno (sin validez fiscal).`,
        issuerDataAction(err),
      )
    } finally {
      setLoadingWa(false)
    }
    if (fallbackToInternal) await handleWhatsApp()
  }, [invoice, op, receiptOpts, openWhatsAppText, handleWhatsApp])

  return (
    <div className="flex items-center gap-1.5" onClick={(e) => e.stopPropagation()}>

      {/* ── Comprobante / Factura dropdown ───────────────────────────────── */}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            variant="outline"
            size="sm"
            className="h-7 gap-1 border-border text-foreground text-xs px-2.5"
            disabled={loadingPrint}
          >
            {loadingPrint
              ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
              : invoice ? <Receipt className="h-3.5 w-3.5" /> : <FileText className="h-3.5 w-3.5" />}
            {invoice ? "Factura" : "Comprobante"}
            <ChevronDown className="h-3 w-3 text-muted-foreground" />
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent
          align="end"
          className={`${invoice ? "w-64" : "w-48"} bg-popover border-border`}
          onClick={(e) => e.stopPropagation()}
        >
          {invoice && (
            <>
              <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={() => handleInvoice("view")}>
                <Receipt className="h-4 w-4 text-muted-foreground" />
                <span>Ver / imprimir factura</span>
              </DropdownMenuItem>
              <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={() => handleInvoice("download")}>
                <Download className="h-4 w-4 text-muted-foreground" />
                <span>Descargar factura (PDF)</span>
              </DropdownMenuItem>
              <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={() => handleInvoice("duplicate")}>
                <Files className="h-4 w-4 text-muted-foreground" />
                <span>Descargar duplicado</span>
              </DropdownMenuItem>
              <DropdownMenuItem className="gap-2 cursor-pointer" onSelect={handleVerifyInArca}>
                <ShieldCheck className="h-4 w-4 text-muted-foreground" />
                <span>Verificar en ARCA</span>
              </DropdownMenuItem>
              <DropdownMenuSeparator />
            </>
          )}

          <DropdownMenuItem
            className="gap-2 cursor-pointer"
            onSelect={handleDownload}
          >
            <FileText className="h-4 w-4 text-muted-foreground" />
            <span>{invoice ? "Comprobante interno (sin validez fiscal)" : "Descargar / Imprimir"}</span>
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem
            className="gap-2 cursor-pointer"
            onSelect={handleCopy}
          >
            {copied
              ? <Check className="h-4 w-4 text-success" />
              : <Copy className="h-4 w-4 text-muted-foreground" />}
            <span>{copied ? "¡Copiado!" : "Copiar texto"}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* ── WhatsApp direct button ───────────────────────────────────────── */}
      <Button
        variant="outline"
        size="sm"
        onClick={invoice ? handleWhatsAppInvoice : handleWhatsApp}
        disabled={loadingWa}
        className={[
          "h-7 gap-1.5 text-xs px-2.5 transition-colors",
          hasValidPhone
            ? "border-[#25D366]/40 text-[#25D366] hover:bg-[#25D366]/10 hover:border-[#25D366]/60"
            : "border-border text-muted-foreground hover:text-foreground",
        ].join(" ")}
        title={
          hasValidPhone
            ? `Enviar ${invoice ? "la factura" : "comprobante"} por WhatsApp al cliente`
            : "Enviar por WhatsApp (sin número de cliente registrado)"
        }
      >
        {loadingWa
          ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
          : <MessageCircle className="h-3.5 w-3.5" />}
        {hasValidPhone ? "Enviar por WhatsApp" : "WhatsApp"}
      </Button>
    </div>
  )
}
