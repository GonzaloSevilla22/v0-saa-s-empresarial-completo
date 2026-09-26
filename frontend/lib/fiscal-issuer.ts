/**
 * factura-fiscal-imprimible (D6/D7, OQ-1) — datos del emisor que exige la
 * factura impresa (RG 1415) y cómo se nombran.
 *
 * Obligatorios para imprimir: razón social, domicilio comercial, Ingresos
 * Brutos (número O condición) e inicio de actividades. El nombre de fantasía es
 * opcional. El backend usa los MISMOS códigos en el 409 `issuer_data_incomplete`
 * (además de `cuit` e `iva_condition`, que la configuración ya exige), así que
 * las etiquetas viven acá una sola vez: las usan la configuración fiscal y el
 * aviso al imprimir.
 *
 * Funciones puras, sin dependencias de red (testeables sin mockear la app).
 */

/** Código de un dato del emisor que puede faltar para imprimir. */
export type IssuerPrintField =
  | "razon_social"
  | "domicilio_comercial"
  | "iibb"
  | "inicio_actividades"

/** Lo mínimo del perfil fiscal que decide si se puede imprimir. */
export interface IssuerPrintData {
  razonSocial: string | null
  domicilioComercial: string | null
  iibbNumero: string | null
  iibbCondition: string | null
  inicioActividades: string | null
}

const LABELS: Record<string, string> = {
  razon_social: "la razón social",
  domicilio_comercial: "el domicilio comercial",
  iibb: "el número o la condición de Ingresos Brutos",
  inicio_actividades: "la fecha de inicio de actividades",
  cuit: "el CUIT",
  iva_condition: "la condición frente al IVA",
}

function filled(value: string | null | undefined): boolean {
  return typeof value === "string" && value.trim().length > 0
}

/** Los datos que faltan para imprimir, en el orden en que van en la factura. */
export function missingIssuerPrintFields(profile: IssuerPrintData | null): IssuerPrintField[] {
  if (!profile) return ["razon_social", "domicilio_comercial", "iibb", "inicio_actividades"]
  const missing: IssuerPrintField[] = []
  if (!filled(profile.razonSocial)) missing.push("razon_social")
  if (!filled(profile.domicilioComercial)) missing.push("domicilio_comercial")
  if (!filled(profile.iibbNumero) && !filled(profile.iibbCondition)) missing.push("iibb")
  if (!filled(profile.inicioActividades)) missing.push("inicio_actividades")
  return missing
}

/**
 * "el domicilio comercial y la fecha de inicio de actividades". Acepta también
 * los códigos que sólo manda el backend (`cuit`, `iva_condition`); uno
 * desconocido se muestra tal cual en vez de romper.
 */
export function describeMissingIssuerFields(fields: readonly string[]): string {
  const labels = fields.map((field) => LABELS[field] ?? field)
  if (labels.length <= 1) return labels[0] ?? ""
  return `${labels.slice(0, -1).join(", ")} y ${labels[labels.length - 1]}`
}
