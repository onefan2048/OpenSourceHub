import { Apple, Box, Monitor, Smartphone, TabletSmartphone, Terminal, Globe } from "lucide-react";
import clsx from "clsx";
import { STATUS_META, type RepoStatus } from "@/lib/status";
import { PLATFORM_LABELS, type Platform } from "@/lib/assets";

const TONES = {
  green: "bg-emerald-100 text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-300",
  blue: "bg-sky-100 text-sky-800 dark:bg-sky-500/15 dark:text-sky-300",
  amber: "bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-300",
  gray: "bg-black/5 text-black/60 dark:bg-white/10 dark:text-white/60",
  red: "bg-red-100 text-red-700 dark:bg-red-500/15 dark:text-red-300",
  purple: "bg-violet-100 text-violet-800 dark:bg-violet-500/15 dark:text-violet-300",
} as const;
export type Tone = keyof typeof TONES;

export function Chip({ tone = "gray", children, className, title }: { tone?: Tone; children: React.ReactNode; className?: string; title?: string }) {
  return (
    <span title={title} className={clsx("chip", TONES[tone], className)}>
      {children}
    </span>
  );
}

export function StatusBadge({ status }: { status: string }) {
  const m = STATUS_META[status as RepoStatus] ?? STATUS_META.pending;
  return <Chip tone={m.tone}>{m.label}</Chip>;
}

/** 内容维度徽章：与“长期未更新/归档”等状态并列显示 */
export function contentStatus(r: { hasReleases: boolean; hasAssets: boolean; hasTags: boolean; headSha: string | null; baselineEstablished: boolean }): string {
  if (!r.baselineEstablished) return "pending";
  if (r.hasReleases) return r.hasAssets ? "release_with_assets" : "release_no_assets";
  if (r.hasTags) return "tags_only";
  if (r.headSha) return "commits_only";
  return "source_only";
}

const PICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  macos: Apple,
  windows: Monitor,
  linux: Terminal,
  ios: Smartphone,
  android: TabletSmartphone,
  cross: Globe,
  unknown: Box,
};

export function PlatformIcon({ platform, className }: { platform: string; className?: string }) {
  const I = PICONS[platform] ?? Box;
  return <I className={clsx("size-3.5", className)} />;
}

export function PlatformChip({ platform }: { platform: string }) {
  return (
    <Chip tone="gray">
      <PlatformIcon platform={platform} />
      {PLATFORM_LABELS[platform as Platform] ?? platform}
    </Chip>
  );
}

export function RepoLogo({ src, name, size = 48 }: { src?: string | null; name: string; size?: number }) {
  if (src)
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={src} alt={name} width={size} height={size} className="shrink-0 rounded-2xl bg-white object-cover shadow-sm ring-1 ring-black/5" style={{ width: size, height: size }} loading="lazy" />;
  return (
    <div className="flex shrink-0 items-center justify-center rounded-2xl bg-gradient-to-br from-sky-400 to-brand-600 font-bold text-white" style={{ width: size, height: size, fontSize: size / 2.4 }}>
      {name.slice(0, 1).toUpperCase()}
    </div>
  );
}

export function Empty({ icon, title, desc, children }: { icon?: React.ReactNode; title: string; desc?: string; children?: React.ReactNode }) {
  return (
    <div className="card flex flex-col items-center gap-2 px-6 py-12 text-center">
      {icon && <div className="muted">{icon}</div>}
      <div className="font-semibold">{title}</div>
      {desc && <p className="muted max-w-md text-sm">{desc}</p>}
      {children}
    </div>
  );
}

export function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="rounded-2xl bg-white/70 px-4 py-3 backdrop-blur dark:bg-white/5">
      <div className="text-2xl font-bold tabular-nums">{value}</div>
      <div className="muted text-xs">{label}</div>
      {hint && <div className="muted mt-0.5 text-[11px]">{hint}</div>}
    </div>
  );
}

export const SOURCE_LABEL: Record<string, { label: string; tone: Tone }> = {
  release: { label: "Release", tone: "green" },
  tag: { label: "Tag", tone: "purple" },
  commit: { label: "Commit", tone: "amber" },
  changelog: { label: "Changelog", tone: "blue" },
};

export function SourceChip({ source }: { source: string | null | undefined }) {
  if (!source) return null;
  const m = SOURCE_LABEL[source] ?? { label: source, tone: "gray" as Tone };
  return <Chip tone={m.tone}>{m.label}</Chip>;
}
