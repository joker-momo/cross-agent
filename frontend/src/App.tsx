import { useCallback, useEffect, useRef, useState } from "react";
import { Play, Square, FolderPlus, FolderSearch, Loader2, CheckCircle2, XCircle, RefreshCw } from "lucide-react";
import { api, API_BASE, AGENTS, Agent, AgentStatus, Roles } from "./api";

const IN_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

type Phase = "idle" | "running" | "stopped";

interface LogLine {
  kind: "state" | "log" | "verdict" | "stop";
  text: string;
  approved?: boolean;
  iteration?: number;
}

const ROLE_KEYS: (keyof Roles)[] = ["planner", "implementer", "reviewer"];

export default function App() {
  const [projects, setProjects] = useState<string[]>([]);
  const [project, setProject] = useState("");
  const [newPath, setNewPath] = useState("");
  const [request, setRequest] = useState("");
  const [roles, setRoles] = useState<Roles>({
    planner: "claude",
    implementer: "agy",
    reviewer: "claude",
  });
  const [maxIter, setMaxIter] = useState(5);
  const [escalateAfter, setEscalateAfter] = useState(2);

  const [phase, setPhase] = useState<Phase>("idle");
  const [runId, setRunId] = useState<string | null>(null);
  const [lines, setLines] = useState<LogLine[]>([]);
  const [stopReason, setStopReason] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const esRef = useRef<EventSource | null>(null);

  const [backendUp, setBackendUp] = useState(false);
  const [agents, setAgents] = useState<AgentStatus[]>([]);
  const [agentsLoading, setAgentsLoading] = useState(false);

  const loadAgents = useCallback(async () => {
    setAgentsLoading(true);
    try {
      const d = await api.agentsStatus();
      setAgents(d.agents);
    } catch {
      /* backend not ready yet */
    } finally {
      setAgentsLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    // Backend may still be starting (desktop app spawns it on launch).
    const tryLoad = async (attempt = 0) => {
      try {
        const d = await api.listProjects();
        if (cancelled) return;
        setBackendUp(true);
        setProjects(d.projects);
        if (d.projects[0]) setProject((p) => p || d.projects[0]);
        loadAgents();
      } catch {
        if (cancelled || attempt > 30) return;
        setTimeout(() => tryLoad(attempt + 1), 1000);
      }
    };
    tryLoad();
    return () => {
      cancelled = true;
    };
  }, []);

  const registerPath = async (path: string) => {
    const p = path.trim();
    if (!p) return;
    setError(null);
    try {
      const d = await api.addProject(p);
      setProjects(d.projects);
      setProject(d.projects[d.projects.length - 1]);
      setNewPath("");
    } catch (e: any) {
      setError(e.message);
    }
  };

  const browse = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const picked = await open({ directory: true, multiple: false });
      if (typeof picked === "string") await registerPath(picked);
    } catch (e: any) {
      setError(e.message);
    }
  };

  const push = useCallback((l: LogLine) => setLines((p) => [...p, l]), []);

  const startStream = useCallback(
    (id: string) => {
      const es = new EventSource(`${API_BASE}/run/${id}/events`);
      esRef.current = es;
      es.addEventListener("state", (e) => {
        const d = JSON.parse((e as MessageEvent).data);
        push({ kind: "state", text: `${d.state} · iter ${d.iteration}` });
      });
      es.addEventListener("log", (e) => {
        const d = JSON.parse((e as MessageEvent).data);
        push({ kind: "log", text: d.message });
      });
      es.addEventListener("verdict", (e) => {
        const d = JSON.parse((e as MessageEvent).data);
        push({
          kind: "verdict",
          approved: d.approved,
          iteration: d.iteration,
          text: d.approved
            ? `iter ${d.iteration}: APPROVED — ${d.reason}`
            : `iter ${d.iteration}: rejected — ${(d.blocking_issues || []).join("; ")}`,
        });
      });
      es.addEventListener("stop", (e) => {
        const d = JSON.parse((e as MessageEvent).data);
        setStopReason(d.stop_reason);
        push({ kind: "stop", text: `${d.stop_reason} — ${d.message}` });
      });
      es.addEventListener("end", () => {
        setPhase("stopped");
        es.close();
      });
      es.onerror = () => {
        es.close();
        setPhase("stopped");
      };
    },
    [push]
  );

  const run = async () => {
    if (!project || !request.trim()) return;
    setError(null);
    setLines([]);
    setStopReason(null);
    setPhase("running");
    try {
      const { run_id } = await api.startRun({
        project,
        request: request.trim(),
        roles,
        max_iter: maxIter,
        escalate_after: escalateAfter,
      });
      setRunId(run_id);
      startStream(run_id);
    } catch (e: any) {
      setError(e.message);
      setPhase("idle");
    }
  };

  const stop = async () => {
    if (runId) await api.stopRun(runId).catch(() => {});
  };

  useEffect(() => () => esRef.current?.close(), []);

  return (
    <div className="mx-auto max-w-5xl p-6">
      <header className="mb-6 flex items-center gap-3">
        <div className="h-8 w-8 rounded-md bg-primary/20 grid place-items-center text-primary font-bold">
          △
        </div>
        <div>
          <h1 className="text-xl font-semibold leading-none">Trinity</h1>
          <p className="text-sm text-muted-foreground">
            plan → implement → review, across claude / codex / agy
          </p>
        </div>
      </header>

      {!backendUp && (
        <div className="mb-4 flex items-center gap-2 rounded-md border border-border bg-muted px-3 py-2 text-sm text-muted-foreground">
          <Loader2 size={14} className="animate-spin" />
          Connecting to backend on :7777…
        </div>
      )}

      <section className="mb-4 rounded-lg border border-border bg-card p-3">
        <div className="mb-2 flex items-center justify-between">
          <h2 className="text-sm font-medium text-muted-foreground">
            Agent connections
          </h2>
          <button
            onClick={loadAgents}
            disabled={agentsLoading || !backendUp}
            className="inline-flex items-center gap-1 rounded px-2 py-1 text-xs text-muted-foreground hover:text-foreground disabled:opacity-40"
          >
            <RefreshCw
              size={12}
              className={agentsLoading ? "animate-spin" : ""}
            />
            Recheck
          </button>
        </div>
        <div className="grid grid-cols-3 gap-2">
          {AGENTS.map((a) => {
            const s = agents.find((x) => x.agent === a);
            return <AgentBadge key={a} agent={a} status={s} />;
          })}
        </div>
      </section>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {/* --- Setup --- */}
        <Card title="Task">
          <Label>Project</Label>
          <div className="flex gap-2">
            <select
              className="flex-1 rounded-md border border-border bg-muted px-2 py-1.5 text-sm"
              value={project}
              onChange={(e) => setProject(e.target.value)}
            >
              {projects.length === 0 && <option value="">no projects yet</option>}
              {projects.map((p) => (
                <option key={p} value={p}>
                  {p}
                </option>
              ))}
            </select>
          </div>
          <div className="mt-2 flex gap-2">
            <input
              className="flex-1 rounded-md border border-border bg-muted px-2 py-1.5 text-sm"
              placeholder="/path/to/project"
              value={newPath}
              onChange={(e) => setNewPath(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && registerPath(newPath)}
            />
            {IN_TAURI && (
              <Btn onClick={browse}>
                <FolderSearch size={15} /> Browse
              </Btn>
            )}
            <Btn onClick={() => registerPath(newPath)} disabled={!newPath.trim()}>
              <FolderPlus size={15} /> Add
            </Btn>
          </div>

          <Label className="mt-4">Request</Label>
          <textarea
            className="h-24 w-full resize-none rounded-md border border-border bg-muted px-2 py-1.5 text-sm"
            placeholder="Describe the task…"
            value={request}
            onChange={(e) => setRequest(e.target.value)}
          />

          <div className="mt-4 grid grid-cols-3 gap-2">
            {ROLE_KEYS.map((rk) => (
              <div key={rk}>
                <Label className="capitalize">{rk}</Label>
                <select
                  className="w-full rounded-md border border-border bg-muted px-2 py-1.5 text-sm capitalize"
                  value={roles[rk]}
                  onChange={(e) =>
                    setRoles({ ...roles, [rk]: e.target.value as Agent })
                  }
                >
                  {AGENTS.map((a) => (
                    <option key={a} value={a}>
                      {a}
                    </option>
                  ))}
                </select>
              </div>
            ))}
          </div>

          <div className="mt-3 grid grid-cols-2 gap-2">
            <div>
              <Label>max iterations</Label>
              <input
                type="number"
                min={1}
                className="w-full rounded-md border border-border bg-muted px-2 py-1.5 text-sm"
                value={maxIter}
                onChange={(e) => setMaxIter(+e.target.value)}
              />
            </div>
            <div>
              <Label>escalate after</Label>
              <input
                type="number"
                min={1}
                className="w-full rounded-md border border-border bg-muted px-2 py-1.5 text-sm"
                value={escalateAfter}
                onChange={(e) => setEscalateAfter(+e.target.value)}
              />
            </div>
          </div>

          <div className="mt-4 flex gap-2">
            <Btn
              primary
              onClick={run}
              disabled={phase === "running" || !project || !request.trim()}
            >
              {phase === "running" ? (
                <Loader2 size={15} className="animate-spin" />
              ) : (
                <Play size={15} />
              )}
              Run
            </Btn>
            <Btn onClick={stop} disabled={phase !== "running"}>
              <Square size={15} /> Stop
            </Btn>
          </div>
          {error && <p className="mt-2 text-sm text-red-400">{error}</p>}
        </Card>

        {/* --- Live board --- */}
        <Card title="Live board">
          {lines.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No activity yet. Start a run.
            </p>
          ) : (
            <div className="flex flex-col gap-1 font-mono text-[13px]">
              {lines.map((l, i) => (
                <Line key={i} l={l} />
              ))}
            </div>
          )}
          {stopReason && (
            <div className="mt-4 rounded-md border border-border bg-muted px-3 py-2 text-sm">
              <span className="text-muted-foreground">stop_reason: </span>
              <span
                className={
                  stopReason === "approved" ? "text-primary" : "text-red-400"
                }
              >
                {stopReason}
              </span>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

function AgentBadge({
  agent,
  status,
}: {
  agent: Agent;
  status?: AgentStatus;
}) {
  const st = status?.status ?? "unknown";
  const color =
    st === "ready"
      ? "bg-primary"
      : st === "error"
      ? "bg-amber-400"
      : st === "missing"
      ? "bg-red-500"
      : "bg-muted-foreground";
  const label =
    st === "ready"
      ? "connected"
      : st === "missing"
      ? "not installed"
      : st === "error"
      ? "error"
      : "checking…";
  const tip = status?.version || status?.detail || "";
  return (
    <div
      title={tip}
      className="flex items-center gap-2 rounded-md border border-border bg-muted px-2.5 py-1.5"
    >
      <span className={`h-2 w-2 shrink-0 rounded-full ${color}`} />
      <div className="min-w-0">
        <div className="text-sm font-medium capitalize leading-none">
          {agent}
        </div>
        <div className="truncate text-[11px] text-muted-foreground">
          {label}
        </div>
      </div>
    </div>
  );
}

function Line({ l }: { l: LogLine }) {
  if (l.kind === "verdict")
    return (
      <div className="flex items-center gap-1.5">
        {l.approved ? (
          <CheckCircle2 size={14} className="text-primary" />
        ) : (
          <XCircle size={14} className="text-red-400" />
        )}
        <span>{l.text}</span>
      </div>
    );
  if (l.kind === "state")
    return <div className="text-primary/80">▸ {l.text}</div>;
  if (l.kind === "stop")
    return <div className="text-amber-400">■ {l.text}</div>;
  return <div className="text-muted-foreground">· {l.text}</div>;
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg border border-border bg-card p-4">
      <h2 className="mb-3 text-sm font-medium text-muted-foreground">{title}</h2>
      {children}
    </section>
  );
}

function Label({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <label className={`mb-1 block text-xs text-muted-foreground ${className}`}>
      {children}
    </label>
  );
}

function Btn({
  children,
  onClick,
  disabled,
  primary,
}: {
  children: React.ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  primary?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium transition disabled:opacity-40 ${
        primary
          ? "bg-primary text-primary-foreground hover:bg-primary/90"
          : "border border-border bg-muted hover:bg-border"
      }`}
    >
      {children}
    </button>
  );
}
