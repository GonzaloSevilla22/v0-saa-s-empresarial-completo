"use client"

import { createClient } from "@/lib/supabase/client"
// auth-hardening-jwt-cookies (Parte C, D1, task 19.8b).
import { getSessionUser } from "@/lib/auth/access-token-store"
import { InvoiceOcrError, type InvoiceDocument, type ParsedInvoice, type OcrStep } from "@/lib/invoice-types"

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

/** Lo mínimo que se lee de una Response: el status y el cuerpo en texto. */
interface ResponseLike {
  status: number
  text(): Promise<string>
}

function isResponseLike(value: unknown): value is ResponseLike {
  return (
    typeof value === "object" && value !== null &&
    typeof (value as { status?: unknown }).status === "number" &&
    typeof (value as { text?: unknown }).text === "function"
  )
}

/**
 * Busca la Response HTTP del error de `functions.invoke`. En functions-js el `context` de un
 * FunctionsHttpError ES la Response; se acepta también `context.response` (forma que el código
 * anterior asumía y que no existe en la versión instalada).
 */
function extractResponse(fnErr: unknown): ResponseLike | null {
  if (typeof fnErr !== "object" || fnErr === null) return null
  const ctx = (fnErr as { context?: unknown }).context
  if (isResponseLike(ctx)) return ctx
  if (typeof ctx === "object" && ctx !== null) {
    const nested = (ctx as { response?: unknown }).response
    if (isResponseLike(nested)) return nested
  }
  return null
}

const GENERIC_OCR_ERROR = "Error en el procesamiento IA"

/**
 * Traduce el error de `supabase.functions.invoke("invoice-ocr")` a un `InvoiceOcrError` tipado
 * (v31-ia-ratelimit-budget, D8). El código sale del `error` del cuerpo (`quota_exceeded`,
 * `rate_limited`, `quota_unavailable`) o del status 413; todo lo demás es `other` con el mensaje
 * del cuerpo.
 */
export async function toInvoiceOcrError(fnErr: unknown): Promise<InvoiceOcrError> {
  const res = extractResponse(fnErr)
  if (!res) {
    const message = fnErr instanceof Error && fnErr.message ? fnErr.message : GENERIC_OCR_ERROR
    return new InvoiceOcrError("other", message)
  }

  let raw = ""
  try { raw = await res.text() } catch { /* cuerpo ilegible: queda el mensaje genérico */ }

  let body: Record<string, unknown> | null = null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      body = parsed as Record<string, unknown>
    }
  } catch { /* no es JSON */ }

  const serverError = typeof body?.error === "string" ? body.error : null
  const message = serverError ?? (raw.trim() || GENERIC_OCR_ERROR)

  if (res.status === 429 && serverError === "quota_exceeded") {
    return new InvoiceOcrError("quota_exceeded", "Usaste todas las lecturas de factura de tu plan este mes", {
      resetAt: typeof body?.resetAt === "string" ? body.resetAt : null,
      used: typeof body?.used === "number" ? body.used : undefined,
      limit: typeof body?.limit === "number" ? body.limit : undefined,
    })
  }
  if (res.status === 429 && serverError === "rate_limited") {
    const retry = body?.retryAfterSeconds
    return new InvoiceOcrError("rate_limited", "Demasiadas lecturas seguidas", {
      retryAfterSeconds: typeof retry === "number" ? retry : undefined,
    })
  }
  if (res.status === 413) return new InvoiceOcrError("image_too_large", message)
  if (res.status === 503 && serverError === "quota_unavailable") {
    return new InvoiceOcrError("quota_unavailable", "No pudimos verificar tu cupo")
  }
  return new InvoiceOcrError("other", message)
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
    const user = await getSessionUser()
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
      throw await toInvoiceOcrError(fnErr)
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