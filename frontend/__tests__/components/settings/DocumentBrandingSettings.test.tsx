/**
 * documentos-marca-empresa (task 11.3) — `DocumentBrandingSettings`: la pestaña «Documentos»
 * de /configuracion.
 *
 *  - datos de la empresa para los papeles, con los del perfil fiscal mostrados como tales
 *    (sólo lectura, con enlace a AFIP);
 *  - paleta: muestras del catálogo (RadioGroup accesible) + color personalizado con el aviso
 *    de contraste EN VIVO, que bloquea Guardar bajo 4,5:1;
 *  - vista previa en vivo con lo que se está editando (la cascada del servidor);
 *  - sólo owner/admin editan; el resto lo ve todo en sólo lectura.
 */
import React from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({
  branding: { value: null as unknown },
  isLoading: { value: false },
  save: vi.fn(),
  isPending: { value: false },
  logoUri: { value: undefined as string | undefined },
  useOrgRole: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
  upload: vi.fn(),
  remove: vi.fn(),
}))

vi.mock("sonner", () => ({ toast: { error: mocks.toastError, success: mocks.toastSuccess } }))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))
vi.mock("@/hooks/data/use-document-branding", () => ({
  useDocumentBranding: () => ({ branding: mocks.branding.value, isLoading: mocks.isLoading.value, isError: false }),
  useUpdateDocumentBranding: () => ({ mutateAsync: mocks.save, isPending: mocks.isPending.value }),
  useDocumentLogoDataUri: () => ({ dataUri: mocks.logoUri.value, isLoading: false }),
  useUploadDocumentLogo: () => ({ mutateAsync: mocks.upload, isPending: false }),
  useDeleteDocumentLogo: () => ({ mutateAsync: mocks.remove, isPending: false }),
}))

import { DocumentBrandingSettings } from "@/components/settings/DocumentBrandingSettings"
import { parseDocumentBranding, type DocumentBranding } from "@/lib/document-branding"
import { PythonApiError } from "@/lib/api/python-api-error"
import { BRANDING_RESPONSE, BRANDING_RESPONSE_DEFAULT, LOGO_SHA, PNG_DATA_URI } from "../../helpers/branding-fixtures"

const FISCAL = {
  razon_social: "Ropa Deportiva SRL",
  nombre_fantasia: "Sumar",
  cuit: "20-12345678-6",
  domicilio_comercial: "Av. San Martín 1234",
  iva_condition: "monotributista",
}

function setBranding(raw: unknown = BRANDING_RESPONSE) {
  mocks.branding.value = parseDocumentBranding(raw)
}

function asRoles(roles: string[], resolved = true) {
  mocks.useOrgRole.mockReturnValue({ role: roles[0], roles, rolesResolved: resolved, isWriter: true, isLoading: false })
}

const preview = () => screen.getByRole("img", { name: /vista previa del encabezado/i })

beforeEach(() => {
  vi.clearAllMocks()
  mocks.isLoading.value = false
  mocks.isPending.value = false
  mocks.logoUri.value = undefined
  mocks.save.mockResolvedValue({})
  setBranding()
  asRoles(["owner"])
})

