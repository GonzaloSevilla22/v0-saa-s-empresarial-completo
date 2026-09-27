/**
 * Error que lanza `pythonClient` ante una respuesta no-2xx del backend.
 *
 * ventas-unidades-conversion (decisión 7): hasta acá `handleResponse` tiraba
 * un `Error` con el `detail` y descartaba el resto del problem+json (RFC 7807,
 * v3-api-standards §1: `code` = código de negocio —slug estable o sqlstate
 * P04xx— y `field` = campo implicado). El formulario de producto necesita el
 * `code` para distinguir el 409 `base_unit_locked` de cualquier otro 409 sin
 * parsear el texto del `detail`.
 *
 * Sigue siendo un `Error` con el MISMO `message` (mismo molde que
 * `SubscriptionConflictError`/`FiscalInvoiceError`), así que ningún manejo
 * genérico existente (`error.message` en un toast) cambia. Vive en su propio
 * módulo — y no en `python-client.ts` — porque ése exige
 * `NEXT_PUBLIC_BACKEND_URL` al importarse: un componente que sólo quiere
 * reconocer el error no debe arrastrar esa guarda de arranque.
 */
export interface PythonApiProblem {
  code?: unknown
  field?: unknown
}

export class PythonApiError extends Error {
  readonly status: number
  readonly code?: string
  readonly field?: string

  constructor(message: string, status: number, problem: PythonApiProblem = {}) {
    super(message)
    this.name = "PythonApiError"
    this.status = status
    this.code = typeof problem.code === "string" ? problem.code : undefined
    this.field = typeof problem.field === "string" ? problem.field : undefined
  }
}
