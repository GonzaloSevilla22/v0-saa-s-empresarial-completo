/**
 * PaymentMethodBadge — canonización (gastos-forma-pago, D16 / task 8.1).
 *
 * El badge de forma de pago estaba duplicado LITERAL en 4 lugares
 * (`sale-operations-list.tsx` ×2 — mobile y desktop —, `purchase-operations-
 * list.tsx` ×2). Con el listado de gastos serían 6: Regla de Tres cumplida
 * hace rato, no anticipada. Estos tests fijan el contrato del componente
 * canónico ANTES de escribirlo (RED: el módulo no existe todavía).
 *
 * El tercer test es el que importa de verdad: D17 prohíbe copiar el estilo de
 * `categoryColors` de `gastos/page.tsx` (`bg-blue-500/20 text-blue-400 …`),
 * que es exactamente el patrón que `tokens-contraste-aa` (#406-#408)
 * desterró. Un badge nuevo con colores literales pasaría cualquier test de
 * contenido; sólo lo atrapa una aserción sobre las clases emitidas.
 */
import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { PaymentMethodBadge } from "@/components/payment-methods/PaymentMethodBadge"
import { KIND_LABELS, UNASSIGNED_PAYMENT_METHOD_LABEL } from "@/lib/payment-method-meta"

/**
 * Paleta literal de Tailwind: cualquier `bg-/text-/border-` seguido de una
 * familia de color con escala numérica. Los tonos semánticos del design
 * system (`text-muted-foreground`, `bg-success/15`, …) no matchean.
 */
const LITERAL_COLOR_RE =
  /\b(?:bg|text|border)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/

describe("PaymentMethodBadge", () => {
  it("renderiza el nombre de la forma de pago imputada", () => {
    render(<PaymentMethodBadge name="Transferencia bancaria" />)
    expect(screen.getByText("Transferencia bancaria")).toBeInTheDocument()
  })

  it("cae en 'Sin especificar' cuando no hay imputación (null, undefined o vacío)", () => {
    const { rerender } = render(<PaymentMethodBadge name={null} />)
    expect(screen.getByText(UNASSIGNED_PAYMENT_METHOD_LABEL)).toBeInTheDocument()

    rerender(<PaymentMethodBadge />)
    expect(screen.getByText(UNASSIGNED_PAYMENT_METHOD_LABEL)).toBeInTheDocument()

    // Un nombre en blanco es tan "sin imputar" como la ausencia: sin este
    // caso el badge mostraría una cápsula vacía.
    rerender(<PaymentMethodBadge name="   " />)
    expect(screen.getByText(UNASSIGNED_PAYMENT_METHOD_LABEL)).toBeInTheDocument()
  })

  it("D17: no emite ni una clase de color literal de Tailwind, en ninguna de sus variantes", () => {
    const { rerender } = render(<PaymentMethodBadge name="Efectivo" kind="cash" />)
    expect(screen.getByTestId("payment-method-badge").className).not.toMatch(LITERAL_COLOR_RE)

    rerender(<PaymentMethodBadge name={null} layout="inline" />)
    expect(screen.getByTestId("payment-method-badge").className).not.toMatch(LITERAL_COLOR_RE)
  })

  it("usa el token semántico de texto atenuado, igual que las 4 duplicaciones que reemplaza", () => {
    render(<PaymentMethodBadge name="Efectivo" />)
    expect(screen.getByTestId("payment-method-badge").className).toContain("text-muted-foreground")
  })

  it("layout 'block' ocupa el ancho del contenido y 'inline' no se encoge — las dos variantes vivas", () => {
    const { rerender } = render(<PaymentMethodBadge name="Efectivo" layout="block" />)
    expect(screen.getByTestId("payment-method-badge").className).toContain("w-fit")

    rerender(<PaymentMethodBadge name="Efectivo" layout="inline" />)
    const cls = screen.getByTestId("payment-method-badge").className
    expect(cls).toContain("shrink-0")
    expect(cls).not.toContain("w-fit")
  })

  it("cuando recibe el kind lo expone como título accesible en castellano, y sin kind no inventa ninguno", () => {
    const { rerender } = render(<PaymentMethodBadge name="Mi transferencia" kind="transfer" />)
    expect(screen.getByTestId("payment-method-badge")).toHaveAttribute("title", KIND_LABELS.transfer)

    rerender(<PaymentMethodBadge name="Mi transferencia" />)
    expect(screen.getByTestId("payment-method-badge")).not.toHaveAttribute("title")
  })
})

describe("KIND_LABELS (lib/payment-method-meta)", () => {
  it("cubre los 7 kinds del catálogo, en castellano", () => {
    expect(KIND_LABELS).toEqual({
      cash: "Efectivo",
      transfer: "Transferencia",
      card: "Tarjeta",
      check: "Cheque",
      wallet: "Billetera virtual",
      credit: "Cuenta corriente",
      other: "Otro",
    })
  })

  it("UNASSIGNED_PAYMENT_METHOD_LABEL es EL MISMO literal que ya usa el reporte, no una copia nueva", async () => {
    const report = await import("@/lib/payment-method-report")
    expect(UNASSIGNED_PAYMENT_METHOD_LABEL).toBe(report.UNASSIGNED_PAYMENT_METHOD_LABEL)
  })
})
