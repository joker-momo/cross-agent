// Backend base URL. Empty string in a browser dev server (vite proxy handles
// it); absolute when running inside the Tauri desktop shell, where there is no
// proxy and the UI is served from tauri://localhost.
export const API_BASE =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window
    ? "http://127.0.0.1:7777"
    : "";

export type Agent = "claude" | "codex" | "agy";
export const AGENTS: Agent[] = ["claude", "codex", "agy"];

export interface Roles {
  planner: Agent;
  implementer: Agent;
  reviewer: Agent;
}

export interface RunRecord {
  run_id: string;
  project: string;
  request: string;
  roles: Roles;
  state: string;
  stop_reason: string | null;
  branch: string | null;
  iteration: number;
}

async function json<T>(res: Response): Promise<T> {
  if (!res.ok) {
    const detail = await res.json().catch(() => ({ detail: res.statusText }));
    throw new Error(detail.detail ?? res.statusText);
  }
  return res.json();
}

export interface AgentStatus {
  agent: Agent;
  installed: boolean;
  version: string;
  status: "missing" | "ready" | "error";
  detail: string;
  account: string;
  plan: string;
  quota_hint: string;
  quota_remaining: string;
  can_switch: boolean;
}

const u = (path: string) => `${API_BASE}${path}`;

export const api = {
  agentsStatus: () =>
    fetch(u("/agents")).then((r) => json<{ agents: AgentStatus[] }>(r)),
  listProjects: () =>
    fetch(u("/projects")).then((r) => json<{ projects: string[] }>(r)),
  addProject: (path: string) =>
    fetch(u("/projects"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ path }),
    }).then((r) => json<{ projects: string[] }>(r)),
  startRun: (body: {
    project: string;
    request: string;
    roles: Roles;
    max_iter: number;
    escalate_after: number;
  }) =>
    fetch(u("/runs"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => json<{ run_id: string }>(r)),
  stopRun: (id: string) =>
    fetch(u(`/run/${id}/stop`), { method: "POST" }).then((r) => json(r)),
  switchAccount: (agent: Agent, action = "login") =>
    fetch(u(`/agents/${agent}/account`), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ action }),
    }).then((r) =>
      json<{ agent: Agent; action: string; launched: string }>(r)
    ),
};
