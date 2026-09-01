/**
 * qa-integral-modulos G12 (H16) — colores de serie de los reportes.
 *
 * Regla (skill de dataviz): el color sigue a la ENTIDAD (la serie), nunca a
 * su rango ni a la fila — jamás `<Cell>` con paleta rotativa por fila, que
 * era exactamente el bug: la paleta rotada incluía el fill fijo de la otra
 * serie ("Efectivo": Vendido y Comprado el mismo azul #60a5fa).
 *
 * Un color fijo por concepto, consistente entre los TRES reportes
 * (/reportes/formas-pago, /reportes/centros-costo, /reportes/sucursal):
 * lo vendido en verde (token primary), lo comprado en azul, lo gastado en
 * rojo (token destructive). Paleta validada con la skill de dataviz
 * (validate_palette.js: lightness/chroma/CVD ΔE 23.2 deutan/normal 26.8 en
 * claro — el WARN de contraste lo releva la tabla que acompaña a cada
 * gráfico; en oscuro los tokens del design system quedan al borde de la
 * banda de luminosidad, característica de la marca, no de este fix).
 */
export const REPORT_SERIES_COLORS = {
  /** Vendido / Ventas — ingreso, verde de marca. */
  sold: "hsl(var(--primary))",
  /** Comprado / Compras — azul fijo (ya era el fill de la serie). */
  purchased: "#60a5fa",
  /** Gastado / Gastos — rojo del token destructive. */
  spent: "hsl(var(--destructive))",
} as const
