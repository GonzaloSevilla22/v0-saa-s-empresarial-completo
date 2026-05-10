/**
 * Barcode utility functions — EAN-13, UPC-A, EAN-8 checksum validation
 * and helper generators/normalizers.
 */

// ── Validation ────────────────────────────────────────────────────────────────

/**
 * Validates an EAN-13 barcode (13 digits).
 * Digits 1-12 weighted alternating 1/3; digit 13 is the check digit.
 */
export function validateEAN13(code: string): boolean {
  if (!/^\d{13}$/.test(code)) return false
  const digits = code.split("").map(Number)
  const sum = digits
    .slice(0, 12)
    .reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 1 : 3), 0)
  const check = (10 - (sum % 10)) % 10
  return check === digits[12]
}

/**
 * Validates a UPC-A barcode (12 digits).
 */
export function validateUPCA(code: string): boolean {
  if (!/^\d{12}$/.test(code)) return false
  const digits = code.split("").map(Number)
  const sum = digits
    .slice(0, 11)
    .reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 3 : 1), 0)
  const check = (10 - (sum % 10)) % 10
  return check === digits[11]
}

/**
 * Validates an EAN-8 barcode (8 digits).
 */
export function validateEAN8(code: string): boolean {
  if (!/^\d{8}$/.test(code)) return false
  const digits = code.split("").map(Number)
  const sum = digits
    .slice(0, 7)
    .reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 3 : 1), 0)
  const check = (10 - (sum % 10)) % 10
  return check === digits[7]
}

// ── Format detection ──────────────────────────────────────────────────────────

export type BarcodeFormat = "EAN13" | "UPC-A" | "EAN8" | "CODE128" | "unknown"

/**
 * Detects the format of a scanned barcode string.
 * CODE128 is a catch-all for alphanumeric codes without a defined checksum.
 */
export function detectBarcodeFormat(code: string): BarcodeFormat {
  if (validateEAN13(code)) return "EAN13"
  if (validateUPCA(code)) return "UPC-A"
  if (validateEAN8(code)) return "EAN8"
  if (/^[A-Za-z0-9\-_.]+$/.test(code) && code.length >= 4) return "CODE128"
  return "unknown"
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Normalizes a raw scanned string: trims whitespace and uppercases letters.
 */
export function normalizeBarcode(raw: string): string {
  return raw.trim().toUpperCase()
}

/**
 * Generates a random, checksum-valid EAN-13 code.
 */
export function generateEAN13(): string {
  const base = Array.from({ length: 12 }, () => Math.floor(Math.random() * 10))
  const sum = base.reduce((acc, d, i) => acc + d * (i % 2 === 0 ? 1 : 3), 0)
  const check = (10 - (sum % 10)) % 10
  return [...base, check].join("")
}