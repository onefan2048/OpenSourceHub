import { NextResponse } from "next/server";
import { ensureSqlitePragmas } from "./db";

export const json = (data: unknown, status = 200) => NextResponse.json(data, { status });
export const bad = (message: string, status = 400) => NextResponse.json({ error: message }, { status });

export async function withDb<T>(fn: () => Promise<T>) {
  await ensureSqlitePragmas();
  return fn();
}
