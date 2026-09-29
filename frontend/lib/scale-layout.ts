/**
 * lib/scale-layout.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * balanza-etiquetas-pos (D3/D4) — tipos, validación y utilidades de PRESENTACIÓN
 * de la configuración de formatos de código de barras de la balanza.
 *
 * Pura — sin React, sin fetch. El esquema zod de acá es la MISMA definición
 * (D4) que valida el backend (`backend/schemas/scale_settings.py`), verificada
 * contra el mismo conjunto de casos compartido
 * (`backend/tests/fixtures/scale_layout_cases.json`) por `scale-layout.test.ts`.
 */

import { z } from "zod"

// ─── Tipos ──────────────────────────────────────────────────────────────────

export type ScaleField = "fixed" | "plu" | "amount" | "quantity" | "ignored"

export interface ScaleSegment {
  field: ScaleField
  digits: number
  /** Sólo para `field: "fixed"` — el valor literal del campo (p. ej. "20"). */
  value?: string
  /** Sólo para el campo de valor (`amount`/`quantity`). Default 0. */
  decimals?: number
}

export interface ScaleLayout {
  kind: "weighed" | "unit" | "multi"
  enabled: boolean
  segments: ScaleSegment[]
}

/** [weighed, unit, multi] — siempre los tres, en ese orden (D3). */
export type ScaleLayoutTuple = [ScaleLayout, ScaleLayout, ScaleLayout]

export interface ScaleSettings {
  enabled: boolean
  layouts: ScaleLayoutTuple
}

// ─── Valores de fábrica (D3, manual págs. 134-135) ───────────────────────────

/**
 * Formatos de fábrica de la Systel Cuora Neo. `enabled: false` a nivel
 * cuenta (D3: "una cuenta sin fila SHALL comportarse como balanza
 * deshabilitada"), pero los TRES formatos nacen `enabled: true` — así el
 * probador de la pestaña Balanza puede decodificar contra ellos aunque la
 * lectura global esté apagada (D11: `{ ...editing, enabled: true }`), y una
 * etiqueta "Varios" de fábrica resuelve a `unsupported/multi_item` en vez de
 * `no_layout_match`.
 */
export const FACTORY_SCALE_SETTINGS: ScaleSettings = {
  enabled: false,
  layouts: [
    {
      kind: "weighed",
      enabled: true,
      segments: [
        { field: "fixed", digits: 2, value: "20" },
        { field: "plu", digits: 4 },
        { field: "amount", digits: 6, decimals: 2 },
      ],
    },
    {
      kind: "unit",
      enabled: true,
      segments: [
        { field: "fixed", digits: 2, value: "21" },
        { field: "plu", digits: 4 },
        { field: "amount", digits: 6, decimals: 2 },
      ],
    },
    {
      kind: "multi",
      enabled: true,
      segments: [
        { field: "fixed", digits: 2, value: "22" },
        { field: "ignored", digits: 2 },
        { field: "ignored", digits: 8 },
      ],
    },
  ],
}

// ─── Esquema zod (D4) ─────────────────────────────────────────────────────────

const scaleFieldSchema = z.enum(["fixed", "plu", "amount", "quantity", "ignored"])

const scaleSegmentSchema = z.object({
  field: scaleFieldSchema,
  digits: z.number().int().min(0),
  value: z.string().optional(),
  decimals: z.number().int().optional(),
})

const scaleLayoutSchema = z.object({
  kind: z.enum(["weighed", "unit", "multi"]),
  enabled: z.boolean(),
  segments: z.array(scaleSegmentSchema),
})

/**
 * Código descriptivo interno (no forma parte del contrato — sólo el booleano
 * `valid` importa entre frontend y backend, nota del fixture compartido).
 */
export type ScaleLayoutErrorCode =
  | "segments_count_invalid"
  | "digits_sum_not_12"
  | "field_a_not_fixed"
  | "header_length_invalid"
  | "header_not_starting_with_2"
  | "plu_missing"
  | "plu_digits_out_of_range"
  | "value_field_count_invalid"
  | "decimals_out_of_range"
  | "unit_quantity_decimals_invalid"
  | "header_prefix_conflict"

/**
 * Reglas D4 para UN formato HABILITADO. Un formato deshabilitado no se
 * valida (regla explícita: "El sistema SHALL aceptar un formato HABILITADO
 * sólo si...") — lo verifica `disabled_layout_with_invalid_segments_is_valid_overall`.
 */
function validateEnabledLayout(layout: ScaleLayout): ScaleLayoutErrorCode | null {
  const segs = layout.segments

  if (segs.length < 1 || segs.length > 4) return "segments_count_invalid"

  const digitsSum = segs.reduce((sum, s) => sum + s.digits, 0)
  if (digitsSum !== 12) return "digits_sum_not_12"

  const fieldA = segs[0]
  if (fieldA.field !== "fixed") return "field_a_not_fixed"
  if (!fieldA.value || fieldA.value.length < 1 || fieldA.value.length > 3 || fieldA.value.length !== fieldA.digits) {
    return "header_length_invalid"
  }
  if (!fieldA.value.startsWith("2")) return "header_not_starting_with_2"

  // "un campo plu con 0 dígitos ... se trata como PLU ausente" (nota del fixture)
  const pluSegs = segs.filter((s) => s.field === "plu" && s.digits > 0)
  const valueSegs = segs.filter((s) => (s.field === "amount" || s.field === "quantity") && s.digits > 0)

  if (layout.kind === "multi") {
    // "el formato de varios no tiene código PLU y sólo se le exige la cabecera"
    if (pluSegs.length > 0) return "plu_missing"
    return null
  }

  // weighed / unit: exactamente un PLU (1-6 dígitos) y exactamente un valor
  if (pluSegs.length !== 1) return "plu_missing"
  if (pluSegs[0].digits < 1 || pluSegs[0].digits > 6) return "plu_digits_out_of_range"
  if (valueSegs.length !== 1) return "value_field_count_invalid"

  const valueSeg = valueSegs[0]
  const decimals = valueSeg.decimals ?? 0
  if (decimals < 0 || decimals > 3) return "decimals_out_of_range"
  // "un campo de cantidad del formato por unidad tiene 0 decimales"
  if (layout.kind === "unit" && valueSeg.field === "quantity" && decimals !== 0) {
    return "unit_quantity_decimals_invalid"
  }

  return null
}

