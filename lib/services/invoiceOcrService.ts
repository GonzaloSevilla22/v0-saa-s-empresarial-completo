"use client"

import { createClient } from "@/lib/supabase/client"
import type { InvoiceDocument, ParsedInvoice, OcrStep } from "@/lib/invoice-types"

const BUCKET = "invoices"

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Compress an image File/Blob to a JPEG of at most maxDimension px,
 *  returning a new Blob. Reduces GPT-4o Vision costs and latency. */
async function compressImage(file: File, maxDimension = 2048, quality = 0.85): Promise<Blob> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    const url = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(url)
      let { width, height } = img
      if (width > maxDimension || height > maxDimension) {
        if (width >= height) {
          height = Math.round((height * maxDimension) / width)
          width  = maxDimension
        } else {
          width  = Math.round((width * maxDimension) / height)
          height = maxDimension
        }
      }
      const canvas = document.createElement("canvas")
      canvas.width  = width
      canvas.height = height
      const ctx = canvas.getContext("2d")!
      ctx.drawImage(img, 0, 0, width, height)
      canvas.toBlob(
        (blob) => {
          if (blob) resolve(blob)
          else reject(new Error("Canvas toBlob failed"))
        },
        "image/jpeg",
        quality,
      )
    }
    img.onerror = reject
    img.src     = url
  })
}

// ── Main service ──────────────────────────────────────────────────────────────

export const invoiceOcrService = {
  /**
   * Full pipeline:
   *   1. Compress image (client-side, max 2048px)
   *   2. Upload to storage
   *   3. Create invoice_documents row
   *   4. Call invoice-ocr Edge Function
   *   5. Return ParsedInvoice
   *
   * The `onStep` callback fires at each pipeline stage so the UI can
   * update the progress bar in real time.
   */
  async processInvoice(
    file: File,
    onStep: (step: OcrStep, progress: number, message?: string) => void,
  ): Promise<{ document_id: string; result: ParsedInvoice }> {
    const supabase = createClient()

    // ── 1. Auth check ─────────────────────────────────────────────────────────
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) throw new Error("No autorizado")

    // ── 2. Compress ───────────────────────────────────────────────────────────
    onStep("uploading", 10, "Comprimiendo imagen...")
    let uploadBlob: Blob = file
    if (file.type.startsWith("image/")) {
      try { uploadBlob = await compressImage(file) } catch (_) { /* use original */ }
    }

    // ── 3. Upload to storage ──────────────────────────────────────────────────
    onStep("uploading", 25, "Subiendo factura...")
    const ext = file.type.includes("pdf") ? "pdf" : "jpg"
    const uuid = crypto.randomUUID()
    const storagePath = `${user.id}/${uuid}.${ext}`

    const { error: uploadErr } = await supabase.storage
      .from(BUCKET)
      .upload(storagePath, uploadBlob, {
        contentType: file.type.startsWith("image/") ? "image/jpeg" : file.type,
        upsert: false,
      })
    if (uploadErr) throw new Error(`Error subiendo archivo: ${uploadErr.message}`)

    // ── 4. Create DB record ───────────────────────────────────────────────────
    onStep("uploading", 40, "Registrando documento...")
    const { data: docData, error: docErr } = await supabase
      .from("invoice_documents")
      .insert({
        user_id:        user.id,
        storage_path:   storagePath,
        original_name:  file.name,
        mime_type:      file.type.startsWith("image/") ? "image/jpeg" : file.type,
        file_size_bytes: uploadBlob.size,
        status:         "pending",
      })
      .select("id")
      .single()

    if (docErr || !docData) {
      // Clean up orphan storage object
      await supabase.storage.from(BUCKET).remove([storagePath])
      throw new Error(`Error creando registro: ${docErr?.message}`)
    }

    const documentId = docData.id

    // ── 5. Call Edge Function (OCR + AI extraction) ───────────────────────────
    onStep("processing", 55, "La IA está leyendo la factura...")
    const { data: fnData, error: fnErr } = await supabase.functions.invoke("invoice-ocr", {
      body: { document_id: documentId, storage_path: storagePath },
    })

    if (fnErr) {
      let msg = "Error en el procesamiento IA"
      try {
        const ctx = (fnErr as any).context
        if (ctx?.response) {
          const txt = await ctx.response.text()
          try { msg = JSON.parse(txt)?.error || msg } catch (_) { msg = txt }
        } else if (fnErr instanceof Error) {
          msg = fnErr.message
        }
      } catch (_) {}
      throw new Error(msg)
    }

    if (!fnData?.ok) {
      throw new Error(fnData?.error || "El procesamiento IA falló")
    }

    onStep("matching", 85, "Buscando productos...")
    return { document_id: documentId, result: fnData.result as ParsedInvoice }
  },

  /** Fetch a previously-processed invoice document. */
  async getDocument(documentId: string): Promise<InvoiceDocument | null> {
    const supabase = createClient()
    const { data } = await supabase
      .from("invoice_documents")
      .select("*")
      .eq("id", documentId)
      .single()
    return data as InvoiceDocument | null
  },

  /** Fetch recent invoice documents for the current user. */
  async listDocuments(limit = 20): Promise<InvoiceDocument[]> {
    const supabase = createClient()
    const { data } = await supabase
      .from("invoice_documents")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(limit)
    return (data ?? []) as InvoiceDocument[]
  },

  /** Save a product alias after user confirms a match (for future learning). */
  async saveAlias(productId: string, alias: string): Promise<void> {
    const supabase = createClient()
    await supabase
      .from("product_aliases")
      .upsert({ product_id: productId, alias: alias.toLowerCase().trim() }, {
        onConflict: "user_id,alias",
        ignoreDuplicates: true,
      })
  },

  /** Fetch all aliases for the current user. */
  async getAliases(): Promise<{ alias: string; product_id: string }[]> {
    const supabase = createClient()
    const { data } = await supabase
      .from("product_aliases")
      .select("alias, product_id")
    return (data ?? []) as { alias: string; product_id: string }[]
  },

  /** Mark an invoice document as confirmed with a purchase operation. */
  async markConfirmed(documentId: string, operationId: string): Promise<void> {
    const supabase = createClient()
    await supabase
      .from("invoice_documents")
      .update({ purchase_operation_id: operationId })
      .eq("id", documentId)
  },

  /** Delete storage file + DB record (when user cancels / retries). */
  async deleteDocument(documentId: string, storagePath: string): Promise<void> {
    const supabase = createClient()
    await Promise.all([
      supabase.storage.from(BUCKET).remove([storagePath]),
      supabase.from("invoice_documents").delete().eq("id", documentId),
    ])
  },
}