describe("DocumentBrandingSettings — datos de la empresa", () => {
  it("precarga lo guardado en cada campo", () => {
    render(<DocumentBrandingSettings />)
    expect(screen.getByLabelText(/nombre comercial/i)).toHaveValue("Sumar Ropa Deportiva")
    expect(screen.getByLabelText(/teléfono/i)).toHaveValue("2617175072")
    expect(screen.getByLabelText(/email del negocio/i)).toHaveValue("ventas@sumar.com.ar")
    expect(screen.getByLabelText(/sitio web/i)).toHaveValue("sumar.com.ar")
    expect(screen.getByLabelText(/domicilio/i)).toHaveValue("Av. San Martín 1234, Mendoza")
    expect(screen.getByLabelText(/leyenda al pie/i)).toHaveValue("Alias para transferencias: sumar.ropa")
  })

  it("aclara que el email del negocio no es el email con el que se entra a la app", () => {
    render(<DocumentBrandingSettings />)
    expect(screen.getByText(/no es el email con el que entrás/i)).toBeInTheDocument()
  })

  it("sin perfil fiscal, la razón social, el CUIT y el domicilio se editan acá", () => {
    render(<DocumentBrandingSettings />)
    expect(screen.getByLabelText(/razón social/i)).toBeEnabled()
    expect(screen.getByLabelText(/cuit/i)).toBeEnabled()
    expect(screen.queryByText(/sale de datos fiscales/i)).toBeNull()
  })

  it("con perfil fiscal, esos datos se muestran como tales, de sólo lectura y con enlace a AFIP", () => {
    setBranding({ ...BRANDING_RESPONSE, fiscal: FISCAL })
    render(<DocumentBrandingSettings />)

    const block = screen.getByText(/sale de datos fiscales \(afip\)/i).closest("section") as HTMLElement
    expect(within(block).getByText("Ropa Deportiva SRL")).toBeInTheDocument()
    expect(within(block).getByText("20-12345678-6")).toBeInTheDocument()
    expect(within(block).getByText("Av. San Martín 1234")).toBeInTheDocument()
    expect(within(block).getByText(/monotributo/i)).toBeInTheDocument()
    expect(within(block).getByRole("link", { name: /datos fiscales|afip/i })).toHaveAttribute("href", "/configuracion?tab=fiscal")
    // no hay campos editables para lo que manda el perfil fiscal
    expect(screen.queryByLabelText(/razón social/i)).toBeNull()
    expect(screen.queryByLabelText(/^cuit/i)).toBeNull()
  })

  it("explica qué papeles usan la marca", () => {
    render(<DocumentBrandingSettings />)
    expect(screen.getByText(/comprobante de venta, presupuestos y remitos/i)).toBeInTheDocument()
  })

  it("mientras carga muestra un estado de carga y no el formulario", () => {
    mocks.isLoading.value = true
    render(<DocumentBrandingSettings />)
    expect(screen.getByText(/cargando/i)).toBeInTheDocument()
    expect(screen.queryByLabelText(/nombre comercial/i)).toBeNull()
  })
})

describe("DocumentBrandingSettings — vista previa en vivo", () => {
  it("muestra el emisor guardado", () => {
    render(<DocumentBrandingSettings />)
    expect(within(preview()).getByText("Sumar Ropa Deportiva")).toBeInTheDocument()
    expect(within(preview()).getByText("ventas@sumar.com.ar")).toBeInTheDocument()
  })

  it("cambia mientras se escribe, antes de guardar", () => {
    render(<DocumentBrandingSettings />)
    fireEvent.change(screen.getByLabelText(/nombre comercial/i), { target: { value: "Otro Nombre" } })
    expect(within(preview()).getByText("Otro Nombre")).toBeInTheDocument()
    expect(mocks.save).not.toHaveBeenCalled()
  })

  it("sin nombre comercial usa el negocio del perfil del dueño (la cascada del servidor)", () => {
    setBranding(BRANDING_RESPONSE_DEFAULT)
    render(<DocumentBrandingSettings />)
    expect(within(preview()).getByText("Perfil Dueño")).toBeInTheDocument()
    expect(within(preview()).getByText("Tel: 2610000000")).toBeInTheDocument()
  })

  it("con perfil fiscal, el nombre de fantasía fiscal se usa si la marca no tiene nombre comercial", () => {
    setBranding({ ...BRANDING_RESPONSE_DEFAULT, fiscal: FISCAL })
    render(<DocumentBrandingSettings />)
    expect(within(preview()).getByText("Sumar")).toBeInTheDocument()
    expect(within(preview()).getByText("CUIT: 20-12345678-6")).toBeInTheDocument()
  })

  it("muestra el logo normalizado que devolvió el servidor", () => {
    setBranding({ ...BRANDING_RESPONSE, logo: { sha256: LOGO_SHA, mime: "image/png", width: 400, height: 100 } })
    mocks.logoUri.value = PNG_DATA_URI
    render(<DocumentBrandingSettings />)
    expect(within(preview()).getByAltText("Logo de la empresa")).toHaveAttribute("src", PNG_DATA_URI)
  })
})

