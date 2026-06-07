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
  const {
    data: { session },
  } = await supabase.auth.getSession();
  const token = session?.access_token ?? "";
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

async function handleResponse<T>(response: Response): Promise<T> {
  if (response.status === 401) {
    const supabase = createClient();
    await supabase.auth.signOut();
    window.location.href = "/auth/login";
    throw new Error("Unauthorized");
  }
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body.detail ?? response.statusText);
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

  async delete<T>(path: string): Promise<T> {
    const headers = await getAuthHeaders();
    const response = await fetch(`${BACKEND_URL as string}${path}`, { method: "DELETE", headers });
    return handleResponse<T>(response);
  },
};
