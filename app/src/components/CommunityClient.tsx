"use client";
import { useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw, ChevronDown, Eye, EyeOff } from "lucide-react";
import { Markdown } from "@/components/Markdown";

async function api(url: string, method: string, body?: unknown) {
  const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  const d = await r.json();
  if (!r.ok) throw Error(d.error || d.message || "操作失败");
  return d;
}

/** 下拉框 / 复选框变化时立即提交（与 GitHub 筛选交互一致）；文本框按回车提交 */
export function AutoSubmitForm({ children, className, action }: { children: React.ReactNode; className?: string; action: string }) {
  const ref = useRef<HTMLFormElement>(null);
  return (
    <form
      ref={ref}
      action={action}
      className={className}
      onChange={(e) => {
        const t = e.target as unknown as HTMLInputElement;
        if (t.tagName === "SELECT" || t.type === "checkbox") ref.current?.requestSubmit();
      }}
    >
      {children}
    </form>
  );
}

/** 标签多选（可搜索），与 GitHub 一样多个标签取交集 */
export function LabelPicker({ labels, selected }: { labels: { name: string; color: string | null; description?: string | null }[]; selected: string[] }) {
  const [filter, setFilter] = useState("");
  const shown = useMemo(() => {
    const f = filter.trim().toLowerCase();
    const list = f ? labels.filter((l) => l.name.toLowerCase().includes(f)) : labels;
    return [...list].sort((a, b) => Number(selected.includes(b.name)) - Number(selected.includes(a.name)));
  }, [labels, filter, selected]);
  return (
    <details className="relative">
      <summary className="input flex cursor-pointer list-none items-center justify-between gap-2">
        <span className="truncate">{selected.length ? `标签：${selected.join("、")}` : "所有标签"}</span>
        <ChevronDown size={14} className="shrink-0" />
      </summary>
      <div className="card absolute z-30 mt-1 w-72 p-2 shadow-lg">
        <input className="input mb-2 py-1.5" placeholder={`筛选 ${labels.length} 个标签`} value={filter} onChange={(e) => setFilter(e.target.value)} onKeyDown={(e) => e.key === "Enter" && e.preventDefault()} />
        <div className="max-h-72 overflow-auto">
          {shown.map((l) => (
            <label key={l.name} className="flex cursor-pointer items-start gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-black/5 dark:hover:bg-white/5" title={l.description ?? undefined}>
              <input type="checkbox" name="label" value={l.name} defaultChecked={selected.includes(l.name)} className="mt-1" />
              <span className="mt-1 inline-block h-3 w-3 shrink-0 rounded-full" style={{ backgroundColor: l.color ? `#${l.color}` : "#888" }} />
              <span className="min-w-0">
                <span className="block truncate">{l.name}</span>
                {l.description && <span className="muted block truncate text-xs">{l.description}</span>}
              </span>
            </label>
          ))}
          {shown.length === 0 && <p className="muted px-2 py-3 text-sm">没有匹配的标签</p>}
        </div>
      </div>
    </details>
  );
}

/** 立即同步 / 从头同步 / 开关 */
export function CommunitySyncActions({ repoId, kind, scope }: { repoId: number; kind: "issues" | "discussions"; scope: string }) {
  const [busy, setBusy] = useState(false);
  const r = useRouter();
  const run = async (body: Record<string, unknown>, confirmText?: string) => {
    if (confirmText && !confirm(confirmText)) return;
    setBusy(true);
    try {
      await api(`/api/repos/${repoId}/community`, "POST", { kind, ...body });
      r.refresh();
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  if (scope === "off")
    return (
      <button className="btn-primary" disabled={busy} onClick={() => run({ action: "scope", scope: "all" })}>
        开启同步
      </button>
    );
  return (
    <div className="flex flex-wrap gap-2">
      <button className="btn-ghost" disabled={busy} onClick={() => run({ action: "sync" })}>
        <RefreshCw size={15} className={busy ? "animate-spin" : ""} />
        立即同步
      </button>
      <button className="btn-ghost" disabled={busy} onClick={() => run({ action: "resync" }, "从头重新回填全部数据？已同步的数据会保留并被覆盖更新，大仓库需要较长时间。")}>
        从头回填
      </button>
    </div>
  );
}

/** 展开预览正文（读取本地缓存） */
export function BodyPreview({ repoId, kind, number, baseUrl }: { repoId: number; kind: "issues" | "discussions"; number: number; baseUrl?: string }) {
  const [open, setOpen] = useState(false);
  const [body, setBody] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  return (
    <>
      <button
        type="button"
        className="inline-flex items-center gap-1 text-xs text-brand-600 hover:underline"
        onClick={async () => {
          setOpen(!open);
          if (body === null && !loading) {
            setLoading(true);
            try {
              const d = await api(`/api/repos/${repoId}/community/${kind}/${number}`, "GET");
              setBody(d.body || "_（无正文）_");
            } catch (e) {
              setBody(`加载失败：${(e as Error).message}`);
            } finally {
              setLoading(false);
            }
          }
        }}
      >
        {open ? <EyeOff size={12} /> : <Eye size={12} />}
        {open ? "收起" : "预览"}
      </button>
      {open && <div className="mt-3 basis-full rounded-xl bg-black/[0.03] p-4 text-sm dark:bg-white/[0.04]">{loading || body === null ? <p className="muted">加载中…</p> : <Markdown text={body} baseUrl={baseUrl} />}</div>}
    </>
  );
}
