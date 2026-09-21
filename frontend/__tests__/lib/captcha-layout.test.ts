import { describe, expect, it } from "vitest"

import {
  CAPTCHA_MAX_OVERHANG_PX,
  TURNSTILE_FLEXIBLE_MIN_WIDTH_PX,
  pickCaptchaSize,
} from "@/lib/captcha-layout"

/**
 * fix/captcha-widget-mobile-overflow.
 *
 * Turnstile en `size: "flexible"` exige 300 px de ancho: por debajo, el widget
 * no entra. Las 5 pantallas de auth comparten la misma geometría (`p-4` +
 * borde + `p-4`), que en un teléfono de 360 px deja una columna de 294,4 px —
 * medido en navegador real. La regla: tolerar un desborde chico y simétrico
 * dentro del padding de la tarjeta, y por debajo de eso pasar a `compact`
 * (150 px), que es el tamaño que Cloudflare documenta para anchos angostos.
 */
describe("pickCaptchaSize", () => {
  it("usa flexible cuando la columna alcanza el mínimo de Turnstile", () => {
    expect(pickCaptchaSize(TURNSTILE_FLEXIBLE_MIN_WIDTH_PX)).toBe("flexible")
    expect(pickCaptchaSize(448)).toBe("flexible")
  })

  it("sigue en flexible en un teléfono de 360 px (columna de 294,4): el desborde entra en el padding", () => {
    expect(pickCaptchaSize(294.4)).toBe("flexible")
  })

  it("pasa a compact cuando el desborde ya no entra en el padding (viewport de 320 px → columna de 254,4)", () => {
    expect(pickCaptchaSize(254.4)).toBe("compact")
  })

  it("el umbral es el mínimo menos el desborde tolerado por lado, inclusive", () => {
    const threshold = TURNSTILE_FLEXIBLE_MIN_WIDTH_PX - 2 * CAPTCHA_MAX_OVERHANG_PX
    expect(pickCaptchaSize(threshold)).toBe("flexible")
    expect(pickCaptchaSize(threshold - 0.1)).toBe("compact")
  })

  it("sin medida utilizable (0, negativo, NaN) se queda en flexible en vez de achicar a ciegas", () => {
    // jsdom y un contenedor `display: none` reportan 0: no es "angosto", es
    // "no se pudo medir". Achicar ahí degradaría el widget en pantallas anchas.
    expect(pickCaptchaSize(0)).toBe("flexible")
    expect(pickCaptchaSize(-1)).toBe("flexible")
    expect(pickCaptchaSize(Number.NaN)).toBe("flexible")
  })
})
