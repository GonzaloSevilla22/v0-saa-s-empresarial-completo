"use client"

/**
 * SaleReceiptButton
 *
 * Renders a compact action group for a SaleOperation:
 *  - "Comprobante" → dropdown with "Descargar / Imprimir" and "Copiar texto"
 *  - "Enviar por WhatsApp" → direct deep-link to the client's number (wa.me/<phone>?text=…).
 *    Falls back to WhatsApp contact picker if no phone is available.
 *
 * Zero external PDF library — uses the browser's native print pipeline.
 */

import { useState, useCallback } from "react"
import { FileText, Copy, Check, Loader2, MessageCircle, ChevronDown } from "lucide-react"
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
import { createClient } from "@/lib/supabase/client"
import {
  generateReceiptHTML,
  generateReceiptText,
  generateReceiptShortText,
  buildSalesReceiptPdfPayload,
} from "@/lib/receipt"
import { buildWhatsAppUrl, normalizeWhatsAppPhone } from "@/lib/phone-utils"
import type { SaleOperation } from "@/lib/group-operations"

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
  const [loadingPrint, setLoadingPrint] = useState(false)
  const [loadingWa, setLoadingWa]       = useState(false)
  const [copied, setCopied]             = useState(false)

  // ── Receipt options derived from user profile ────────────────────────────
  const receiptOpts = {
    businessName:    user?.businessName || user?.name || "Mi Negocio",
    businessPhone:   user?.phone,
    businessEmail:   user?.email,
    logoUrl:         user?.avatar,
    clientFirstName: clientFirstName ?? undefined,
  }

  // Does the client have a valid WhatsApp-capable phone number?
  const hasValidPhone = !!normalizeWhatsAppPhone(clientPhone)

  // ── Download / print ─────────────────────────────────────────────────────
  const handleDownload = useCallback(async () => {
    setLoadingPrint(true)
    try {
      const html = generateReceiptHTML(op, receiptOpts)
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
    } catch (err: any) {
      toast.error(err?.message || "No se pudo generar el comprobante.")
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
      window.open(buildWhatsAppUrl(clientPhone, text), "_blank", "noopener,noreferrer")
      if (!hasValidPhone) {
        toast.info(
          "No hay número de WhatsApp registrado para este cliente. Seleccioná el contacto en WhatsApp.",
          { duration: 4000 },
        )
      }
    },
    [clientPhone, hasValidPhone],
  )

  const handleWhatsApp = useCallback(async () => {
    const shortText = generateReceiptShortText(op, receiptOpts)
    setLoadingWa(true)
    try {
      const payload = buildSalesReceiptPdfPayload(op, receiptOpts)
      const supabase = createClient()
      const { data: { session } } = await supabase.auth.getSession()
      const res = await fetch(`${process.env.NEXT_PUBLIC_BACKEND_URL}/sales/receipt-pdf`, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization:  `Bearer ${session?.access_token ?? ""}`,
        },
        body: JSON.stringify(payload),
      })
      if (!res.ok) throw new Error("pdf")

      const blob = await res.blob()
      const file = new File([blob], `comprobante-${payload.receipt_number}.pdf`, {
        type: "application/pdf",
      })

      const nav = navigator as Navigator & { canShare?: (d: ShareData) => boolean }
      if (nav.canShare?.({ files: [file] })) {
        try {
          await nav.share({ files: [file], text: shortText, title: "Comprobante de venta" })
          return
        } catch (err) {
          if ((err as Error)?.name === "AbortError") return // el usuario canceló
          // si falló el share (ej. iOS), seguimos al fallback de descarga
        }
      }

      // Fallback: descargar el PDF + abrir WhatsApp con el mensaje corto
      const url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      a.download = `comprobante-${payload.receipt_number}.pdf`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      setTimeout(() => URL.revokeObjectURL(url), 10_000)
      openWhatsAppText(shortText)
      toast.info("Descargamos el comprobante en PDF. Adjuntalo en el chat de WhatsApp que se abrió.")
    } catch {
      // Último recurso: solo el mensaje de texto por WhatsApp
      openWhatsAppText(shortText)
    } finally {
      setLoadingWa(false)
    }
  }, [op, receiptOpts, openWhatsAppText])

  return (
    <div className="flex items-center gap-1.5" onClick={(e) => e.stopPropagation()}>

      {/* ── Comprobante dropdown ─────────────────────────────────────────── */}
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
              : <FileText className="h-3.5 w-3.5" />}
            Comprobante
            <ChevronDown className="h-3 w-3 text-muted-foreground" />
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent
          align="end"
          className="w-48 bg-popover border-border"
          onClick={(e) => e.stopPropagation()}
        >
          <DropdownMenuItem
            className="gap-2 cursor-pointer"
            onSelect={handleDownload}
          >
            <FileText className="h-4 w-4 text-muted-foreground" />
            <span>Descargar / Imprimir</span>
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem
            className="gap-2 cursor-pointer"
            onSelect={handleCopy}
          >
            {copied
              ? <Check className="h-4 w-4 text-emerald-500" />
              : <Copy className="h-4 w-4 text-muted-foreground" />}
            <span>{copied ? "¡Copiado!" : "Copiar texto"}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* ── WhatsApp direct button ───────────────────────────────────────── */}
      <Button
        variant="outline"
        size="sm"
        onClick={handleWhatsApp}
        disabled={loadingWa}
        className={[
          "h-7 gap-1.5 text-xs px-2.5 transition-colors",
          hasValidPhone
            ? "border-[#25D366]/40 text-[#25D366] hover:bg-[#25D366]/10 hover:border-[#25D366]/60"
            : "border-border text-muted-foreground hover:text-foreground",
        ].join(" ")}
        title={
          hasValidPhone
            ? "Enviar comprobante por WhatsApp al cliente"
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
