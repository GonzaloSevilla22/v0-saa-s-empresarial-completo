/**
 * Parser de extracto bancario (bank-reconciliation C3, design D2).
 *
 * El parseo vive en el CLIENTE: el backend recibe filas NORMALIZADAS
 * ({ line_no, value_date, description, amount, balance? }) — sin dependencias
 * de parsing en Render. Formato de entrada V1: CSV (los home bankings exportan
 * CSV; un Excel se guarda como CSV antes de subir — la UI lo documenta).
 *
 * Heurística de columnas por alias (es-AR + en), separador `;`/`,` autodetectado,
 * BOM UTF-8, fechas dd/mm/yyyy · dd-mm-yyyy · yyyy-mm-dd, montos formato
 * argentino ("1.234,56") o plano ("1234.56").
 *
 * candidatos-importadores (2026-09-09): el importe y el saldo se leen con el
 * helper canónico `parseAmountString` de `lib/excel.ts` (RN-D4: string, nunca
 * float) — antes era una copia local. Contrato preservado (comparación
 * decimal siempre; "-"/paréntesis para negativos), sumando lo que faltaba:
 * - una línea con importe ilegible o vacío se DESCARTA individualmente (no
 *   aborta el resto del archivo) y queda en `discarded` con motivo;
 * - un importe o saldo ambiguo por punto de miles ("1.500") avisa en
 *   `warnings` de la línea, igual que los importadores de productos/gastos
 *   (`amountAmbiguityWarning`) — antes no avisaba nada;
 * - un saldo ilegible (columna opcional) NO descarta la línea: queda `null`
 *   con un warning explícito, en vez de convertirse en `null` en silencio.
 *
 * Revisión adversarial (2026-09-09) sobre el fix de arriba — F1..F12, ver
 * `CHANGES.md`/design del change: char-guard en `parseAmountString` (F1
 * blocker + F2 major), `source_row` en la línea (F5), motivo agregado
 * cuando TODAS las filas se descartan (F4), aviso de ambigüedad también por
 * coma en el dominio bancario (F6), fecha inválida descarta sólo esa fila en
 * vez de abortar el archivo (F8), valores crudos acotados en los motivos
 * (F11).
 */

import { amountAmbiguityWarning, parseAmountString } from "@/lib/excel"

export interface NormalizedStatementLine {
  line_no: number
  value_date: string // ISO yyyy-mm-dd
  description: string | null
  amount: string // decimal como string (sin float — RN-D4)
  balance: string | null
  /** Ambigüedades no bloqueantes (importe/saldo con punto de miles, saldo ilegible). */
  warnings: string[]
  /**
   * F5: fila física del archivo (1 = encabezado), MISMA convención que
   * `DiscardedStatementLine.row` — antes la UI numeraba los avisos con
   * `line_no` (índice entre líneas válidas, se renumera tras cada descarte)
   * y los descartes con la fila física, dos numeraciones distintas
   * conviviendo en el mismo panel. El hook NO manda este campo al backend
   * (F10) — es sólo para que la UI cite la fila real del archivo.
   */
  source_row: number
}

/** Fila del archivo que no pudo normalizarse — se omite del import, no aborta el resto. */
export interface DiscardedStatementLine {
  /** Número de fila del archivo (1 = encabezado), igual convención que los mensajes de error existentes. */
  row: number
  reason: string
}

export type BankStatementParseResult =
  | { ok: true; lines: NormalizedStatementLine[]; discarded: DiscardedStatementLine[] }
  | { ok: false; error: string }

/** Opciones de `parseAmountString` para el dominio del extracto bancario: coma
 *  siempre decimal (convención AR de bancos, nunca miles) y paréntesis-negativo
 *  (convención contable, ya soportada por la implementación local anterior). */
const BANK_AMOUNT_OPTIONS = { loneCommaIsDecimal: true, parenthesesNegative: true } as const

const DATE_ALIASES = ["fecha valor", "fecha", "fecha operacion", "fecha operación", "fecha mov", "date"]
const DESC_ALIASES = ["descripcion", "descripción", "concepto", "detalle", "referencia", "movimiento", "description"]
const AMOUNT_ALIASES = ["importe", "monto", "amount", "importe ($)", "debito/credito", "débito/crédito"]
const BALANCE_ALIASES = ["saldo", "balance", "saldo ($)"]

