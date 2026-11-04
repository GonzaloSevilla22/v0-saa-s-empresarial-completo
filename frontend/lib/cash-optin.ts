/**
 * Textos del opt-in de caja que comparten el hook (`useCashOptin`), el bloque
 * presentacional (`CashOptinBlock`) y los motivos de bloqueo de los diálogos de
 * conversión. Viven acá —y no en el hook— para que el bloque no arrastre los
 * hooks de datos (cajas, sesión, sucursales) sólo por importar un string.
 *
 * `caja-optin-carga`: mientras se averigua dónde está la sesión de caja, el
 * consumidor no puede confirmar una operación en efectivo (mandaría
 * `cash_session_id = null` y se registraría sin movimiento de caja).
 */

/** Estado de carga del opt-in: aviso visible y motivo del botón de confirmar bloqueado. */
export const CASH_OPTIN_PENDING_TEXT = "Verificando la caja…"
