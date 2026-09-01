/**
 * seguros-perfil-asesor (task 5.1/5.6): perfil de asesor en /seguros/[slug].
 * Cubre los escenarios del delta spec (insurance-advisor-profile):
 * identidad+matrícula, orden de servicios/pilares, vías de contacto sólo
 * cuando el dato existe, degradación a iniciales sin foto, y slug
 * inexistente sin error no controlado.
 *
 * Mockea el servicio (no el cliente Supabase crudo): insuranceService ya
 * tiene su propia cobertura unitaria en seguros-advisor-profile.test.tsx y
 * seguros-contact-tracking.test.tsx — acá el foco es el render/comportamiento
 * de la página.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Insurance } from "@/lib/services/insuranceService"

// vi.hoisted: vi.mock() se hoistea por encima de CUALQUIER const de nivel
// de módulo (incluida esta), así que las funciones mock tienen que crearse
// dentro de vi.hoisted para existir antes de que corran las factories de
// vi.mock (mismo gotcha que documenta seguros-click-tracking.test.tsx).
const { getAdvisorBySlugMock, incrementContactClickMock } = vi.hoisted(() => ({
  getAdvisorBySlugMock: vi.fn(),
  incrementContactClickMock: vi.fn(),
}))

// insuranceService.ts crea el cliente Supabase a nivel de módulo
// (`const supabase = createClient()`), así que aunque sólo se sobreescriban
// getAdvisorBySlug/incrementContactClick con vi.importActual, ese módulo
// real se ejecuta igual — hay que mockear el cliente para que no explote
// por falta de env vars (mismo patrón que seguros-click-tracking.test.tsx).
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: vi.fn(), schema: vi.fn() }),
}))

vi.mock("@/lib/services/insuranceService", async () => {
  const actual = await vi.importActual<typeof import("@/lib/services/insuranceService")>(
    "@/lib/services/insuranceService"
  )
  return {
    ...actual,
    insuranceService: {
      ...actual.insuranceService,
      getAdvisorBySlug: getAdvisorBySlugMock,
      incrementContactClick: incrementContactClickMock,
    },
  }
})

import AdvisorProfilePage from "@/app/(dashboard)/seguros/[slug]/page"

function makeAdvisor(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "advisor-1",
    title: "Julián Dupás — Productor Asesor de Seguros",
    description: "",
    coverage: "",
    price: "",
    contact_url: "https://www.argbroker.com.ar",
    is_visible: true,
    created_at: "2026-09-01T00:00:00.000Z",
    updated_at: "2026-09-01T00:00:00.000Z",
    entry_type: "advisor",
    slug: "julian-dupas",
    advisor_name: "Julián Dupás",
    advisor_role: "Productor Asesor de Seguros",
    license_number: "98506",
    license_authority: null,
    headline: "Un seguro no termina cuando se emite la póliza.",
    bio: "Mi trabajo comienza con el análisis de cada situación particular.",
    photo_url: null,
    contact_phone: "2266 474348",
    contact_whatsapp: "5492266474348",
    contact_email: "julian_dupas@argbroker.com.ar",
    service_lines: [
      { title: "Autos y motos", description: "Coberturas adaptadas al uso real del vehículo." },
      { title: "Hogar y comercio", description: "Sumas aseguradas actualizadas." },
      { title: "Empresas, flotas y ART", description: "Diseño integral del programa de seguros." },
    ],
    pillars: [
      { title: "Comparación de alternativas", body: "No trabajo con una única aseguradora." },
      { title: "Transparencia y asesoramiento", body: "Explico previamente las condiciones." },
    ],
    coverage_areas: ["Necochea", "Mendoza", "La Plata"],
    disclaimer: "Aliadata no es aseguradora ni intermediaria.",
    contact_clicks: {},
    is_featured: false,
    sort_order: 0,
    ...overrides,
  }
}

function renderPage(slug = "julian-dupas") {
  return render(<AdvisorProfilePage params={Promise.resolve({ slug })} />)
}

beforeEach(() => {
  getAdvisorBySlugMock.mockReset()
  incrementContactClickMock.mockReset().mockResolvedValue(undefined)
})

describe("AdvisorProfilePage — identidad, matrícula y contenido", () => {
  it("renderiza identidad, rol y matrícula", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    expect(await screen.findByRole("heading", { name: /julián dupás/i })).toBeInTheDocument()
    expect(screen.getByText(/productor asesor de seguros/i)).toBeInTheDocument()
    expect(screen.getByText(/mat\.?\s*n\.?º\s*98506/i)).toBeInTheDocument()
  })

  it("lista las líneas de servicio en el mismo orden en que fueron cargadas", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    await screen.findByText("Autos y motos")
    const titles = screen.getAllByText(/autos y motos|hogar y comercio|empresas, flotas y art/i)
    const order = titles.map((el) => el.textContent)
    expect(order[0]).toMatch(/autos y motos/i)
    expect(order[1]).toMatch(/hogar y comercio/i)
    expect(order[2]).toMatch(/empresas, flotas y art/i)
  })

  it("lista los pilares en orden", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    await screen.findByText("Comparación de alternativas")
    expect(screen.getByText("Transparencia y asesoramiento")).toBeInTheDocument()
  })

  it("muestra las zonas de cobertura", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    await screen.findByText("Necochea")
    expect(screen.getByText("Mendoza")).toBeInTheDocument()
    expect(screen.getByText("La Plata")).toBeInTheDocument()
  })

  it("muestra el deslinde de Aliadata cuando está cargado", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    expect(await screen.findByText(/aliadata no es aseguradora ni intermediaria/i)).toBeInTheDocument()
  })

  it("no muestra la leyenda del organismo cuando license_authority está vacío", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor({ license_authority: null }))
    renderPage()

    await screen.findByText(/mat\.?\s*n\.?º\s*98506/i)
    expect(screen.queryByTestId("license-authority")).not.toBeInTheDocument()
  })

  it("muestra la leyenda del organismo cuando sí está cargada", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor({ license_authority: "SSN" }))
    renderPage()

    expect(await screen.findByTestId("license-authority")).toHaveTextContent("SSN")
  })
})

describe("AdvisorProfilePage — vías de contacto", () => {
  it("ofrece las cuatro vías cuando los cuatro datos están cargados", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    const whatsapp = await screen.findByRole("link", { name: /whatsapp/i })
    expect(whatsapp).toHaveAttribute("href", "https://wa.me/5492266474348")
    expect(whatsapp).toHaveAttribute("target", "_blank")
    expect(whatsapp).toHaveAttribute("rel", "noopener noreferrer")

    const email = screen.getByRole("link", { name: /email|mail/i })
    expect(email).toHaveAttribute("href", "mailto:julian_dupas@argbroker.com.ar")

    const phone = screen.getByRole("link", { name: /llamar|teléfono/i })
    expect(phone).toHaveAttribute("href", "tel:2266 474348")

    const web = screen.getByRole("link", { name: /sitio web|web/i })
    expect(web).toHaveAttribute("href", "https://www.argbroker.com.ar")
    expect(web).toHaveAttribute("target", "_blank")
    expect(web).toHaveAttribute("rel", "noopener noreferrer")
  })

  it("omite el botón de WhatsApp cuando contact_whatsapp está vacío, sin dejar un control inerte", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor({ contact_whatsapp: null }))
    renderPage()

    await screen.findByRole("link", { name: /email|mail/i })
    expect(screen.queryByRole("link", { name: /whatsapp/i })).not.toBeInTheDocument()
  })

  it("con sólo el teléfono cargado, ofrece únicamente esa vía", async () => {
    getAdvisorBySlugMock.mockResolvedValue(
      makeAdvisor({ contact_whatsapp: null, contact_email: null, contact_url: "" })
    )
    renderPage()

    await screen.findByRole("link", { name: /llamar|teléfono/i })
    expect(screen.queryByRole("link", { name: /whatsapp/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /email|mail/i })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /sitio web|^web/i })).not.toBeInTheDocument()
  })

  it("dispara el tracking por vía al usar WhatsApp, sin bloquear la navegación", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    const whatsapp = await screen.findByRole("link", { name: /whatsapp/i })
    await userEvent.click(whatsapp)

    await waitFor(() => {
      expect(incrementContactClickMock).toHaveBeenCalledWith("advisor-1", "whatsapp")
    })
    // El link sigue con su href intacto (la navegación real no fue interceptada)
    expect(whatsapp).toHaveAttribute("href", "https://wa.me/5492266474348")
  })

  it("dispara el tracking correcto para email, teléfono y web", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor())
    renderPage()

    await userEvent.click(await screen.findByRole("link", { name: /email|mail/i }))
    await waitFor(() => expect(incrementContactClickMock).toHaveBeenCalledWith("advisor-1", "email"))

    await userEvent.click(screen.getByRole("link", { name: /llamar|teléfono/i }))
    await waitFor(() => expect(incrementContactClickMock).toHaveBeenCalledWith("advisor-1", "phone"))

    await userEvent.click(screen.getByRole("link", { name: /sitio web|^web/i }))
    await waitFor(() => expect(incrementContactClickMock).toHaveBeenCalledWith("advisor-1", "web"))
  })
})

describe("AdvisorProfilePage — avatar", () => {
  it("sin photo_url rinde las iniciales derivadas del nombre", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor({ photo_url: null }))
    renderPage()

    expect(await screen.findByText("JD")).toBeInTheDocument()
  })

  it("con photo_url renderiza la imagen, no las iniciales", async () => {
    getAdvisorBySlugMock.mockResolvedValue(makeAdvisor({ photo_url: "/julian-dupas.jpg" }))
    renderPage()

    const img = await screen.findByRole("img", { name: /julián dupás/i })
    expect(img).toHaveAttribute("src", expect.stringContaining("julian-dupas.jpg"))
  })
})

describe("AdvisorProfilePage — casos límite", () => {
  it("un asesor sin listas cargadas no rompe: identidad y contacto sin secciones vacías", async () => {
    getAdvisorBySlugMock.mockResolvedValue(
      makeAdvisor({ service_lines: [], pillars: [], coverage_areas: [] })
    )
    renderPage()

    expect(await screen.findByRole("heading", { name: /julián dupás/i })).toBeInTheDocument()
    expect(screen.queryByText("Autos y motos")).not.toBeInTheDocument()
  })

  it("slug inexistente muestra la pantalla de no encontrado sin lanzar", async () => {
    getAdvisorBySlugMock.mockResolvedValue(null)
    renderPage("no-existe")

    expect(await screen.findByText(/no (se )?encontr/i)).toBeInTheDocument()
  })
})