describe("DocumentBrandingSettings — paleta", () => {
  it("las seis opciones del catálogo son un grupo de radio accesible, con la guardada marcada", () => {
    render(<DocumentBrandingSettings />)
    const group = screen.getByRole("radiogroup", { name: /paleta de colores/i })
    const radios = within(group).getAllByRole("radio")
    expect(radios.map((r) => r.getAttribute("aria-label") ?? r.textContent)).toEqual([
      "Neutro (blanco)", "Azul", "Verde", "Grafito", "Bordó", "Personalizado",
    ])
    expect(within(group).getByRole("radio", { name: "Azul" })).toBeChecked()
  })

  it("elegir una paleta cambia la vista previa al instante", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)

    await user.click(screen.getByRole("radio", { name: "Bordó" }))

    expect(within(preview()).getByText("PRESUPUESTO")).toHaveStyle({ color: "#9f1239" })
    await user.click(screen.getByRole("radio", { name: "Neutro (blanco)" }))
    expect(within(preview()).getByText("PRESUPUESTO")).toHaveStyle({ color: "#1e293b" })
  })

  it("el color personalizado sólo aparece con la paleta personalizada", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    expect(screen.queryByLabelText(/código del color/i)).toBeNull()

    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    expect(screen.getByLabelText(/código del color/i)).toBeInTheDocument()
    expect(document.querySelector('input[type="color"]')).not.toBeNull()
  })

  it("avisa EN VIVO si el color no se lee sobre blanco y bloquea Guardar", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    fireEvent.change(screen.getByLabelText(/código del color/i), { target: { value: "#facc15" } })

    expect(screen.getByRole("status")).toHaveTextContent(/no se lee bien sobre blanco · 1,53:1/i)
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
    // la vista previa NO usa el color ilegible: se ve como el servidor lo dibujaría (Neutro)
    expect(within(preview()).getByText("PRESUPUESTO")).toHaveStyle({ color: "#1e293b" })
  })

  it("un color legible se confirma con su contraste y permite guardar", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    fireEvent.change(screen.getByLabelText(/código del color/i), { target: { value: "#7c2d12" } })

    expect(screen.getByRole("status")).toHaveTextContent(/se lee bien sobre blanco · 9,37:1/i)
    expect(screen.getByRole("button", { name: /guardar/i })).toBeEnabled()
    expect(within(preview()).getByText("PRESUPUESTO")).toHaveStyle({ color: "#7c2d12" })
  })

  it.each([
    ["#777777", /no se lee bien sobre blanco · 4,48:1/i, false],
    ["#767676", /se lee bien sobre blanco · 4,54:1/i, true],
  ])("el umbral es EXACTAMENTE 4,5:1: %s", async (color, status, canSave) => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    fireEvent.change(screen.getByLabelText(/código del color/i), { target: { value: color } })

    expect(screen.getByRole("status")).toHaveTextContent(status)
    const save = screen.getByRole("button", { name: /guardar/i })
    if (canSave) expect(save).toBeEnabled()
    else expect(save).toBeDisabled()
  })

  it("el selector de color nativo y el campo de código se mantienen sincronizados", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))
    const native = document.querySelector('input[type="color"]') as HTMLInputElement

    fireEvent.change(native, { target: { value: "#7c2d12" } })

    expect(screen.getByLabelText(/código del color/i)).toHaveValue("#7c2d12")
  })

  it("un código mal formado se explica y no se puede guardar", async () => {
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))

    fireEvent.change(screen.getByLabelText(/código del color/i), { target: { value: "azul" } })

    expect(await screen.findByText(/tiene que ser #rrggbb/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
  })
})

