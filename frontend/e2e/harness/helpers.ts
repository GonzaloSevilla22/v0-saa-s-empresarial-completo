import type { Locator, Page } from '@playwright/test'

/**
 * Gesto táctil real por CDP (Input.dispatchTouchEvent) — el método del QA del
 * 2026-08-30 (qa/INFORME.md): los clics simulados de Playwright NO reproducen
 * H1, hace falta el touchmove de verdad para que react-remove-scroll tenga
 * algo que cancelar.
 */
export async function touchDragUp(page: Page, x: number, y: number, dy: number): Promise<void> {
  const cdp = await page.context().newCDPSession(page)
  try {
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchStart',
      touchPoints: [{ x, y }],
    })
    const steps = 10
    for (let i = 1; i <= steps; i++) {
      await cdp.send('Input.dispatchTouchEvent', {
        type: 'touchMove',
        touchPoints: [{ x, y: y - (dy * i) / steps }],
      })
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  } finally {
    await cdp.detach()
  }
}

/** Rueda del mouse sobre el centro de un locator. */
export async function wheelOver(page: Page, target: Locator, deltaY: number): Promise<void> {
  const box = await target.boundingBox()
  if (!box) throw new Error('wheelOver: el locator no tiene bounding box')
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.wheel(0, deltaY)
}

export function scrollTopOf(target: Locator): Promise<number> {
  return target.evaluate((el) => el.scrollTop)
}
