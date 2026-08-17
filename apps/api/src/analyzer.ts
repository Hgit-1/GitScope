import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { CommitNode, EngineeringReport, GraphPage } from "@gitscope/contracts";

const exec = promisify(execFile);
const timeoutMs = Number(process.env.ANALYSIS_TIMEOUT_MS || 300_000);
const maxCommits = Number(process.env.ANALYSIS_MAX_COMMITS || 20_000);

export interface AnalysisResult { graph: GraphPage; report: EngineeringReport; }

function gitEnv(token?: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
  if (token) {
    env.GIT_CONFIG_COUNT = "1";
    env.GIT_CONFIG_KEY_0 = "http.extraHeader";
    env.GIT_CONFIG_VALUE_0 = `Authorization: Bearer ${token}`;
  }
  return env;
}

async function runGit(args: string[], cwd?: string, token?: string, maxBuffer = 32 * 1024 * 1024): Promise<string> {
  const { stdout } = await exec("git", args, { cwd, env: gitEnv(token), timeout: timeoutMs, maxBuffer });
  return stdout;
}

function parseCommits(raw: string): CommitNode[] {
  return raw.split("\x1e").map((record) => record.trim()).filter(Boolean).map((record, index) => {
    const [id, shortId, parents, author, email, authoredAt, refs, message] = record.split("\x1f");
    const refList = (refs || "").split(",").map((ref) => ref.trim().replace(/^\((.*)\)$/, "$1")).filter(Boolean);
    const lane = refList.some((ref) => /docs/i.test(ref)) ? 2 : refList.some((ref) => /feature|fix/i.test(ref)) ? 1 : 0;
    return { id, shortId, parentIds: parents ? parents.split(" ") : [], author, authorEmail: email, authoredAt, refs: refList, message: message || "无提交说明", lane: index === 0 ? 0 : lane };
  });
}

function weekdayAndHour(commits: CommitNode[]): { weekdays: number[]; hours: number[] } {
  const weekdays = Array(7).fill(0) as number[];
  const hours = Array(24).fill(0) as number[];
  for (const commit of commits) { const date = new Date(commit.authoredAt); weekdays[date.getUTCDay()]++; hours[date.getUTCHours()]++; }
  return { weekdays, hours };
}

function parseHotspots(raw: string): Array<{ path: string; changes: number }> {
  const files = new Map<string, number>();
  for (const line of raw.split("\n")) {
    const match = /^(\d+|-)\s+(\d+|-)\s+(.+)$/.exec(line.trim());
    if (!match) continue;
    const additions = match[1] === "-" ? 0 : Number(match[1]);
    const deletions = match[2] === "-" ? 0 : Number(match[2]);
    files.set(match[3], (files.get(match[3]) || 0) + additions + deletions);
  }
  return [...files.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20).map(([path, changes]) => ({ path, changes }));
}

export async function analyzeRepository(url: string, token?: string): Promise<AnalysisResult> {
  const workDir = await mkdtemp(join(tmpdir(), "gitscope-"));
  const repoDir = join(workDir, "repository.git");
  try {
    await runGit(["-c", "core.hooksPath=/dev/null", "clone", "--bare", "--filter=blob:none", "--no-tags", "--single-branch", url, repoDir], undefined, token);
    const logFormat = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1e";
    const logRaw = await runGit(["log", `--max-count=${maxCommits + 1}`, `--pretty=format:${logFormat}`, "HEAD"], repoDir, token);
    const allCommits = parseCommits(logRaw);
    const truncated = allCommits.length > maxCommits;
    const commits = allCommits.slice(0, maxCommits);
    const refsRaw = await runGit(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"], repoDir, token);
    const refs = refsRaw.split("\n").filter(Boolean);
    const branches = refs.filter((ref) => ref.startsWith("refs/heads/")).length;
    const tags = refs.filter((ref) => ref.startsWith("refs/tags/")).length;
    const hotspotRaw = await runGit(["log", "--since=1.year", "--format=", "--numstat", "HEAD"], repoDir, token, 64 * 1024 * 1024).catch(() => "");
    const contributorMap = new Map<string, number>();
    commits.forEach((commit) => contributorMap.set(commit.author, (contributorMap.get(commit.author) || 0) + 1));
    const contributors = [...contributorMap.entries()].sort((a, b) => b[1] - a[1]).slice(0, 50).map(([name, count]) => ({ name, commits: count, additions: 0, deletions: 0 }));
    const { weekdays, hours } = weekdayAndHour(commits);
    return {
      graph: { commits, nextCursor: commits.length > 300 ? "300" : undefined, truncated },
      report: { totalCommits: commits.length, branches, tags, contributors, commitsByWeekday: weekdays, commitsByHour: hours, hotspots: parseHotspots(hotspotRaw), availability: { git: truncated ? "truncated" : "available", pullRequests: "unsupported", issues: "unsupported", releases: "unsupported" }, generatedAt: new Date().toISOString() },
    };
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
