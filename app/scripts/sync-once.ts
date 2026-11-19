// 用法：npm run sync:once -- owner/repo [--full]
import { createGitHubClient } from "../src/lib/github/factory";
import { addRepository } from "../src/lib/repos";
import { syncRepository } from "../src/lib/sync/engine";
import { prisma } from "../src/lib/db";
import { parseRepoInput, repoKey } from "../src/lib/github/parse";

(async () => {
  const input = process.argv[2];
  const gh = await createGitHubClient();
  const ref = parseRepoInput(input);
  if ("error" in ref) throw new Error(ref.error);
  let repo = await prisma.repository.findFirst({ where: { fullNameKey: repoKey(ref.owner, ref.name) } });
  if (!repo) {
    const r = await addRepository(input, gh);
    console.log(r.message);
    if (!r.ok) process.exit(1);
    repo = await prisma.repository.findUniqueOrThrow({ where: { id: r.repository.id } });
  }
  const res = await syncRepository(repo.id, gh, { mode: process.argv.includes("--full") ? "full" : "incremental", trigger: "cli" });
  const { fatal, ...rest } = res;
  console.log(JSON.stringify({ ...rest, fatal: fatal?.message }, null, 2));
  const after = await prisma.repository.findUniqueOrThrow({ where: { id: repo.id } });
  console.log({ status: after.status, latestVersion: after.latestVersion, platforms: after.platforms, hasAssets: after.hasAssets });
  process.exit(res.ok ? 0 : 1);
})();
