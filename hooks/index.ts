// UI primitives
export { useMounted } from "./ui/use-mounted"
export { useDebounce, useDebouncedCallback } from "./ui/use-debounce"
export { useThrottle } from "./ui/use-throttle"
export { usePrevious } from "./ui/use-previous"
export { useMediaQuery, useIsDesktop, useIsTablet, useIsMobile } from "./ui/use-media-query"
export { useClickOutside } from "./ui/use-click-outside"
export { useHotkeys } from "./ui/use-hotkeys"

// Network
export { useRequestState } from "./network/use-request-state"
export { useOnlineStatus } from "./network/use-online-status"
export { usePolling } from "./network/use-polling"

// Persistence
export { usePersistentState } from "./persistence/use-persistent-state"
export { useCookieState } from "./persistence/use-cookie-state"
export { useSessionStorage } from "./persistence/use-session-storage"

// Tables
export { useTablePreferences } from "./tables/use-table-preferences"
export { useTableSelection } from "./tables/use-table-selection"
export { useTableFilters } from "./tables/use-table-filters"

// Forms
export { useUnsavedChanges } from "./forms/use-unsaved-changes"
export { useAutosave } from "./forms/use-autosave"
export { useFormPersist } from "./forms/use-form-persist"

// Overlays
export { useConfirmDialog } from "./overlays/use-confirm-dialog"
export { useDrawer } from "./overlays/use-drawer"
export { useModalStack } from "./overlays/use-modal-stack"

// Auth
export { usePermissions } from "./auth/use-permissions"
export { useCurrentUser } from "./auth/use-current-user"

// Keyboard
export { useCommandPalette } from "./keyboard/use-command-palette"

// Existing hooks (re-exported for unified import path)
export { useLocalStorage } from "./use-local-storage"
export { usePaginatedQuery } from "./use-paginated-query"
export { useBarcodeScanner } from "./use-barcode-scanner"
export { useUnitsOfMeasure } from "./use-units-of-measure"
export { useGreeting } from "./use-greeting"
export { useToast } from "./use-toast"
