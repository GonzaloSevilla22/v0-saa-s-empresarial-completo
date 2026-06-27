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
