"use client"

/**
 * SaleReceiptButton
 *
 * Renders a compact action group for a SaleOperation:
 *  - "Comprobante" → generates a self-contained HTML receipt, opens it in a
 *    new tab, and auto-triggers the browser's print/Save-as-PDF dialog.
 *  - "Compartir" → opens WhatsApp (or native Share API on mobile) with a
 *    pre-formatted text summary of the operation.
 *
 * Zero external PDF library — uses the browser's native print pipeline.
 */

import { useState, useCallback } from "react"
import { FileText, Share2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { toast } from "sonner"
import { useAuth } from "@/contexts/auth-context"
import { generateReceiptHTML, generateReceiptText } from "@/lib/receipt"
import type { SaleOperation } from "@/lib/group-operations"

interface SaleReceiptButtonProps {
  op: SaleOperation
}

export function SaleReceiptButton({ op }: SaleReceiptButtonProps) {
  const { user } = useAuth()
  const [loading, setLoading] = useState(false)

  // ── Receipt options derived from user profile ────────────────────────────
  const receiptOpts = {
    businessName:  user?.businessName || user?.name || "Mi Negocio",
    businessPhone: user?.phone,
    businessEmail: user?.email,
    logoUrl:       user?.avatar,
  }

  // ── Download / print ─────────────────────────────────────────────────────
  const handleDownload = useCallback(async () => {
    setLoading(true)
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
      setLoading(false)
    }
  }, [op, receiptOpts])

  // ── Share ────────────────────────────────────────────────────────────────
  const handleShare = useCallback(async () => {
    const text = generateReceiptText(op, receiptOpts)

    // Use native Web Share API if available (iOS Safari, Android Chrome)
    if (typeof navigator !== "undefined" && navigator.share) {
      try {
        await navigator.share({ title: "Comprobante de venta", text })
        return
      } catch {
        // User dismissed — fall through to WhatsApp
      }
    }

    // Desktop fallback: open WhatsApp web
    const encoded = encodeURIComponent(text)
    window.open(`https://wa.me/?text=${encoded}`, "_blank", "noopener,noreferrer")
  }, [op, receiptOpts])

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          className="h-7 gap-1.5 border-border text-foreground text-xs px-2.5"
          disabled={loading}
          onClick={(e) => e.stopPropagation()}
        >
          {loading
            ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
            : <FileText className="h-3.5 w-3.5" />}
          Comprobante
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
        <DropdownMenuItem
          className="gap-2 cursor-pointer"
          onSelect={handleShare}
        >
          <Share2 className="h-4 w-4 text-muted-foreground" />
          <span>Compartir</span>
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
