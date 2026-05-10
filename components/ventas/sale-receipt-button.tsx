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
import { generateReceiptHTML, generateReceiptText } from "@/lib/receipt"
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

  // ── Send via WhatsApp ────────────────────────────────────────────────────
  const handleWhatsApp = useCallback(() => {
    const text = generateReceiptText(op, receiptOpts)
    const url  = buildWhatsAppUrl(clientPhone, text)
    window.open(url, "_blank", "noopener,noreferrer")

    if (!hasValidPhone) {
      toast.info(
        "No hay número de WhatsApp registrado para este cliente. Seleccioná el contacto en WhatsApp.",
        { duration: 4000 },
      )
    }
  }, [op, receiptOpts, clientPhone, hasValidPhone])

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
        <MessageCircle className="h-3.5 w-3.5" />
        {hasValidPhone ? "Enviar por WhatsApp" : "WhatsApp"}
      </Button>
    </div>
  )
}