export const MAX_STATEMENT_LINES = 5000

// ── Parseo ─────────────────────────────────────────────────────────────────────

export function parseBankStatementText(text: string): BankStatementParseResult {
  const clean = text.replace(/^﻿/, "")
  const rawLines = clean.split(/\r?\n/).filter((l) => l.trim() !== "")

  if (rawLines.length < 2) {
    return { ok: false, error: "El archivo no contiene datos (mínimo: encabezado + 1 fila)." }
  }

  const sep = rawLines[0].includes(";") ? ";" : ","
  const headers = splitCsvLine(rawLines[0], sep).map((h) => h.toLowerCase().trim())

  const dateIdx = findColumn(headers, DATE_ALIASES)
  const amountIdx = findColumn(headers, AMOUNT_ALIASES)
  const descIdx = findColumn(headers, DESC_ALIASES)
  const balanceIdx = findColumn(headers, BALANCE_ALIASES)

  if (dateIdx < 0 || amountIdx < 0) {
    return {
      ok: false,
      error:
        "No se reconocieron las columnas del extracto. Se esperan encabezados de " +
        "fecha (Fecha / Fecha valor) e importe (Importe / Monto); descripción y saldo son opcionales.",
    }
  }

  const lines: NormalizedStatementLine[] = []
  const discarded: DiscardedStatementLine[] = []
  for (let i = 1; i < rawLines.length; i++) {
    const cells = splitCsvLine(rawLines[i], sep)
    const rawDate = (cells[dateIdx] ?? "").trim()
    const rawAmount = (cells[amountIdx] ?? "").trim()
    if (rawDate === "" && rawAmount === "") continue // fila decorativa/vacía

    // F8: una fecha inválida ya NO aborta el archivo completo — se descarta
    // esta fila puntual por el MISMO canal que un importe ilegible (motivo
    // registrado en `discarded`) y se sigue con el resto, en vez de que un
    // solo error de tipeo tire abajo todo el import.
    const valueDate = parseDate(rawDate)
    if (!valueDate) {
      discarded.push({ row: i + 1, reason: `Fecha inválida: "${truncateRaw(rawDate)}".` })
      continue
    }

    // Importe: campo obligatorio para poder registrar el movimiento. Ilegible
    // o vacío → se DESCARTA esta fila puntual (motivo en `discarded`) y se
    // sigue con el resto del archivo, en vez de abortar el import completo.
    const amount = parseAmountString(rawAmount, BANK_AMOUNT_OPTIONS)
    if (amount === null) {
      discarded.push({
        row: i + 1,
        reason:
          rawAmount === ""
            ? "Importe vacío — no se puede registrar un movimiento sin importe."
            : `Importe ilegible: "${truncateRaw(rawAmount)}" — no se puede registrar un movimiento sin importe.`,
      })
      continue
    }

    const warnings: string[] = []
    // F6: separator "any" — el dominio bancario lee con loneCommaIsDecimal
    // (la coma SIEMPRE es decimal acá), así que una coma con grupos de tres
    // dígitos ("1,500") es igual de ambigua que un punto ("1.500"); el
    // default de `amountAmbiguityWarning` (sólo punto) es para importes que
    // NO usan esa opción (precio/costo/monto de gasto).
    const amountAmbiguity = amountAmbiguityWarning("Importe", rawAmount, Number(amount), "any")
    if (amountAmbiguity) warnings.push(amountAmbiguity)

    // Saldo: campo opcional/informativo. Ilegible → NO descarta la fila (el
    // importe ya es válido): queda `null` con un warning explícito, en vez
    // de indistinguible de "no vino saldo".
    const balanceRaw = balanceIdx >= 0 ? (cells[balanceIdx] ?? "").trim() : ""
    let balance: string | null = null
    if (balanceRaw !== "") {
      const parsedBalance = parseAmountString(balanceRaw, BANK_AMOUNT_OPTIONS)
      if (parsedBalance === null) {
        warnings.push(
          `Saldo ilegible: "${truncateRaw(balanceRaw)}" — se ignora (no bloquea la fila; el saldo es informativo).`,
        )
      } else {
        balance = parsedBalance
        const balanceAmbiguity = amountAmbiguityWarning("Saldo", balanceRaw, Number(parsedBalance), "any")
        if (balanceAmbiguity) warnings.push(balanceAmbiguity)
      }
    }

    lines.push({
      line_no: lines.length + 1,
      value_date: valueDate,
      description: descIdx >= 0 ? (cells[descIdx] ?? "").trim() || null : null,
      amount,
      balance,
      warnings,
      source_row: i + 1,
    })

    if (lines.length > MAX_STATEMENT_LINES) {
      return { ok: false, error: `El extracto supera el máximo de ${MAX_STATEMENT_LINES} líneas por import.` }
    }
  }

  if (lines.length === 0) {
    // F4: si TODAS las filas se descartaron (en vez de simplemente no haber
    // datos), el mensaje genérico por sí solo esconde la causa — se agrega
    // el conteo y el motivo de las primeras filas descartadas.
    if (discarded.length > 0) {
      const preview = discarded
        .slice(0, 3)
        .map((d) => `fila ${d.row} (${d.reason})`)
        .join(", ")
      const more = discarded.length > 3 ? `, … (${discarded.length} en total)` : ""
      return {
        ok: false,
        error:
          `El archivo no contiene filas de movimientos válidas: ${discarded.length} ` +
          `fila${discarded.length !== 1 ? "s" : ""} descartada${discarded.length !== 1 ? "s" : ""}: ${preview}${more}.`,
      }
    }
    return { ok: false, error: "El archivo no contiene filas de movimientos válidas." }
  }

  return { ok: true, lines, discarded }
}

