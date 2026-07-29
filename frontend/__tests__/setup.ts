import '@testing-library/jest-dom'

// jsdom no implementa ResizeObserver, que usan algunos componentes Radix
// (p. ej. Checkbox). Polyfill mínimo para que rendericen en los tests.
if (typeof globalThis.ResizeObserver === 'undefined') {
  globalThis.ResizeObserver = class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
}

// jsdom no implementa matchMedia. Lo usan hooks/ui/use-media-query.ts
// (useIsMobile/useIsTablet/useIsDesktop, usePrefersReducedMotion) y por lo
// tanto cualquier componente de components/motion/* (v4-visual-3d-refresh).
// Default conservador: "no coincide" (no reduced-motion, no breakpoint) —
// los tests que necesiten un valor específico lo sobreescriben localmente
// (ver __tests__/hooks/usePrefersReducedMotion.test.ts, FadeIn.test.tsx,
// ResponsiveModal.test.tsx, etc.), lo cual sigue funcionando porque esto
// solo define un default cuando no existe ninguna implementación.
if (typeof globalThis.matchMedia === 'undefined') {
  globalThis.matchMedia = (query: string) =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
}

// jsdom no implementa IntersectionObserver, que usa
// components/three/Lazy3DCanvas.tsx (v4-visual-3d-refresh Fase B) para montar
// el <Canvas> solo cuando la superficie entra en viewport. Default
// conservador: nunca "entra en viewport" (no dispara el callback) — los
// tests que necesiten simular visibilidad instalan su propio stub controlable
// (ver __tests__/components/three/Lazy3DCanvas.test.tsx).
if (typeof globalThis.IntersectionObserver === 'undefined') {
  globalThis.IntersectionObserver = class IntersectionObserver {
    constructor(_callback: IntersectionObserverCallback, _options?: IntersectionObserverInit) {}
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords(): IntersectionObserverEntry[] {
      return []
    }
    root = null
    rootMargin = ''
    thresholds: ReadonlyArray<number> = []
  } as unknown as typeof IntersectionObserver
}
