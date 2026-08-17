import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ProjectStore } from "../src/store.js";

test("analysis results survive a store restart and deletion is durable", async () => {
  const directory = await mkdtemp(join(tmpdir(), "gitscope-store-test-"));
  const dataFile = join(directory, "results.json");
  try {
    const firstStore = new ProjectStore(dataFile);
    const project = firstStore.save(
      "https://github.com/verified/repository",
      {
        commits: [{
          id: "commit-1",
          shortId: "c1",
          parentIds: [],
          author: "Verified User",
          authoredAt: "2026-08-17T00:00:00.000Z",
          message: "persistent commit",
          refs: ["main"],
          lane: 0,
        }],
        truncated: false,
      },
      {
        totalCommits: 1,
        branches: 1,
        tags: 0,
        contributors: [{ name: "Verified User", commits: 1, additions: 0, deletions: 0 }],
        commitsByWeekday: [0, 1, 0, 0, 0, 0, 0],
        commitsByHour: Array(24).fill(0) as number[],
        hotspots: [],
        availability: { git: "available" },
        generatedAt: "2026-08-17T00:00:00.000Z",
      },
    );

    const restartedStore = new ProjectStore(dataFile);
    assert.equal(restartedStore.get(project.id)?.graph.commits[0].message, "persistent commit");
    assert.equal(restartedStore.delete(project.id), true);
    assert.equal(new ProjectStore(dataFile).get(project.id), undefined);

    const storedText = await readFile(dataFile, "utf8");
    assert.doesNotMatch(storedText, /accessToken|refreshToken|Bearer/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
