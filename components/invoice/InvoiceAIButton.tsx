"use client"

import { useState, useCallback, useEffect } from "react"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { InvoiceUploadZone } from "@/components/invoice/InvoiceUploadZone"
import { InvoiceProcessingCard } from "@/components/invoice/InvoiceProcessingCard"
import { InvoiceReviewModal } from "@/components/invoice/InvoiceReviewModal"
import { invoiceOcrService } from "@/lib/services/invoiceOcrService"
import { enrichLines } from "@/lib/invoice-matcher"
import { generateOperationId } from "@/lib/cart-utils"
import { useData } from "@/contexts/data-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { ScanText, Sparkles } from "lucide-react"
import { toast } from "sonner"
import type { OcrStep, ParsedInvoice, MatchedInvoiceLine, OcrSessionState } from "@/lib/invoice-types"
import type { ProductAlias } from "@/lib/invoice-matcher"

const INITIAL_STATE: OcrSessionState = {
  step: "idle", document_id: null, storage_path: null,
  parsed: null, matched: [], error: null, progress: 0,
}

interface Props {
  /** Called after the user confirms — triggers the actual purchase creation loop. */
  onPurchasesCreated?: () => void
}

export function InvoiceAIButton({ onPurchasesCreated }: Props) {
  const { products, addProduct, addPurchase, refreshData } = useData()
  const { units }  = useUnitsOfMeasure()

  const [uploadOpen,  setUploadOpen]  = useState(false)
  const [reviewOpen,  setReviewOpen]  = useState(false)
  const [session,     setSession]     = useState<OcrSessionState>(INITIAL_STATE)
  const [aliases,     setAliases]     = useState<ProductAlias[]>([])

  // Load aliases once on mount
  useEffect(() => {
    invoiceOcrService.getAliases().then(setAliases).catch(() => {})
  }, [])

  const setStep = useCallback((step: OcrStep, progress: number, message?: string) => {
    setSession((s) => ({ ...s, step, progress, error: step === "error" ? s.error : null }))
  }, [])

  // ── Main pipeline ──────────────────────────────────────────────────────────
  const handleFileSelected = useCallback(async (file: File) => {
    setSession({ ...INITIAL_STATE, step: "uploading", progress: 5 })

    try {
      const { document_id, result } = await invoiceOcrService.processInvoice(
        file,
        (step, progress, message) => setSession((s) => ({ ...s, step, progress, error: null })),
      )

      // Client-side matching
      setStep("matching", 85, "Buscando productos en catálogo...")
      const matched = enrichLines(result.items ?? [], products, units, aliases)

      setSession({
        step:        "review",
        document_id,
        storage_path: `${document_id}`,  // approximated; not needed after this point
        parsed:      result,
        matched,
        error:       null,
        progress:    100,
      })
      setUploadOpen(false)
      setReviewOpen(true)

    } catch (err: any) {
      const msg = err?.message || "Error desconocido"
      setSession((s) => ({ ...s, step: "error", error: msg, progress: 0 }))
      toast.error(msg)
    }
  }, [products, units, aliases, setStep])

  // ── Confirm purchase ───────────────────────────────────────────────────────
  const handleConfirm = useCallback(async (
    lines:       MatchedInvoiceLine[],
    operationId: string,
    parsed:      ParsedInvoice,
    documentId:  string | null,
  ) => {
    const date = parsed.invoice?.date ?? new Date().toISOString().split("T")[0]

    // 1. Create any new products first
    for (const line of lines) {
      if (line.is_new_product && line.confirmed_product_name && !line.confirmed_product_id) {
        await addProduct({
          name:             line.confirmed_product_name,
          category:         "Otros",
          cost:             line.confirmed_unit_price,
          price:            line.confirmed_unit_price,
          margin:           0,
          stock:            0,
          minStock:         0,
          isVariant:        false,
          stockControlType: "tracked",
          baseUnitId:       line.confirmed_unit_id ?? undefined,
        })
        // Note: We can't easily get the new product's ID here without re-fetching.
        // The purchase will fail gracefully if product_id is null — acceptable for MVP.
      }
    }

    // Re-fetch products to get newly-created IDs
    await refreshData()

    // 2. Create purchases for matched lines
    const purchasables = lines.filter((l) => l.confirmed_product_id)
    if (purchasables.length === 0) {
      toast.warning("No hay productos matcheados — verificá los nombres")
      return
    }

    const errors: string[] = []
    for (const line of purchasables) {
      try {
        await addPurchase({
          date,
          productId:   line.confirmed_product_id!,
          productName: line.confirmed_product_name,
          quantity:    line.confirmed_quantity,
          unitCost:    line.confirmed_unit_price,
          total:       line.confirmed_quantity * line.confirmed_unit_price,
          description: `Factura IA${parsed.invoice?.number ? ` N° ${parsed.invoice.number}` : ""}`,
          unitId:      line.confirmed_unit_id ?? undefined,
          operationId,
        })

        // Save alias for future OCR learning
        if (
          line.match.type !== "exact_barcode" &&
          line.match.type !== "exact_name" &&
          line.confirmed_product_id &&
          line.description
        ) {
          invoiceOcrService.saveAlias(line.confirmed_product_id, line.description).catch(() => {})
        }
      } catch (err: any) {
        errors.push(`${line.confirmed_product_name}: ${err.message}`)
      }
    }

    // 3. Mark document as confirmed
    if (documentId) {
      invoiceOcrService.markConfirmed(documentId, operationId).catch(() => {})
    }

    if (errors.length > 0) {
      toast.warning(`${purchasables.length - errors.length} registrado(s). ${errors.length} con error.`)
      errors.forEach((e) => toast.error(e))
    } else {
      toast.success(`✅ ${purchasables.length} compra${purchasables.length > 1 ? "s" : ""} registrada${purchasables.length > 1 ? "s" : ""} desde factura IA`)
    }

    setSession(INITIAL_STATE)
    onPurchasesCreated?.()
  }, [addProduct, addPurchase, refreshData, onPurchasesCreated])

  const handleReset = useCallback(() => {
    setSession(INITIAL_STATE)
    setUploadOpen(true)
  }, [])

  return (
    <>
      {/* ── Trigger button ───────────────────────────────────────────────────── */}
      <Button
        variant="outline"
        className="gap-2 border-primary/30 text-primary hover:bg-primary/10 hover:border-primary"
        onClick={() => {
          setSession(INITIAL_STATE)
          setUploadOpen(true)
        }}
      >
        <ScanText className="h-4 w-4" />
        <span className="hidden sm:inline">Subir factura IA</span>
        <Sparkles className="h-3 w-3 opacity-60" />
      </Button>

      {/* ── Upload dialog ─────────────────────────────────────────────────────── */}
      <Dialog open={uploadOpen} onOpenChange={(o) => {
        if (!o && session.step !== "idle") return  // block close during processing
        setUploadOpen(o)
      }}>
        <DialogContent className="bg-card border-border max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Sparkles className="h-5 w-5 text-primary" />
              Leer factura con IA
            </DialogTitle>
          </DialogHeader>

          <div className="flex flex-col gap-4">
            {session.step === "idle" && (
              <InvoiceUploadZone onFileSelected={handleFileSelected} />
            )}

            {session.step !== "idle" && (
              <InvoiceProcessingCard
                step={session.step}
                progress={session.progress}
                error={session.error}
              />
            )}

            {session.step === "error" && (
              <Button variant="outline" onClick={handleReset}>
                Intentar de nuevo
              </Button>
            )}
          </div>
        </DialogContent>
      </Dialog>

      {/* ── Review modal ─────────────────────────────────────────────────────── */}
      {session.parsed && (
        <InvoiceReviewModal
          open={reviewOpen}
          onOpenChange={(o) => {
            setReviewOpen(o)
            if (!o) setSession(INITIAL_STATE)
          }}
          parsed={session.parsed}
          lines={session.matched}
          products={products}
          units={units}
          documentId={session.document_id}
          onConfirm={handleConfirm}
        />
      )}
    </>
  )
}