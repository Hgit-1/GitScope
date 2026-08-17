import test from "node:test";
import assert from "node:assert/strict";

process.env.NODE_ENV = "test";
const { app } = await import("../src/server.js");
const { saveResult } = await import("../src/store.js");

test("health endpoint reports service status", async () => {
  const response = await app.inject({ method: "GET", url: "/health" });
  assert.equal(response.statusCode, 200);
  assert.equal(response.json().service, "gitscope-api");
});

test("analysis endpoint rejects unsafe repository URLs", async () => {
  const response = await app.inject({ method: "POST", url: "/v1/analysis-jobs", payload: { url: "http://127.0.0.1/private/repo" } });
  assert.equal(response.statusCode, 400);
});

test("analysis endpoint never forwards a GitHub token to another Git host", async () => {
  const response = await app.inject({
    method: "POST",
    url: "/v1/analysis-jobs",
    headers: { authorization: "Bearer github_pat_secret_value" },
    payload: { url: "https://gitlab.com/verified/repository" },
  });
  assert.equal(response.statusCode, 400);
  assert.match(response.json().error, /只能发送到 github\.com/);
});

test("graph, report and delete endpoints operate on analyzed project data", async () => {
  const commits = Array.from({ length: 301 }, (_, index) => ({
    id: `commit-${index}`,
    shortId: `c${index}`,
    parentIds: [],
    author: "Verified User",
    authoredAt: "2026-08-17T00:00:00.000Z",
    message: `commit ${index}`,
    refs: index === 0 ? ["main"] : [],
    lane: 0,
  }));
  const report = {
    totalCommits: 301,
    branches: 1,
    tags: 0,
    contributors: [{ name: "Verified User", commits: 301, additions: 0, deletions: 0 }],
    commitsByWeekday: [0, 301, 0, 0, 0, 0, 0],
    commitsByHour: Array(24).fill(0) as number[],
    hotspots: [],
    availability: { git: "available" as const },
    generatedAt: "2026-08-17T00:00:00.000Z",
  };
  const project = saveResult("https://github.com/verified/repository", { commits, truncated: false, nextCursor: "300" }, report);

  const firstPage = await app.inject({ method: "GET", url: `/v1/projects/${project.id}/graph` });
  assert.equal(firstPage.statusCode, 200);
  assert.equal(firstPage.json().commits.length, 300);
  assert.equal(firstPage.json().nextCursor, "300");

  const secondPage = await app.inject({ method: "GET", url: `/v1/projects/${project.id}/graph?cursor=300` });
  assert.equal(secondPage.json().commits.length, 1);
  assert.equal(secondPage.json().nextCursor, undefined);

  const reportResponse = await app.inject({ method: "GET", url: `/v1/projects/${project.id}/reports` });
  assert.equal(reportResponse.statusCode, 200);
  assert.equal(reportResponse.json().totalCommits, 301);

  const deleted = await app.inject({ method: "DELETE", url: `/v1/projects/${project.id}` });
  assert.equal(deleted.statusCode, 204);
  const missing = await app.inject({ method: "GET", url: `/v1/projects/${project.id}/reports` });
  assert.equal(missing.statusCode, 404);
});

test("GitHub OAuth exchange reports missing server configuration instead of pretending to connect", async () => {
  delete process.env.GITHUB_CLIENT_ID;
  delete process.env.GITHUB_CLIENT_SECRET;
  const response = await app.inject({
    method: "POST",
    url: "/v1/auth/github/exchange",
    payload: {
      code: "valid-code",
      codeVerifier: "v".repeat(43),
      redirectUri: "gitscope://oauth/github",
    },
  });
  assert.equal(response.statusCode, 503);
  assert.match(response.json().error, /尚未配置/);
});

test.after(async () => app.close());
