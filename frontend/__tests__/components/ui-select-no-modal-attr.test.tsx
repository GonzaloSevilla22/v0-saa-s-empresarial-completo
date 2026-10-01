import { describe, it, expect, vi, beforeAll, beforeEach, afterAll } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { useState } from "react"
import type { ComponentPropsWithoutRef, ElementRef } from "react"
import type * as SelectPrimitiveModule from "@radix-ui/react-select"

// tablero-menu-pulido (P5): al abrir cualquier <Select> React avisaba
// "Received `false` for a non-boolean attribute `modal`". El componente
// compartido le pasaba `modal={false}` a `SelectPrimitive.Content`, silenciando
// el error de tipos con una directiva de TypeScript: Radix Select 2.x NO tiene
// esa prop (no aparece en ninguna parte de su código), así que caía tal cual al
// <div> del DOM. Era un no-op: el foco/scroll lock del Select no depende de ella.
//
// Cómo protege la regresión (ronda 1 de revisión): React avisa UNA sola vez por
// atributo y por módulo, y un `false` en un atributo desconocido nunca llega al
// DOM. Por eso (1) el espía de console.error se instala UNA vez para todo el
// archivo y cada test mira el acumulado — el aviso no se le escapa a ningún
// test aunque otro haya abierto el Content antes — y (2) un espía sobre el
// `Content` de Radix registra las props que le llegan: es la guarda que no
// depende de la maquinaria de avisos de React.

const h = vi.hoisted(() => ({
  contentProps: [] as Array<Record<string, unknown>>,
}))

vi.mock("@radix-ui/react-select", async (importOriginal) => {
  const actual = await importOriginal<typeof SelectPrimitiveModule>()
  const React = await import("react")
  const ContentEspia = React.forwardRef<
    ElementRef<typeof actual.Content>,
    ComponentPropsWithoutRef<typeof actual.Content>
  >(function ContentEspia(props, ref) {
    h.contentProps.push({ ...props })
    return React.createElement(actual.Content, { ...props, ref })
  })
  return { ...actual, Content: ContentEspia }
})

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"

function Opciones({ onChange }: { onChange?: (v: string) => void }) {
  return (
    <Select onValueChange={onChange}>
      <SelectTrigger aria-label="Canal">
        <SelectValue placeholder="Elegí un canal" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="local">Local</SelectItem>
        <SelectItem value="web">Web</SelectItem>
      </SelectContent>
    </Select>
  )
}

// Espía de archivo: NO se restaura entre tests (ver el comentario de cabecera).
let errorSpy: ReturnType<typeof vi.spyOn>

function avisosDeAtributo(): string[] {
  return errorSpy.mock.calls
    .map((args: unknown[]) => args.map(String).join(" "))
    .filter((line: string) => /non-boolean attribute|React does not recognize|`modal`/.test(line))
}

describe("ui/select — sin atributo `modal` colgando al DOM (tablero-menu-pulido P5)", () => {
  beforeAll(() => {
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
  })

  beforeEach(() => {
    h.contentProps = []
  })

  afterAll(() => {
    // Cierre: en TODO el archivo, con cualquier orden de ejecución, el aviso
    // nunca se emitió.
    expect(avisosDeAtributo()).toEqual([])
    errorSpy.mockRestore()
  })

  it("abrir un Select no emite el warning de React por el atributo `modal`", async () => {
    const user = userEvent.setup()
    render(<Opciones />)

    await user.click(screen.getByRole("combobox", { name: "Canal" }))
    expect(await screen.findByRole("option", { name: "Web" })).toBeInTheDocument()

    expect(avisosDeAtributo()).toEqual([])
  })

  it("SelectContent no le pasa una prop `modal` al Content de Radix (que no la conoce)", async () => {
    const user = userEvent.setup()
    render(<Opciones />)

    await user.click(screen.getByRole("combobox", { name: "Canal" }))
    expect(await screen.findByRole("listbox")).toBeInTheDocument()

    // El espía tiene que haber visto el Content: sin esto la aserción de abajo
    // pasaría en vacío.
    expect(h.contentProps.length).toBeGreaterThan(0)
    expect(h.contentProps.filter((props) => "modal" in props)).toEqual([])
  })

  // Control de comportamiento: lo que `modal={false}` decía proteger (elegir una
  // opción dentro de un Dialog sin que el clic se pierda ni cierre el Dialog)
  // sigue funcionando.
  it("dentro de un Dialog se puede elegir una opción, el valor llega al onValueChange y el Dialog no se cierra", async () => {
    const onChange = vi.fn()
    const onOpenChange = vi.fn()
    function Escena() {
      const [abierto, setAbierto] = useState(true)
      return (
        <Dialog
          open={abierto}
          onOpenChange={(next) => {
            onOpenChange(next)
            setAbierto(next)
          }}
        >
          <DialogContent>
            <DialogTitle>Nueva venta</DialogTitle>
            <DialogDescription>Elegí el canal</DialogDescription>
            <Opciones onChange={onChange} />
          </DialogContent>
        </Dialog>
      )
    }
    const user = userEvent.setup()
    render(<Escena />)

    await user.click(screen.getByRole("combobox", { name: "Canal" }))
    await user.click(await screen.findByRole("option", { name: "Web" }))

    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenCalledWith("web")
    expect(onOpenChange).not.toHaveBeenCalledWith(false)
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Canal" })).toHaveTextContent("Web")
  })

  it("fuera de un Dialog también: elegir otra opción cambia el valor mostrado", async () => {
    const onChange = vi.fn()
    const user = userEvent.setup()
    render(<Opciones onChange={onChange} />)

    await user.click(screen.getByRole("combobox", { name: "Canal" }))
    await user.click(await screen.findByRole("option", { name: "Local" }))

    expect(onChange).toHaveBeenCalledWith("local")
    expect(screen.getByRole("combobox", { name: "Canal" })).toHaveTextContent("Local")
  })
})
