import { prisma } from "@/lib/db";
import { json, withDb } from "@/lib/api";

export const dynamic = "force-dynamic";

export async function GET() {
  return withDb(async () => json(await prisma.notification.findMany({ where: { channel: "web" }, orderBy: { createdAt: "desc" }, take: 200, include: { repository: { select: { fullName: true } } } })));
}

/** 标记已读：{ ids: number[] } 或 { all: true } */
export async function POST(req: Request) {
  return withDb(async () => {
    const b = await req.json().catch(() => ({}));
    const where = b.all ? { channel: "web", readAt: null } : { id: { in: (b.ids ?? []).map(Number) } };
    const r = await prisma.notification.updateMany({ where, data: { readAt: new Date() } });
    return json({ updated: r.count });
  });
}
