/**
 * productos-categorias-sku (D10) — template de ejemplo de la carga masiva,
 * generado desde el catálogo REAL de la cuenta que lo descarga.
 *
 * Antes era una constante de módulo con "Ropa"/"Alimentos" literales, que
 * podían no existir en la cuenta. Las filas de ejemplo usan las dos primeras
 * categorías ACTIVAS del catálogo; con el catálogo vacío se cae a las legacy.
 * De paso se corrige el espacio a la izquierda del SKU en la fila Padre
 * (`;;;;;;; ZAP-NIKE`), hoy inofensivo sólo porque el validador hace trim.
 */

export const TEMPLATE_HEADER = "Tipo;Nombre;Precio;Costo;Categoría;Stock;Stock mínimo;Código;SKU"

const LEGACY_FALLBACK: readonly [string, string] = ["Ropa", "Alimentos"]

export function buildTemplateCsv(
  categories: readonly { name: string; isActive: boolean }[],
): string {
  const active = categories.filter((c) => c.isActive).map((c) => c.name)
  const [first, second]: readonly [string, string] =
    active.length >= 2 ? [active[0], active[1]]
    : active.length === 1 ? [active[0], active[0]]
    : LEGACY_FALLBACK

  return [
    TEMPLATE_HEADER,
    `Producto;Remera básica;5000;2500;${first};50;10;;REM-001`,
    "Padre;Zapatillas Nike;;;;;;;ZAP-NIKE",
    `Variante;Zapatillas Nike 41;18000;9000;${first};15;3;;ZAP-NIKE-41`,
    `Variante;Zapatillas Nike 42;18000;9000;${first};12;3;;ZAP-NIKE-42`,
    `Producto;Aceite de oliva 500ml;3200;1800;${second};30;5;7790001234567;ACE-500`,
  ].join("\n")
}
