/**
 * Las 24 jurisdicciones de Argentina (23 provincias + CABA), en orden alfabético.
 * Se usan como opciones del campo "Provincia" en el alta y se persisten en
 * `profiles.province`. Mantener el texto estable: es lo que queda guardado.
 */
export const PROVINCIAS_AR = [
  "Buenos Aires",
  "Ciudad Autónoma de Buenos Aires",
  "Catamarca",
  "Chaco",
  "Chubut",
  "Córdoba",
  "Corrientes",
  "Entre Ríos",
  "Formosa",
  "Jujuy",
  "La Pampa",
  "La Rioja",
  "Mendoza",
  "Misiones",
  "Neuquén",
  "Río Negro",
  "Salta",
  "San Juan",
  "San Luis",
  "Santa Cruz",
  "Santa Fe",
  "Santiago del Estero",
  "Tierra del Fuego",
  "Tucumán",
] as const

export type ProvinciaAR = (typeof PROVINCIAS_AR)[number]
