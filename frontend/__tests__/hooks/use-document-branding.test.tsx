/**
 * documentos-marca-empresa (task 9.3) — hooks de la marca de la cuenta.
 *
 *   useDocumentBranding        GET /document-branding (respuesta inválida → Neutro sin romper)
 *   useUpdateDocumentBranding  PUT; guardar invalida la marca Y los presupuestos y remitos
 *                              (su `issuer_name` sigue la cascada)
 *   useUploadDocumentLogo      PUT binario del logo
 *   useDeleteDocumentLogo      DELETE del logo
 *   useDocumentLogoDataUri     el logo como data: URI, sólo si hay huella
 */
import React from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, renderHook, waitFor } from "@testing-library/react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/api/document-logo", async () => {
  const actual = await vi.importActual<typeof import("@/lib/api/document-logo")>("@/lib/api/document-logo")
  return { ...actual, uploadDocumentLogo: vi.fn(), fetchDocumentLogoDataUri: vi.fn() }
})

import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentLogoDataUri, uploadDocumentLogo } from "@/lib/api/document-logo"
import {
  useDeleteDocumentLogo,
  useDocumentBranding,
  useDocumentLogoDataUri,
  useUpdateDocumentBranding,
  useUploadDocumentLogo,
} from "@/hooks/data/use-document-branding"
import { queryKeys } from "@/lib/query-keys"
import { DEFAULT_DOCUMENT_BRANDING, emptyBrandingForm, formToPayload } from "@/lib/document-branding"

const BRANDED = {
  ...DEFAULT_DOCUMENT_BRANDING,
  is_default: false,
  settings: { ...DEFAULT_DOCUMENT_BRANDING.settings, display_name: "Sumar", palette_preset: "azul" as const },
  issuer: { ...DEFAULT_DOCUMENT_BRANDING.issuer, name: "Sumar" },
  palette: { ...DEFAULT_DOCUMENT_BRANDING.palette, key: "azul", accent: "#1d4ed8", heading: "#1d4ed8" },
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const invalidate = vi.spyOn(queryClient, "invalidateQueries")
  return {
    queryClient,
    invalidate,
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
  }
}

beforeEach(() => vi.clearAllMocks())

describe("claves de caché", () => {
  it("documentBranding.all / detail / logo", () => {
    expect(queryKeys.documentBranding.all()).toEqual(["documentBranding"])
    expect(queryKeys.documentBranding.detail()).toEqual(["documentBranding", "detail"])
    expect(queryKeys.documentBranding.logo("abc")).toEqual(["documentBranding", "logo", "abc"])
  })
})

describe("useDocumentBranding", () => {
  it("GET /document-branding y devuelve la marca", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(BRANDED)
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentBranding(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(pythonClient.get).toHaveBeenCalledWith("/document-branding")
    expect(result.current.branding.issuer.name).toBe("Sumar")
    expect(result.current.branding.palette.key).toBe("azul")
  })

  it("mientras carga devuelve los valores por defecto (Neutro) en vez de undefined", () => {
    vi.mocked(pythonClient.get).mockReturnValue(new Promise(() => undefined))
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentBranding(), { wrapper: Wrapper })
    expect(result.current.isLoading).toBe(true)
    expect(result.current.branding).toEqual(DEFAULT_DOCUMENT_BRANDING)
  })

  it("una respuesta inválida cae a los valores por defecto sin romper", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({ garbage: true })
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentBranding(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.branding).toEqual(DEFAULT_DOCUMENT_BRANDING)
    expect(result.current.isError).toBe(false)
  })

  it("un error de red deja los valores por defecto y marca isError", async () => {
    vi.mocked(pythonClient.get).mockRejectedValueOnce(new Error("404"))
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentBranding(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.branding).toEqual(DEFAULT_DOCUMENT_BRANDING)
  })

  it("se cachea 5 minutos", () => {
    vi.mocked(pythonClient.get).mockResolvedValue(BRANDED)
    const { Wrapper, queryClient } = makeWrapper()
    renderHook(() => useDocumentBranding(), { wrapper: Wrapper })
    const query = queryClient.getQueryCache().find({ queryKey: queryKeys.documentBranding.detail() })
    expect((query?.options as { staleTime?: number }).staleTime).toBe(5 * 60 * 1000)
  })
})