/** El campo A (número fijo) de un formato — `undefined` si no es válido como tal. */
function headerOf(layout: ScaleLayout): string | undefined {
  const a = layout.segments[0]
  if (!a || a.field !== "fixed" || !a.value) return undefined
  return a.value
}

export const scaleSettingsSchema = z
  .object({
    enabled: z.boolean(),
    layouts: z.tuple([scaleLayoutSchema, scaleLayoutSchema, scaleLayoutSchema]),
  })
  .superRefine((settings, ctx) => {
    const enabledHeaders: string[] = []

    settings.layouts.forEach((layout, index) => {
      if (!layout.enabled) return
      const error = validateEnabledLayout(layout as ScaleLayout)
      if (error) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["layouts", index],
          message: error,
        })
        return
      }
      const header = headerOf(layout as ScaleLayout)
      if (header) enabledHeaders.push(header)
    })

    // Regla 5: "ninguna cabecera de un formato habilitado es prefijo de la
    // cabecera de otro formato habilitado" (en cualquiera de los dos sentidos).
    for (let i = 0; i < enabledHeaders.length; i++) {
      for (let j = 0; j < enabledHeaders.length; j++) {
        if (i === j) continue
        if (enabledHeaders[j].startsWith(enabledHeaders[i])) {
          ctx.addIssue({
            code: z.ZodIssueCode.custom,
            path: ["layouts"],
            message: "header_prefix_conflict",
          })
          return
        }
      }
    }
  })

/** Valida una configuración completa contra las reglas D4. */
export function isValidScaleSettings(settings: ScaleSettings): boolean {
  return scaleSettingsSchema.safeParse(settings).success
}

// ─── Línea "Resultado" (D11: espeja la pantalla "Formato de código de barras") ──

/**
 * Letra que la pestaña Balanza muestra para un campo, en la línea "Resultado"
 * que el comercio compara a ojo contra la pantalla de la balanza.
 *
 * Fix F5 (revisión adversarial PR #599): la letra es la de la POSICIÓN del
 * campo en la pantalla de la balanza (A/B/C/D, pág. 135: "cuatro campos
 * ordenados A/B/C/D", cada uno con un tipo elegible por desplegable) — NO el
 * TIPO de campo que se le asignó. La balanza rotula la posición, no el
 * contenido: reordenar los campos (D4.2 lo admite) cambia qué tipo vive en
 * cada posición, pero la posición sigue mostrándose con la MISMA letra. Con
 * la letra por tipo (versión anterior), un formato con Importe en la
 * posición B y Código en la C dibujaba una línea (`CCCCCCBBBB…`) que la
 * balanza jamás mostraría (`BBBBBBCCCC…`), justo en la comparación que D3/D11
 * usan para validar que el comercio copió bien la configuración.
 *
 * `fixed` no pasa por acá — su valor se imprime literal (siempre el campo A,
 * D4.2). El índice 0-based del segmento en `layout.segments` ES la posición
 * A/B/C/D (`String.fromCharCode(65 + index)`).
 */
function letterFor(index: number): string {
  return String.fromCharCode(65 + index)
}

/**
 * La línea "Resultado" que la pestaña Balanza muestra junto al editor de
 * formato, para compararla a ojo con la de la balanza (D11, D4): el valor
 * literal del campo A seguido de la letra de POSICIÓN de cada campo
 * repetida por su cantidad de dígitos (F5), y una `X` final para el dígito
 * verificador del EAN-13.
 *
 * @example
 * layoutResultPattern(FACTORY_SCALE_SETTINGS.layouts[0]) // "20BBBBCCCCCCX"
 */
export function layoutResultPattern(layout: ScaleLayout): string {
  const segs = layout.segments
  let out = ""
  segs.forEach((seg, i) => {
    if (seg.field === "fixed") {
      out += seg.value ?? ""
      return
    }
    out += letterFor(i).repeat(seg.digits)
  })
  return out + "X"
}

/**
 * El importe máximo representable por el campo de valor de TIPO `amount` de
 * un formato (D4): `(10^dígitos − 1) / 10^decimales`. `null` si el formato
 * no tiene campo de importe (p. ej. usa `quantity`, o es el formato Varios).
 *
 * @example
 * maxRepresentableAmount(FACTORY_SCALE_SETTINGS.layouts[0]) // 9999.99
 */
export function maxRepresentableAmount(layout: ScaleLayout): number | null {
  const amountSeg = layout.segments.find((s) => s.field === "amount")
  if (!amountSeg) return null
  const decimals = amountSeg.decimals ?? 0
  return (10 ** amountSeg.digits - 1) / 10 ** decimals
}
