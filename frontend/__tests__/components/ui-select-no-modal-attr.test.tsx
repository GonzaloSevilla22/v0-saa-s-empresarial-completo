import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { useState } from "react"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"

// tablero-menu-pulido (P5): al abrir cualquier <Select> React avisaba
// "Received `false` for a non-boolean attribute `modal`". El componente
// compartido le pasaba `modal={false}` a `SelectPrimitive.Content`, silenciando
// el error de tipos con una directiva de TypeScript: Radix Select 2.x NO tiene
// esa prop (no aparece en ninguna parte de su código), así que caía tal cual al
// <div> del DOM. Era un no-op: el foco/scroll lock del Select no depende de ella.

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

function avisosDeAtributo(spy: ReturnType<typeof vi.spyOn>): string[] {
  return spy.mock.calls
    .map((args: unknown[]) => args.map(String).join(" "))
    .filter((line: string) => /non-boolean attribute|React does not recognize|`modal`/.test(line))
}

describe("ui/select — sin atributo `modal` colgando al DOM (tablero-menu-pulido P5)", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("abrir un Select no emite el warning de React por el atributo `modal`", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const user = userEvent.setup()
    render(<Opciones />)

    await user.click(screen.getByRole("combobox", { name: "Canal" }))
    expect(await screen.findByRole("option", { name: "Web" })).toBeInTheDocument()

    expect(avisosDeAtributo(errorSpy)).toEqual([])
  })

  it("abierto controlado desde el montaje (open) tampoco lo emite", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    render(
      <Select open defaultValue="local">
        <SelectTrigger aria-label="Canal">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="local">Local</SelectItem>
        </SelectContent>
      </Select>,
    )

    expect(screen.getByRole("listbox")).toBeInTheDocument()
    expect(avisosDeAtributo(errorSpy)).toEqual([])
  })

  it("el listbox no lleva ningún atributo `modal` en el DOM", async () => {
    const user = userEvent.setup()
    render(<Opciones />)
    await user.click(screen.getByRole("combobox", { name: "Canal" }))

    expect((await screen.findByRole("listbox")).hasAttribute("modal")).toBe(false)
  })

  // Control de comportamiento: lo que `modal={false}` decía proteger (elegir una
  // opción dentro de un Dialog sin que el clic se pierda) sigue funcionando.
  it("dentro de un Dialog se puede elegir una opción y el valor llega al onValueChange", async () => {
    const onChange = vi.fn()
    function Escena() {
      const [abierto] = useState(true)
      return (
        <Dialog open={abierto}>
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