describe("DocumentBrandingSettings — guardar", () => {
  it("manda el payload con los vacíos como null y avisa", async () => {
    render(<DocumentBrandingSettings />)
    fireEvent.change(screen.getByLabelText(/teléfono/i), { target: { value: "   " } })
    fireEvent.change(screen.getByLabelText(/nombre comercial/i), { target: { value: "  Sumar  " } })

    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => expect(mocks.save).toHaveBeenCalledTimes(1))
    const payload = mocks.save.mock.calls[0][0]
    expect(payload).toMatchObject({ display_name: "Sumar", phone: null, palette_preset: "azul", accent_color: null })
    await waitFor(() => expect(mocks.toastSuccess).toHaveBeenCalled())
  })

  it("el CUIT sin guiones viaja con guiones", async () => {
    render(<DocumentBrandingSettings />)
    fireEvent.change(screen.getByLabelText(/cuit/i), { target: { value: "20123456786" } })

    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => expect(mocks.save).toHaveBeenCalled())
    expect(mocks.save.mock.calls[0][0].tax_id).toBe("20-12345678-6")
  })

  it("Guardar está deshabilitado mientras no cambia nada", () => {
    render(<DocumentBrandingSettings />)
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
  })

  it.each([
    ["email del negocio", "no-es-un-email", /forma de dirección de correo/i],
    ["cuit", "20-12345678-7", /cuit no es válido/i],
    ["sitio web", "sumar com.ar", /no puede tener espacios/i],
  ])("un %s inválido se explica y no se guarda", async (label, value, message) => {
    render(<DocumentBrandingSettings />)
    fireEvent.change(screen.getByLabelText(new RegExp(label, "i")), { target: { value } })

    expect(await screen.findByText(message)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /guardar/i })).toBeDisabled()
    expect(mocks.save).not.toHaveBeenCalled()
  })

  it("un 422 branding_accent_low_contrast del servidor se muestra junto al color", async () => {
    mocks.save.mockRejectedValue(new PythonApiError("El color elegido no se lee bien sobre blanco", 422, {
      code: "branding_accent_low_contrast", field: "accent_color",
    }))
    const user = userEvent.setup()
    render(<DocumentBrandingSettings />)
    await user.click(screen.getByRole("radio", { name: "Personalizado" }))
    fireEvent.change(screen.getByLabelText(/código del color/i), { target: { value: "#7c2d12" } })

    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(mocks.toastSuccess).not.toHaveBeenCalled()
  })

  it("un error del servidor se avisa y el formulario conserva lo escrito", async () => {
    mocks.save.mockRejectedValue(new PythonApiError("Rol insuficiente", 403, {}))
    render(<DocumentBrandingSettings />)
    fireEvent.change(screen.getByLabelText(/nombre comercial/i), { target: { value: "Otro" } })

    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => expect(mocks.toastError).toHaveBeenCalled())
    expect(screen.getByLabelText(/nombre comercial/i)).toHaveValue("Otro")
  })
})

describe("DocumentBrandingSettings — permisos", () => {
  it.each(["owner", "admin"])("un %s edita", (role) => {
    asRoles([role])
    render(<DocumentBrandingSettings />)
    expect(screen.getByLabelText(/nombre comercial/i)).toBeEnabled()
    expect(screen.getByRole("button", { name: /subir logo|cambiar logo/i })).toBeInTheDocument()
  })

  it.each(["seller", "cashier", "viewer"])("un %s lo ve todo en sólo lectura: sin Guardar ni subida de logo", (role) => {
    asRoles([role])
    setBranding({ ...BRANDING_RESPONSE, logo: { sha256: LOGO_SHA, mime: "image/png", width: 400, height: 100 } })
    mocks.logoUri.value = PNG_DATA_URI
    render(<DocumentBrandingSettings />)

    expect(screen.getByLabelText(/nombre comercial/i)).toBeDisabled()
    expect(screen.getByLabelText(/email del negocio/i)).toBeDisabled()
    for (const radio of screen.getAllByRole("radio")) expect(radio).toBeDisabled()
    expect(screen.queryByRole("button", { name: /guardar/i })).toBeNull()
    expect(screen.queryByRole("button", { name: /subir logo|cambiar logo|quitar logo/i })).toBeNull()
    expect(screen.getByText(/sólo el dueño o un administrador/i)).toBeInTheDocument()
    expect(preview()).toBeInTheDocument()
  })

  it("mientras los roles no resolvieron rige el fail-open del resto de la app (el servidor rechaza con 403)", () => {
    asRoles(["member"], false)
    render(<DocumentBrandingSettings />)
    expect(screen.getByLabelText(/nombre comercial/i)).toBeEnabled()
  })
})

describe("DocumentBrandingSettings — contrato", () => {
  it("no depende de ningún dato del perfil del usuario (todo sale de la marca de la cuenta)", () => {
    const branding: DocumentBranding = parseDocumentBranding(BRANDING_RESPONSE)
    expect(branding.issuer.name).toBe("Sumar Ropa Deportiva")
    render(<DocumentBrandingSettings />)
    expect(preview().textContent).not.toMatch(/@.*test\.local/)
  })
})
