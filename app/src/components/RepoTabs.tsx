"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

type Tab = { key: string; label: string };
export function RepoTabs({id, tab, tabs, from}:{id:number;tab:string;tabs:string[][];from?:string|null}) {
  const router = useRouter();
  const items:Tab[] = tabs.map(([key,label]) => ({key,label}));
  const [pending,setPending] = useState<string | null>(null);
  const [slow,setSlow] = useState(false);
  const href = (key:string) => `/repos/${id}?tab=${encodeURIComponent(key)}${from?`&from=${encodeURIComponent(from)}`:""}`;
  useEffect(() => { if (pending === tab) { setPending(null); setSlow(false); } }, [tab,pending]);
  useEffect(() => {
    if (!pending) return;
    const timer = window.setTimeout(() => setSlow(true), 5000);
    return () => window.clearTimeout(timer);
  }, [pending]);
  useEffect(() => {
    function onKey(e:KeyboardEvent) {
      const el=e.target as HTMLElement | null;
      if (e.isComposing || el?.isContentEditable || el?.closest('input, textarea, select, [contenteditable="true"]')) return;
      if (!e.altKey || !e.shiftKey || e.ctrlKey || e.metaKey || e.repeat) return;
      const match=/^Digit([1-9])$/.exec(e.code);
      if (!match) return;
      const item=items[Number(match[1])-1];
      if (!item) return;
      e.preventDefault();
      if (item.key === tab) return;
      setSlow(false);setPending(item.key);router.push(href(item.key),{scroll:false});
    }
    document.addEventListener("keydown",onKey);
    return () => document.removeEventListener("keydown",onKey);
  }, [id,tab,router,tabs,from]);
  return <div className="my-5">
    <nav aria-label="项目详情栏目" className="flex gap-2 overflow-x-auto pb-2">
      {items.map(({key,label},i)=><Link key={key} href={href(key)} scroll={false} prefetch={false} aria-current={tab===key?"page":undefined}
        title={i<9?`快捷键：Option/Alt + Shift + ${i+1}`:undefined}
        onNavigate={()=>{if(key!==tab){setSlow(false);setPending(key)}}}
        className={`btn whitespace-nowrap ${tab===key?"bg-brand-600 text-white":"bg-black/5 dark:bg-white/10"}`}>
        {label}{pending===key&&<span aria-hidden="true"> · 切换中…</span>}
      </Link>)}
    </nav>
    <p className="muted mt-1 text-xs">快捷键：Option/Alt + Shift + 1–{Math.min(9,items.length)}，依次切换以上栏目。</p>
    <p role="status" aria-live="polite" className="mt-1 text-sm text-amber-600">{pending?`正在切换到「${items.find(x=>x.key===pending)?.label ?? pending}」${slow?"，等待时间较长，请勿重复点击。":"…"}`:""}</p>
  </div>;
}
