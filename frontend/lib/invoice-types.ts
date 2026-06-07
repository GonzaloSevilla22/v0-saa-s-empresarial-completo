/**
 * Type definitions for the AI Invoice OCR system.
 * These are shared between the Edge Function response, the client matcher,
 * and the review UI components.
 */

// ── Raw extraction from GPT-4o ────────────────────────────────────────────────

export interface InvoiceSupplierRaw {
  name:         string | null
  cuit:         string | null
  address:      string | null
  invoice_type: "A" | "B" | "C" | "otro" | null
}

export interface InvoiceHeaderRaw {
  number:   string | null
  date:     string | null   // YYYY-MM-DD
  currency: "ARS" | "USD" | "EUR" | null
}

export interface InvoiceTotalsRaw {
  subtotal:    number | null
  vat_amount:  number | null
  vat_rate:    number | null
  other_taxes: number | null
  discount:    number | null
  total:       number | null
}

export interface InvoiceLineRaw {
  raw_description: string
  description:     string
  quantity:        number
  unit:            string | null
  unit_price:      number | null
  discount_pct:    number | null
  subtotal:        number | null
}

/** Structured response from the invoice-ocr Edge Function. */
export interface ParsedInvoice {
  supplier:   InvoiceSupplierRaw
  invoice:    InvoiceHeaderRaw
  totals:     InvoiceTotalsRaw
  items:      InvoiceLineRaw[]
  confidence: number           // 0–1
  warnings:   string[]
}

// ── Client-side product matching ──────────────────────────────────────────────

export type MatchType = "exact_barcode" | "exact_name" | "high" | "partial" | "alias" | "none"

export interface ProductMatch {
  type:         MatchType
  product_id:   string | null
  product_name: string | null
  unit_id:      string | null
  unit_symbol:  string | null
  confidence:   number         // 0–1
}

/** A raw invoice line enriched with the client-side product match. */
export interface MatchedInvoiceLine extends InvoiceLineRaw {
  /** Auto-detected unit_id from units_of_measure table. */
  detected_unit_id:   string | null
  detected_unit_name: string | null
  /** Best product match found in the ERP catalog. */
  match: ProductMatch
  // ── User-editable fields (pre-filled from OCR, editable in review modal)
  confirmed_product_id:   string | null
  confirmed_product_name: string
  confirmed_quantity:     number
  confirmed_unit_price:   number
  confirmed_unit_id:      string | null
  confirmed_unit_symbol:  string | null
  included:               boolean      // user can exclude individual lines
  is_new_product:         boolean      // no match found; needs creation
}

// ── Invoice document DB record ─────────────────────────────────────────────────

export type InvoiceStatus = "pending" | "processing" | "completed" | "failed"

export interface InvoiceDocument {
  id:                   string
  user_id:              string
  storage_path:         string
  original_name:        string | null
  mime_type:            string | null
  file_size_bytes:      number | null
  status:               InvoiceStatus
  error_message:        string | null
  processing_ms:        number | null
  ai_model:             string | null
  ai_confidence:        number | null
  ai_warnings:          string[]
  supplier_name:        string | null
  supplier_cuit:        string | null
  invoice_number:       string | null
  invoice_date:         string | null
  invoice_type:         string | null
  invoice_currency:     string | null
  invoice_total:        number | null
  parsed_items:         InvoiceLineRaw[]
  purchase_operation_id: string | null
  created_at:           string
}

// ── UI state ───────────────────────────────────────────────────────────────────

export type OcrStep =
  | "idle"
  | "uploading"
  | "processing"
  | "matching"
  | "review"
  | "confirming"
  | "done"
  | "error"

export interface OcrSessionState {
  step:         OcrStep
  document_id:  string | null
  storage_path: string | null
  parsed:       ParsedInvoice | null
  matched:      MatchedInvoiceLine[]
  error:        string | null
  progress:     number          // 0–100 for progress bar
}