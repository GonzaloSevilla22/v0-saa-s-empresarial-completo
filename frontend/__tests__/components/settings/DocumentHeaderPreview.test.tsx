/**
 * documentos-marca-empresa (task 11.1) — `DocumentHeaderPreview`: el mini-render del encabezado
 * de un presupuesto con lo que se está editando (logo, nombre, líneas, título, banda de la
 * tabla y total con la paleta). REPRESENTA EL PAPEL: fondo blanco también en tema oscuro; los
 * colores salen de la paleta (hex validado), no de los tokens de la app.
 */
import React from "react"
import { describe, expect, it } from "vitest"
import { render, screen, within } from "@testing-library/react"
import "@testing-library/jest-dom"

import { DocumentHeaderPreview } from "@/components/settings/DocumentHeaderPreview"
import type { PrintedIssuer, ResolvedPalette } from "@/lib/document-branding"
import { AZUL_PALETTE, NEUTRO_PALETTE, PNG_DATA_URI } from "../../helpers/branding-fixtures"

const ISSUER: PrintedIssuer = {
  name: "Sumar Ropa Deportiva",
  legal_name: "Ropa Deportiva SRL",
  cuit: "20-12345678-6",
  iva_legend: "IVA RESPONSABLE MONOTRIBUTO",
  address: "Av. San Martín 1234, Mendoza",
  phone: "2617175072",
  email: "ventas@sumar.com.ar",
  website: "sumar.com.ar",
}

const paper = () => screen.getByRole("img", { name: /vista previa del encabezado/i })

function renderPreview(over: Partial<React.ComponentProps<typeof DocumentHeaderPreview>> = {}) {
  return render(
    <DocumentHeaderPreview issuer={ISSUER} footerNote="Alias: sumar.ropa" palette={AZUL_PALETTE as ResolvedPalette} logoDataUri={PNG_DATA_URI} {...over} />,
  )
}

