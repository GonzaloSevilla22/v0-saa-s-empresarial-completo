/**
 * productos-costo-nullable (task 6.3 RED → GREEN, 6.4 control negativo).
 *
 * `NumericInput` gana un opt-in `nullable` (default `false`):
 *  - con `nullable`: cadena vacía → `onValueChange(null)`; `value == null` →
 *    input vacío; `value === 0` se renderiza `"0"` (un cero declarado tiene
 *    que verse, no confundirse con "vacío").
 *  - sin `nullable` (default, byte a byte el comportamiento de hoy): cadena
 *    vacía → `onValueChange(0)`; `value === 0` renderiza input vacío. Control
 *    negativo obligatorio: 22 instancias en 7 archivos NO deben cambiar.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { NumericInput } from "@/components/ui/numeric-input"

describe("NumericInput — nullable opt-in", () => {
  it("con nullable=false (default) — cero se renderiza vacío (comportamiento de hoy)", () => {
    render(<NumericInput value={0} onValueChange={() => {}} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.value).toBe("")
  })

  it("con nullable=false (default) — cadena vacía dispara onValueChange(0)", () => {
    const onValueChange = vi.fn()
    render(<NumericInput value={5} onValueChange={onValueChange} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    fireEvent.change(input, { target: { value: "" } })
    expect(onValueChange).toHaveBeenCalledWith(0)
  })

  it("con nullable=true — value=null renderiza el input vacío", () => {
    render(<NumericInput nullable value={null} onValueChange={() => {}} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.value).toBe("")
  })

  it("con nullable=true — value=0 se renderiza \"0\" (declarado, no vacío)", () => {
    render(<NumericInput nullable value={0} onValueChange={() => {}} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.value).toBe("0")
  })

  it("con nullable=true — cadena vacía dispara onValueChange(null), no 0", () => {
    const onValueChange = vi.fn()
    render(<NumericInput nullable value={100} onValueChange={onValueChange} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    fireEvent.change(input, { target: { value: "" } })
    expect(onValueChange).toHaveBeenCalledWith(null)
  })

  it("con nullable=true — un valor numérico dispara onValueChange con ese número", () => {
    const onValueChange = vi.fn()
    render(<NumericInput nullable value={null} onValueChange={onValueChange} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    fireEvent.change(input, { target: { value: "42" } })
    expect(onValueChange).toHaveBeenCalledWith(42)
  })

  // productos-costo-nullable (ronda 2, finding nit): con nullable=true el
  // placeholder por defecto NO puede ser "0" — se leería como un valor
  // cero, justo la ambigüedad vacío-vs-cero que el modo nullable existe
  // para eliminar (value === 0 SÍ debe verse, un placeholder "0" sobre un
  // input vacío se ve casi igual).
  it("con nullable=true (default, sin placeholder propio) — no usa \"0\" como placeholder", () => {
    render(<NumericInput nullable value={null} onValueChange={() => {}} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.placeholder).not.toBe("0")
  })

  it("con nullable=true — un placeholder explícito del caller se respeta", () => {
    render(<NumericInput nullable value={null} onValueChange={() => {}} placeholder="Sin costo" />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.placeholder).toBe("Sin costo")
  })

  it("con nullable=false (default) — conserva el placeholder \"0\" (control negativo)", () => {
    render(<NumericInput value={5} onValueChange={() => {}} />)
    const input = screen.getByRole("spinbutton") as HTMLInputElement
    expect(input.placeholder).toBe("0")
  })
})
