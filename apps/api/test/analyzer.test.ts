import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { analyzeRepository } from "../src/analyzer.js";

const exec = promisify(execFile);

test("analyzer clones a real Git repository and derives graph and report data", async () => {
  const directory = await mkdtemp(join(tmpdir(), "gitscope-analyzer-test-"));
  try {
    await exec("git", ["init", "-b", "main"], { cwd: directory });
    await exec("git", ["config", "user.name", "Verified User"], { cwd: directory });
    await exec("git", ["config", "user.email", "verified@example.com"], { cwd: directory });
    await writeFile(join(directory, "README.md"), "# Verified repository\n");
    await exec("git", ["add", "README.md"], { cwd: directory });
    await exec("git", ["commit", "-m", "initial verified commit"], { cwd: directory });

    const result = await analyzeRepository(directory);
    assert.equal(result.graph.commits.length, 1);
    assert.equal(result.graph.commits[0].message, "initial verified commit");
    assert.equal(result.report.totalCommits, 1);
    assert.equal(result.report.contributors[0].name, "Verified User");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