export async function parseBankStatementFile(file: File): Promise<BankStatementParseResult> {
  try {
    const text = await file.text()
    return parseBankStatementText(text)
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "No se pudo leer el archivo." }
  }
}

/** SHA-256 hex del contenido del archivo — dedupe de dominio del import (D2). */
export async function hashFileSHA256(file: File): Promise<string> {
  const buffer = await file.arrayBuffer()
  const digest = await crypto.subtle.digest("SHA-256", buffer)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * F11 (nit, revisor adversarial): acota un valor crudo antes de embeberlo en
 * un motivo de descarte/aviso — una celda con basura larga (o un archivo mal
 * delimitado que arrastra columnas enteras a una celda) no debe inflar el
 * mensaje de error sin límite.
 */
function truncateRaw(raw: string): string {
  return raw.length > 40 ? `${raw.slice(0, 40)}…` : raw
}

function findColumn(headers: string[], aliases: string[]): number {
  for (const alias of aliases) {
    const idx = headers.findIndex((h) => h === alias || h.startsWith(alias))
    if (idx >= 0) return idx
  }
  return -1
}

/** Split CSV respetando comillas dobles. */
function splitCsvLine(line: string, sep: string): string[] {
  const cells: string[] = []
  let current = ""
  let inQuotes = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"'
        i++
      } else {
        inQuotes = !inQuotes
      }
    } else if (ch === sep && !inQuotes) {
      cells.push(current)
      current = ""
    } else {
      current += ch
    }
  }
  cells.push(current)
  return cells
}

/** dd/mm/yyyy · dd-mm-yyyy · yyyy-mm-dd → ISO yyyy-mm-dd (o null). */
export function parseDate(raw: string): string | null {
  const iso = raw.match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (iso) {
    return isValidDate(+iso[1], +iso[2], +iso[3]) ? raw : null
  }
  const arg = raw.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/)
  if (arg) {
    const [, d, m, y] = arg
    if (!isValidDate(+y, +m, +d)) return null
    return `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`
  }
  return null
}

function isValidDate(y: number, m: number, d: number): boolean {
  if (m < 1 || m > 12 || d < 1 || d > 31) return false
  const date = new Date(Date.UTC(y, m - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d
}

/**
 * "1.234,56" (AR) · "1234.56" · "-350" · "$ -1.234,56" · "(1.234,56)" → decimal
 * string (o null). Nunca float: se devuelve string para que el backend lo
 * tome como NUMERIC (RN-D4). Wrapper sobre el helper canónico
 * `parseAmountString` de `lib/excel.ts` (candidatos-importadores,
 * 2026-09-09) con las mismas opciones que usa el parseo de líneas de arriba
 * — se mantiene exportado con esta firma de un solo argumento por
 * compatibilidad con los callers existentes (tests, otros módulos).
 */
export function parseAmount(raw: string): string | null {
  return parseAmountString(raw, BANK_AMOUNT_OPTIONS)
}
