import { describe, it, expect, vi } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { useEditPlanFlow } from "@/hooks/use-edit-plan-flow"
import type { EditPreview, MoneyPlan } from "@/lib/money-plan"

// edicion-operaciones-con-dinero (tanda C, 13.1/13.2): el flujo «guardar → pedir el plan al servidor → confirmar → ejecutar».
// La decisión de mostrar el diálogo es del plan que devolvió el SERVIDOR; el formulario sólo dice si hace falta pedirlo.

const EMPTY: MoneyPlan = {
  writes_money: false,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}
const withCash: EditPreview = {
  dry_run: true,
  plan: { ...EMPTY, writes_money: true, cash: { action: "register", register: { amount: 200 }, reverse: [] } },
  voided_fiscal_document: null,
}
const blocked: EditPreview = {
  ...withCash,
  plan: { ...withCash.plan, blocks: [{ book: "cash", code: "P0426", token: "no_open_session_for_reversal", message: "no_open_session_for_reversal: x" }] },
}
const noEffect: EditPreview = { dry_run: true, plan: EMPTY, voided_fiscal_document: null }

function setup(over: { needsPlan?: boolean; preview?: () => Promise<EditPreview> } = {}) {
  const execute = vi.fn().mockResolvedValue(undefined)
  const onPreviewError = vi.fn()
  const preview = over.preview ?? vi.fn().mockResolvedValue(withCash)
  const hook = renderHook(() =>
    useEditPlanFlow({ needsPlan: over.needsPlan ?? true, preview, execute, onPreviewError }),
  )
  return { ...hook, execute, onPreviewError, preview }
}

describe("useEditPlanFlow", () => {
  it("si el formulario no necesita plan, ejecuta directo y no pide nada al servidor", async () => {
    const { result, execute, preview } = setup({ needsPlan: false })
    await act(async () => { await result.current.requestSave() })
    expect(preview).not.toHaveBeenCalled()
    expect(execute).toHaveBeenCalledTimes(1)
    expect(result.current.dialogOpen).toBe(false)
  })

  it("con plan que escribe dinero: abre el diálogo con la respuesta del servidor y NO ejecuta todavía", async () => {
    const { result, execute } = setup()
    await act(async () => { await result.current.requestSave() })
    expect(execute).not.toHaveBeenCalled()
    expect(result.current.dialogOpen).toBe(true)
    expect(result.current.preview).toBe(withCash)
  })

  it("si el plan no cambia ningún libro, guarda directo sin mostrar el diálogo", async () => {
    const { result, execute } = setup({ preview: vi.fn().mockResolvedValue(noEffect) })
    await act(async () => { await result.current.requestSave() })
    expect(execute).toHaveBeenCalledTimes(1)
    expect(result.current.dialogOpen).toBe(false)
  })

  it("confirmar ejecuta la edición y cierra el diálogo", async () => {
    const { result, execute } = setup()
    await act(async () => { await result.current.requestSave() })
    await act(async () => { await result.current.confirm() })
    expect(execute).toHaveBeenCalledTimes(1)
    expect(result.current.dialogOpen).toBe(false)
    expect(result.current.executing).toBe(false)
  })

  it("con un bloqueo, confirmar no ejecuta (el servidor igual lo rechazaría)", async () => {
    const { result, execute } = setup({ preview: vi.fn().mockResolvedValue(blocked) })
    await act(async () => { await result.current.requestSave() })
    await act(async () => { await result.current.confirm() })
    expect(execute).not.toHaveBeenCalled()
    expect(result.current.dialogOpen).toBe(true)
  })

  it("si la vista previa falla, avisa y no ejecuta ni abre nada", async () => {
    const boom = new Error("boom")
    const { result, execute, onPreviewError } = setup({ preview: vi.fn().mockRejectedValue(boom) })
    await act(async () => { await result.current.requestSave() })
    expect(onPreviewError).toHaveBeenCalledWith(boom)
    expect(execute).not.toHaveBeenCalled()
    expect(result.current.dialogOpen).toBe(false)
    expect(result.current.previewing).toBe(false)
  })

  it("cancelar cierra el diálogo y descarta el plan (el próximo guardado pide uno nuevo)", async () => {
    const { result, preview } = setup()
    await act(async () => { await result.current.requestSave() })
    act(() => { result.current.setDialogOpen(false) })
    expect(result.current.dialogOpen).toBe(false)
    await act(async () => { await result.current.requestSave() })
    expect(preview).toHaveBeenCalledTimes(2)
  })

  it("un segundo guardado mientras se calcula el plan se ignora", async () => {
    let resolve!: (p: EditPreview) => void
    const slow = vi.fn().mockReturnValue(new Promise<EditPreview>((r) => { resolve = r }))
    const { result } = setup({ preview: slow })
    let first!: Promise<void>
    act(() => { first = result.current.requestSave() })
    await act(async () => { await result.current.requestSave() })
    expect(slow).toHaveBeenCalledTimes(1)
    expect(result.current.previewing).toBe(true)
    await act(async () => { resolve(withCash); await first })
    expect(result.current.previewing).toBe(false)
  })
})
