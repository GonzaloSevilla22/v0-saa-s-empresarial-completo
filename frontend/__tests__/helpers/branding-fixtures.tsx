/**
 * documentos-marca-empresa — fixtures y utilidades compartidas por los tests de la marca de
 * la cuenta (botón de comprobante, pestaña "Documentos", hooks).
 *
 *  - `BRANDING_RESPONSE`: lo que devuelve `GET /document-branding` de una cuenta con marca
 *    (paleta azul, logo, contacto y leyenda al pie), tal cual el contrato del servidor.
 *  - `PNG_DATA_URI`: un logo `data:` válido (1×1) para los tests que lo dibujan.
 *  - `renderWithClient`: monta un componente con un `QueryClientProvider` limpio (sin
 *    reintentos), que es lo que necesitan los componentes que leen la marca.
 */
import React from "react"
import { render, type RenderResult } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"

export const LOGO_SHA = "a".repeat(64)

export const PNG_DATA_URI =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

export const AZUL_PALETTE = {
  key: "azul",
  accent: "#1d4ed8",
  ink: "#1e293b",
  muted: "#64748b",
  rule: "#94a3b8",
  surface: "#f1f5f9",
  heading: "#1d4ed8",
  strong_rule: "#1d4ed8",
  table_head_fill: "#1d4ed8",
  table_head_text: "#ffffff",
  total: "#1d4ed8",
  accepted_stamp: "#1d4ed8",
}

export const NEUTRO_PALETTE = {
  key: "neutro",
  accent: null,
  ink: "#1e293b",
  muted: "#64748b",
  rule: "#94a3b8",
  surface: "#f1f5f9",
  heading: "#1e293b",
  strong_rule: "#1e293b",
  table_head_fill: "#f1f5f9",
  table_head_text: "#1e293b",
  total: "#1e293b",
  accepted_stamp: "#1e293b",
}

export const PALETTES = [
  { key: "neutro", label: "Neutro (blanco)", accent: null },
  { key: "azul", label: "Azul", accent: "#1d4ed8" },
  { key: "verde", label: "Verde", accent: "#047857" },
  { key: "grafito", label: "Grafito", accent: "#334155" },
  { key: "bordo", label: "Bordó", accent: "#9f1239" },
  { key: "personalizado", label: "Personalizado", accent: null },
]

/** `GET /document-branding` de una cuenta con marca, sin perfil fiscal. */
export const BRANDING_RESPONSE = {
  settings: {
    display_name: "Sumar Ropa Deportiva",
    legal_name: null,
    tax_id: null,
    address: "Av. San Martín 1234, Mendoza",
    phone: "2617175072",
    email: "ventas@sumar.com.ar",
    website: "sumar.com.ar",
    footer_note: "Alias para transferencias: sumar.ropa",
    palette_preset: "azul",
    accent_color: null,
  },
  is_default: false,
  logo: null as { sha256: string; mime: string; width: number; height: number } | null,
  issuer: {
    name: "Sumar Ropa Deportiva",
    legal_name: null,
    cuit: null,
    iva_legend: null,
    address: "Av. San Martín 1234, Mendoza",
    phone: "2617175072",
    email: "ventas@sumar.com.ar",
    website: "sumar.com.ar",
  },
  sources: { name: "brand", phone: "brand", email: "brand" },
  fiscal: null,
  owner_fallback: { business_name: "Perfil Dueño", phone: "2610000000" },
  footer_note: "Alias para transferencias: sumar.ropa",
  palette: AZUL_PALETTE,
  palettes: PALETTES,
  updated_at: "2026-10-11T12:00:00Z",
  updated_by: "11111111-1111-1111-1111-111111111111",
}

/** `GET /document-branding` de una cuenta que nunca configuró su marca. */
export const BRANDING_RESPONSE_DEFAULT = {
  ...BRANDING_RESPONSE,
  settings: {
    display_name: null, legal_name: null, tax_id: null, address: null, phone: null, email: null,
    website: null, footer_note: null, palette_preset: "neutro", accent_color: null,
  },
  is_default: true,
  issuer: {
    name: "Perfil Dueño", legal_name: null, cuit: null, iva_legend: null, address: null,
    phone: "2610000000", email: null, website: null,
  },
  sources: { name: "owner", phone: "owner" },
  footer_note: null,
  palette: NEUTRO_PALETTE,
  updated_at: null,
  updated_by: null,
}

export function makeQueryClient(): QueryClient {
  return new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
}

export function renderWithClient(ui: React.ReactElement, client: QueryClient = makeQueryClient()): RenderResult & { client: QueryClient } {
  const result = render(React.createElement(QueryClientProvider, { client }, ui))
  return { ...result, client }
}
