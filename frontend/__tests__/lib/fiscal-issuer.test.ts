/**
 * factura-fiscal-imprimible (D6/D7, OQ-1) — qué datos del emisor faltan para
 * poder imprimir la factura, y cómo se nombran.
 *
 * Obligatorios para imprimir: razón social, domicilio comercial, inicio de
 * actividades e Ingresos Brutos como número O condición (uno de los dos). El
 * nombre de fantasía es opcional. Los mismos códigos los devuelve el backend
 * en el 409 `issuer_data_incomplete`, así que la etiqueta vive en un solo
 * lugar para la configuración y para el aviso al imprimir.
 */
import { describe, it, expect } from "vitest"

import {
  describeMissingIssuerFields,
  missingIssuerPrintFields,
} from "@/lib/fiscal-issuer"

const completo = {
  razonSocial: "PEREZ MARIA LAURA",
  domicilioComercial: "Av. San Martín 1234, Mendoza",
  iibbNumero: "0712345",
  iibbCondition: null,
  inicioActividades: "2019-03-01",
}

describe("missingIssuerPrintFields", () => {
  it("un perfil completo no tiene faltantes", () => {
    expect(missingIssuerPrintFields(completo)).toEqual([])
  })

  it("el nombre de fantasía no es obligatorio", () => {
    expect(missingIssuerPrintFields({ ...completo })).toEqual([])
  })

  it("lista lo que falta, en el orden de la factura", () => {
    expect(
      missingIssuerPrintFields({ ...completo, domicilioComercial: null, inicioActividades: null }),
    ).toEqual(["domicilio_comercial", "inicio_actividades"])
  })

  it("Ingresos Brutos alcanza con el número O con la condición", () => {
    expect(missingIssuerPrintFields({ ...completo, iibbNumero: null, iibbCondition: "Exento" })).toEqual([])
    expect(missingIssuerPrintFields({ ...completo, iibbNumero: null, iibbCondition: null })).toEqual(["iibb"])
  })

  it("un texto en blanco cuenta como faltante", () => {
    expect(missingIssuerPrintFields({ ...completo, razonSocial: "   " })).toEqual(["razon_social"])
  })

  it("sin perfil falta todo", () => {
    expect(missingIssuerPrintFields(null)).toEqual([
      "razon_social",
      "domicilio_comercial",
      "iibb",
      "inicio_actividades",
    ])
  })
})

describe("describeMissingIssuerFields", () => {
  it("nombra un solo faltante con su artículo", () => {
    expect(describeMissingIssuerFields(["domicilio_comercial"])).toBe("el domicilio comercial")
  })

  it("une dos con «y»", () => {
    expect(describeMissingIssuerFields(["domicilio_comercial", "inicio_actividades"])).toBe(
      "el domicilio comercial y la fecha de inicio de actividades",
    )
  })

  it("une tres o más con comas y «y»", () => {
    expect(describeMissingIssuerFields(["razon_social", "iibb", "inicio_actividades"])).toBe(
      "la razón social, el número o la condición de Ingresos Brutos y la fecha de inicio de actividades",
    )
  })

  it("también nombra los códigos que sólo manda el backend (CUIT, condición IVA)", () => {
    expect(describeMissingIssuerFields(["cuit", "iva_condition"])).toBe(
      "el CUIT y la condición frente al IVA",
    )
  })

  it("un código desconocido no rompe: se muestra tal cual", () => {
    expect(describeMissingIssuerFields(["otro_dato"])).toBe("otro_dato")
  })
})
