/**
 * Tests for task 1.8 of `v4-visual-3d-refresh` Fase A: applying the refresh
 * tokens (motion duration/easing, elevation shadows) to the base shadcn/
 * Radix components via their existing `cva`/`cn` styling — Button, Card,
 * Input, Badge, Dialog, Table — WITHOUT forking/bifurcating them
 * (`components/ui/*` stays the single source, per spec `visual-design-system`
 * Requirement "Estilos de componente unificados sobre shadcn/Radix").
 *
 * Each component gets two assertions: (1) the token utility class is now
 * present (guards the actual refactor, not a tautology), and (2) the
 * pre-existing `className` merge behavior still works (no regression from
 * the refactor) — the closest meaningful "happy path + edge case" pairing
 * for a presentational className change with no branching logic to fake.
 *
 * Cycle: RED (components don't use the token classes yet) → GREEN →
 * TRIANGULATE (token class present + className merge preserved) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Badge } from "@/components/ui/badge"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Table, TableBody, TableRow, TableCell } from "@/components/ui/table"

describe("ui token refresh (task 1.8)", () => {
  it("Button uses the tokenized motion duration/easing for its color transition", () => {
    render(<Button className="my-button">Guardar</Button>)
    const button = screen.getByRole("button", { name: "Guardar" })
    expect(button.className).toContain("duration-base")
    expect(button.className).toContain("ease-standard")
    expect(button.className).toContain("my-button")
  })

  it("Card uses the tokenized elevation-1 shadow instead of the raw shadow-sm default", () => {
    render(<Card className="my-card" data-testid="card">contenido</Card>)
    const card = screen.getByTestId("card")
    expect(card.className).toContain("shadow-elevation-1")
    expect(card.className).not.toContain("shadow-sm")
    expect(card.className).toContain("my-card")
  })

  it("Input uses the tokenized motion duration/easing for its focus/border transition", () => {
    render(<Input className="my-input" placeholder="Buscar" />)
    const input = screen.getByPlaceholderText("Buscar")
    expect(input.className).toContain("duration-base")
    expect(input.className).toContain("ease-standard")
    expect(input.className).toContain("my-input")
  })

  it("Badge uses the tokenized motion duration/easing for its color transition", () => {
    render(<Badge className="my-badge">Nuevo</Badge>)
    const badge = screen.getByText("Nuevo")
    expect(badge.className).toContain("duration-base")
    expect(badge.className).toContain("ease-standard")
    expect(badge.className).toContain("my-badge")
  })

  it("DialogContent uses the tokenized elevation-4 shadow instead of the raw shadow-lg default", () => {
    render(
      <Dialog open>
        <DialogContent className="my-dialog">
          <DialogTitle>Titulo</DialogTitle>
        </DialogContent>
      </Dialog>
    )
    const dialog = screen.getByRole("dialog")
    expect(dialog.className).toContain("shadow-elevation-4")
    expect(dialog.className).not.toContain("shadow-lg")
    expect(dialog.className).toContain("my-dialog")
  })

  it("TableRow uses the tokenized motion duration/easing for its hover transition", () => {
    render(
      <Table>
        <TableBody>
          <TableRow className="my-row" data-testid="row">
            <TableCell>uno</TableCell>
          </TableRow>
        </TableBody>
      </Table>
    )
    const row = screen.getByTestId("row")
    expect(row.className).toContain("duration-base")
    expect(row.className).toContain("ease-standard")
    expect(row.className).toContain("my-row")
  })
})
