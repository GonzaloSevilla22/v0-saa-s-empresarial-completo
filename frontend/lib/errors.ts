/**
 * review B (FE-4/FE-5/SEC-2/SPEC-02): helper canónico para leer un mensaje
 * de error legible fuera de un `catch (err: any)` — el proyecto prohíbe
 * `any` (CLAUDE.md), y `err instanceof Error` es el narrowing correcto para
 * los errores que lanza `pythonClient` (Error con `.message` = el `detail`
 * RFC 7807 del backend, ver `lib/api/python-client.ts`).
 *
 * Reutilizar antes que repetir (regla PO 2026-08-02): nace acá en vez de
 * quedar embebido en un componente puntual, para que cualquier `catch`
 * nuevo lo reuse en vez de reescribir el mismo `instanceof Error` check.
 */
export function getErrorMessage(err: unknown, fallback: string): string {
  return err instanceof Error && err.message ? err.message : fallback
}
