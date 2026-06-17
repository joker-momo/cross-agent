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

export const api = {
  listProjects: () =>
    fetch("/projects").then((r) => json<{ projects: string[] }>(r)),
  addProject: (path: string) =>
    fetch("/projects", {
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
    fetch("/runs", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => json<{ run_id: string }>(r)),
  stopRun: (id: string) =>
    fetch(`/run/${id}/stop`, { method: "POST" }).then((r) => json(r)),
};
