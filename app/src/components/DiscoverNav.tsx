"use client";
import Link from "next/link";
import { useEffect, useState } from "react";

const STORAGE_KEY = "osh.lastDiscoverUrl";
const VALID_DISCOVER_RE = /^\/discover(\?[^#]*)?$/;

export function isValidDiscoverUrl(v: string | null | undefined): v is string {
  return typeof v === "string" && VALID_DISCOVER_RE.test(v);
}

/** 在发现页记录当前的筛选 URL，以便从详情页返回时恢复筛选条件 */
export function DiscoverMemory({ url }: { url: string }) {
  useEffect(() => {
    if (!isValidDiscoverUrl(url)) return;
    try {
      sessionStorage.setItem(STORAGE_KEY, url);
    } catch {
      /* ignore */
    }
  }, [url]);
  return null;
}

/** 详情页左上角返回链接：优先使用 URL 传入的 from，其次读取同标签页记忆的上一次发现页筛选 URL */
export function BackToDiscover({ initialFrom }: { initialFrom?: string | null }) {
  const validInitial = isValidDiscoverUrl(initialFrom) ? initialFrom : null;
  const [href, setHref] = useState(validInitial ?? "/discover");

  useEffect(() => {
    try {
      if (validInitial) {
        sessionStorage.setItem(STORAGE_KEY, validInitial);
        setHref(validInitial);
      } else {
        const saved = sessionStorage.getItem(STORAGE_KEY);
        if (isValidDiscoverUrl(saved)) setHref(saved);
      }
    } catch {
      /* ignore */
    }
  }, [validInitial]);

  return (
    <Link href={href} className="muted text-sm hover:text-brand-600">
      {href.includes("?") ? "← 返回筛选结果" : "← 返回发现"}
    </Link>
  );
}