describe("useUpdateDocumentBranding", () => {
  it("PUT con el payload y devuelve la marca parseada", async () => {
    vi.mocked(pythonClient.put).mockResolvedValueOnce(BRANDED)
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useUpdateDocumentBranding(), { wrapper: Wrapper })
    const payload = formToPayload({ ...emptyBrandingForm(), display_name: "Sumar", palette_preset: "azul" })

    let saved
    await act(async () => { saved = await result.current.mutateAsync(payload) })

    expect(pythonClient.put).toHaveBeenCalledWith("/document-branding", payload)
    expect((saved as unknown as typeof BRANDED).issuer.name).toBe("Sumar")
  })

  it("guardar invalida la marca Y los presupuestos y remitos (su issuer_name sigue la cascada)", async () => {
    vi.mocked(pythonClient.put).mockResolvedValueOnce(BRANDED)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUpdateDocumentBranding(), { wrapper: Wrapper })
    await act(async () => { await result.current.mutateAsync(formToPayload(emptyBrandingForm())) })

    const keys = invalidate.mock.calls.map((c) => (c[0] as { queryKey: unknown }).queryKey)
    expect(keys).toContainEqual(queryKeys.documentBranding.all())
    expect(keys).toContainEqual(queryKeys.quotes.all())
    expect(keys).toContainEqual(queryKeys.deliveryNotes.all())
  })

  it("un 403/422 no invalida nada y llega al caller", async () => {
    vi.mocked(pythonClient.put).mockRejectedValueOnce(new Error("Rol insuficiente"))
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUpdateDocumentBranding(), { wrapper: Wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync(formToPayload(emptyBrandingForm()))).rejects.toThrow("Rol insuficiente")
    })
    expect(invalidate).not.toHaveBeenCalled()
  })
})

describe("useUploadDocumentLogo / useDeleteDocumentLogo", () => {
  const file = new File([new Uint8Array([1])], "logo.png", { type: "image/png" })

  it("sube el archivo y refresca la marca", async () => {
    vi.mocked(uploadDocumentLogo).mockResolvedValueOnce({ sha256: "a".repeat(64), mime: "image/png", width: 10, height: 10 })
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUploadDocumentLogo(), { wrapper: Wrapper })
    await act(async () => { await result.current.mutateAsync(file) })
    expect(uploadDocumentLogo).toHaveBeenCalledWith(file)
    expect(invalidate.mock.calls.map((c) => (c[0] as { queryKey: unknown }).queryKey)).toContainEqual(queryKeys.documentBranding.all())
  })

  it("si la sesión venció (null) no refresca nada", async () => {
    vi.mocked(uploadDocumentLogo).mockResolvedValueOnce(null)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useUploadDocumentLogo(), { wrapper: Wrapper })
    await act(async () => { await result.current.mutateAsync(file) })
    expect(invalidate).not.toHaveBeenCalled()
  })

  it("quitar el logo es DELETE /document-branding/logo y refresca la marca", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)
    const { Wrapper, invalidate } = makeWrapper()
    const { result } = renderHook(() => useDeleteDocumentLogo(), { wrapper: Wrapper })
    await act(async () => { await result.current.mutateAsync() })
    expect(pythonClient.delete).toHaveBeenCalledWith("/document-branding/logo")
    expect(invalidate.mock.calls.map((c) => (c[0] as { queryKey: unknown }).queryKey)).toContainEqual(queryKeys.documentBranding.all())
  })
})

describe("useDocumentLogoDataUri", () => {
  it("sin huella no pide nada", () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentLogoDataUri(null), { wrapper: Wrapper })
    expect(result.current.dataUri).toBeUndefined()
    expect(fetchDocumentLogoDataUri).not.toHaveBeenCalled()
  })

  it("con huella baja el logo una vez y lo cachea por huella", async () => {
    vi.mocked(fetchDocumentLogoDataUri).mockResolvedValue("data:image/png;base64,iVBORw0KGgo=")
    const { Wrapper, queryClient } = makeWrapper()
    const sha = "a".repeat(64)
    const { result } = renderHook(() => useDocumentLogoDataUri(sha), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.dataUri).toBe("data:image/png;base64,iVBORw0KGgo="))
    expect(fetchDocumentLogoDataUri).toHaveBeenCalledWith(sha)
    const query = queryClient.getQueryCache().find({ queryKey: queryKeys.documentBranding.logo(sha) })
    expect((query?.options as { staleTime?: number }).staleTime).toBe(Infinity)
  })

  it("un logo que no se pudo bajar queda en undefined (el comprobante usa la inicial)", async () => {
    vi.mocked(fetchDocumentLogoDataUri).mockResolvedValue(null)
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useDocumentLogoDataUri("b".repeat(64)), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    expect(result.current.dataUri).toBeUndefined()
  })
})
