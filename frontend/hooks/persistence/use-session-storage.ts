"use client"

import { readFromStorage, usePersistentState, writeToStorage } from "./use-persistent-state"

/**
 * sessionStorage-backed state. Cleared when the tab closes.
 * Use for wizard step progress, unsaved form data (short-lived).
 *
 * @example
 * const [step, setStep] = useSessionStorage("import:step", 1)
 */
export function useSessionStorage<T>(
  key: string,
  initialValue: T,
): [T, (value: T | ((prev: T) => T)) => void, () => void] {
  return usePersistentState(key, initialValue, { backend: "sessionStorage" })
}

/**
 * Lectura PUNTUAL de sessionStorage, fuera del estado de React (mismo formato
 * JSON y mismo try/catch que `useSessionStorage`). Para valores que se
 * necesitan en el momento de una acción y que otras instancias montadas pueden
 * haber cambiado: `useSessionStorage` hidrata UNA vez al montar, así que dos
 * componentes montados a la vez no ven lo que escribió el otro.
 * punto-venta-seleccion (D8): la última elección de PV en /ventas/ordenes,
 * donde cada fila tiene su propio botón de emitir.
 */
export function readSessionValue<T>(key: string): T | null {
  return readFromStorage<T>(key, "sessionStorage", JSON.parse)
}

/** Escritura puntual en sessionStorage (degrada en silencio si está bloqueado). */
export function writeSessionValue<T>(key: string, value: T): void {
  writeToStorage(key, value, "sessionStorage", JSON.stringify, 0)
}
