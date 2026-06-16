import { createClient } from "@/lib/supabase/client";

const BACKEND_URL = process.env.NEXT_PUBLIC_BACKEND_URL;

if (!BACKEND_URL) {
  throw new Error(
    "[python-client] NEXT_PUBLIC_BACKEND_URL is not defined. " +
      "Set it in your .env.local (e.g. NEXT_PUBLIC_BACKEND_URL=http://localhost:8000)."
  );
}

async function getAuthHeaders(): Promise<HeadersInit> {
  const supabase = createClient();
  // getSession() reads from local storage and auto-refreshes expired tokens.
  const {
    data: { session },
  } = await supabase.auth.getSession();
  const token = session?.access_token ?? "";
  return {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function handleResponse<T>(response: Response): Promise<T> {
  if (response.status === 401) {
    // Token expired or invalid — throw so React Query shows an error state.
    // Do NOT sign out: the middleware will handle session renewal on the next
    // server request, and an API 401 does not mean the user's session is gone.
    throw new Error("No autorizado. Recargá la página si el problema persiste.");
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body.detail ?? response.statusText);
  }
  // 204 No Content (p. ej. DELETE) no trae body: parsear con response.json()
  // tiraría "Unexpected end of JSON input". Devolvemos undefined.
  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

export const pythonClient = {
  async get<T>(path: string): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, { method: "GET", headers });
    return handleResponse<T>(response);
  },

  async post<T>(path: string, body: unknown): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response);
  },

  async put<T>(path: string, body: unknown): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "PUT",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response);
  },

  async patch<T>(path: string, body: unknown): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, {
      method: "PATCH",
      headers,
      body: JSON.stringify(body),
    });
    return handleResponse<T>(response);
  },

  async delete<T>(path: string): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, { method: "DELETE", headers });
    return handleResponse<T>(response);
  },
};
