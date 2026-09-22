/**
 * fiscal-emision-segura (G9, 2026-09-22) — traducción de los errores de la
 * pantalla de Datos fiscales (perfil fiscal + puntos de venta).
 *
 * Por qué vive acá y no en `translateEmitError` (hooks/data/use-emit-comprobante):
 * ese mapa traduce errores de EMISIÓN de un comprobante y su fallback es
 * "Ocurrió un error inesperado al emitir el comprobante", que sería falso para
 * un alta de punto de venta. Este devuelve `null` cuando no reconoce el error,
 * así que el caller conserva el mensaje que ya mostraba.
 *
 * El backend manda el detail del RAISE tal cual (RFC 7807 → `body.detail` →
 * `Error.message`), y ese texto ya está en castellano. La traducción existe por
 * dos razones concretas:
 *   1. quitar el token de máquina (`cuit_punto_venta_en_otra_cuenta:`), que el
 *      usuario no tiene por qué leer;
 *   2. ganarle a la heurística de `onCreatePv`, que reemplaza el mensaje por
 *      "El punto de venta N ya existe" cuando el texto contiene "409" — y un
 *      CUIT como 20-40912345-6 contiene "409".
 */

/** Token estable que emiten los dos disparadores de G9 (ERRCODE P0435). */
const CUIT_PV_CROSS_ACCOUNT = "cuit_punto_venta_en_otra_cuenta"

/**
 * Devuelve el mensaje para el usuario, o `null` si el error no es uno de los
 * que esta pantalla sabe explicar.
 */
export function translateFiscalConfigError(message: string): string | null {
  if (!message) return null

  if (message.includes(CUIT_PV_CROSS_ACCOUNT)) {
    // El detail del backend ya trae el número de punto de venta y las salidas
    // posibles; sólo se le quita el prefijo de máquina.
    const withoutToken = message.split(`${CUIT_PV_CROSS_ACCOUNT}:`).pop()?.trim()
    return (
      withoutToken ||
      "Ese CUIT ya tiene ese punto de venta activo en otra cuenta. Ante ARCA la " +
        "numeración es por CUIT y punto de venta: dos cuentas no pueden compartirlo."
    )
  }

  return null
}