describe("DocumentHeaderPreview", () => {
  it("muestra el emisor tal como se imprime: nombre, razón social, CUIT, IVA, domicilio y contacto", () => {
    renderPreview()
    const view = within(paper())
    for (const text of [
      "Sumar Ropa Deportiva", "Ropa Deportiva SRL", "CUIT: 20-12345678-6", "IVA RESPONSABLE MONOTRIBUTO",
      "Av. San Martín 1234, Mendoza", "Tel: 2617175072", "ventas@sumar.com.ar", "sumar.com.ar",
    ]) {
      expect(view.getByText(text), text).toBeInTheDocument()
    }
  })

  it("la razón social sólo se muestra si difiere del nombre", () => {
    renderPreview({ issuer: { ...ISSUER, name: "Ropa Deportiva SRL" } })
    expect(within(paper()).getAllByText("Ropa Deportiva SRL")).toHaveLength(1)
  })

  it("lleva el título del documento, la banda de la tabla con dos líneas y el total", () => {
    renderPreview()
    const view = within(paper())
    expect(view.getByText("PRESUPUESTO")).toBeInTheDocument()
    expect(view.getByText(/P-00000001/)).toBeInTheDocument()
    expect(view.getByText("Descripción")).toBeInTheDocument()
    expect(view.getAllByTestId("preview-line")).toHaveLength(2)
    expect(view.getByText("TOTAL")).toBeInTheDocument()
  })

  it("muestra la leyenda al pie de la cuenta, si la hay", () => {
    renderPreview()
    expect(within(paper()).getByText("Alias: sumar.ropa")).toBeInTheDocument()
    renderPreview({ footerNote: null })
  })

  describe("logo", () => {
    it("con un data: válido lo muestra como imagen", () => {
      renderPreview()
      const logo = within(paper()).getByAltText("Logo de la empresa")
      expect(logo).toHaveAttribute("src", PNG_DATA_URI)
    })

    it.each(["https://evil.example/logo.png", "javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zz4="])(
      "un logo inválido (%s) no genera imagen",
      (bad) => {
        renderPreview({ logoDataUri: bad })
        expect(within(paper()).queryByAltText("Logo de la empresa")).toBeNull()
      },
    )

    it("sin logo no hay imagen", () => {
      renderPreview({ logoDataUri: null })
      expect(within(paper()).queryByAltText("Logo de la empresa")).toBeNull()
    })
  })

  describe("la paleta", () => {
    it("pinta el título, la banda de la tabla y el total con los colores de la paleta", () => {
      renderPreview()
      const view = within(paper())
      expect(view.getByText("PRESUPUESTO")).toHaveStyle({ color: "#1d4ed8" })
      expect(view.getByTestId("preview-table-head")).toHaveStyle({ backgroundColor: "#1d4ed8", color: "#ffffff" })
      expect(view.getByTestId("preview-total")).toHaveStyle({ color: "#1d4ed8" })
    })

    it("Neutro: tinta, y la banda en la superficie clara con texto en tinta", () => {
      renderPreview({ palette: NEUTRO_PALETTE as ResolvedPalette })
      const view = within(paper())
      expect(view.getByText("PRESUPUESTO")).toHaveStyle({ color: "#1e293b" })
      expect(view.getByTestId("preview-table-head")).toHaveStyle({ backgroundColor: "#f1f5f9", color: "#1e293b" })
    })

    it("un color inválido de la paleta cae al de Neutro y no entra al estilo", () => {
      renderPreview({ palette: { ...(AZUL_PALETTE as ResolvedPalette), heading: "red;background:url(x)", table_head_fill: "#ABCDEF" } })
      const view = within(paper())
      expect(view.getByText("PRESUPUESTO")).toHaveStyle({ color: "#1e293b" })
      expect(view.getByTestId("preview-table-head")).toHaveStyle({ backgroundColor: "#f1f5f9" })
      expect(paper().outerHTML).not.toContain("url(x)")
    })
  })

  it("REPRESENTA EL PAPEL: fondo blanco explícito (también en tema oscuro)", () => {
    renderPreview()
    expect(paper()).toHaveStyle({ backgroundColor: "#ffffff" })
  })

  it("los textos hostiles se muestran como texto, nunca como HTML", () => {
    renderPreview({ issuer: { ...ISSUER, name: "<img src=x onerror=alert(1)>" }, footerNote: "<script>alert(1)</script>" })
    expect(paper().querySelector("script")).toBeNull()
    expect(within(paper()).getByText("<img src=x onerror=alert(1)>")).toBeInTheDocument()
  })

  describe("logo ancho (360×120) en el encabezado: no se superpone con el bloque del título", () => {
    // jsdom no calcula layout: se fijan las clases de acotación y el e2e mide las cajas reales
    // (frontend/e2e/documentos-marca.spec.ts: el logo termina antes de que empiece el título).
    const logo = () => within(paper()).getByAltText("Logo de la empresa")
    const titleBlock = () => within(paper()).getByText("PRESUPUESTO").parentElement as HTMLElement

    it("el logo se acota al ancho de SU columna (nunca un ancho fijo), con alto máximo y sin deformarse", () => {
      renderPreview()
      const classes = logo().className
      expect(classes).toMatch(/\bmax-w-full\b/)          // como mucho, la columna del emisor
      expect(classes).toMatch(/\bmax-h-\d+\b/)           // y un alto máximo
      expect(classes).toMatch(/\bobject-contain\b/)       // proporción intacta
      expect(classes).not.toMatch(/max-w-\[\d+(\.\d+)?(rem|px)\]/)   // el tope fijo de 10 rem se salía de una columna de ~7 rem
    })

    it("la columna del emisor puede encogerse (min-w-0) y parte las palabras largas", () => {
      renderPreview()
      const column = logo().parentElement as HTMLElement
      expect(column.className).toMatch(/\bmin-w-0\b/)
      expect(paper().className).toMatch(/break-words|\[overflow-wrap:anywhere\]/)
    })

    it("el bloque del título no se encoge ni se deja pisar: ocupa su ancho a la derecha", () => {
      renderPreview()
      expect(titleBlock().className).toMatch(/\bshrink-0\b|\bflex-none\b|\bw-max\b/)
      expect(titleBlock().className).toMatch(/\btext-right\b/)
    })

    it("el encabezado reparte columna del emisor (flexible) + título (a su contenido), como el PDF", () => {
      renderPreview()
      const row = (logo().parentElement as HTMLElement).parentElement as HTMLElement
      expect(row.className).toMatch(/grid-cols-\[minmax\(0,1fr\)_auto\]/)
    })
  })

  it("no desborda su contenedor a 360 px: usa ancho fluido y permite partir las palabras largas", () => {
    renderPreview({ issuer: { ...ISSUER, email: "un.correo.muy.largo.del.negocio@dominio-largo-de-ejemplo.com.ar" } })
    expect(paper().className).toMatch(/\bw-full\b/)
    expect(paper().className).toMatch(/\bmax-w-/)
    expect(paper().className).toMatch(/break-words|\[overflow-wrap:anywhere\]/)
  })
})
