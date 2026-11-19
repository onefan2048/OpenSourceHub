import { json, withDb } from "@/lib/api";
import { getSystemStatus } from "@/lib/systemStatus";
export const dynamic = "force-dynamic";
export async function GET() {
  return withDb(async () => json(await getSystemStatus()));
}
