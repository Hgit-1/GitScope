import Fastify from "fastify";
import cors from "@fastify/cors";
import { z } from "zod";
import { analyzeRepository } from "./analyzer.js";
import { assertSafeRepositoryUrl, UrlPolicyError } from "./url-policy.js";
import { createJob, deleteResult, getJob, getResult, saveResult, updateJob } from "./store.js";

const app = Fastify({ logger: { redact: ["req.headers.authorization", "body.code", "body.refreshToken", "body.accessToken"] } });
await app.register(cors, { origin: process.env.CORS_ORIGIN?.split(",") || ["http://localhost:4173"] });

app.get("/health", async () => ({ status: "ok", service: "gitscope-api", now: new Date().toISOString() }));

const jobBody = z.object({ url: z.string().min(8).max(2048) });
app.post("/v1/analysis-jobs", async (request, reply) => {
  const parsedBody = jobBody.safeParse(request.body);
  if (!parsedBody.success) return reply.code(400).send({ error: "仓库地址无效" });
  const bearer = request.headers.authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  const tokenTarget = URL.canParse(parsedBody.data.url) ? new URL(parsedBody.data.url).hostname.toLowerCase() : "";
  if (bearer && tokenTarget !== "github.com") {
    return reply.code(400).send({ error: "GitHub 访问令牌只能发送到 github.com" });
  }
  try { await assertSafeRepositoryUrl(parsedBody.data.url); } catch (error) { return reply.code(400).send({ error: error instanceof Error ? error.message : "仓库地址被安全策略拒绝" }); }
  const job = createJob(parsedBody.data.url);
  void runJob(job.id, parsedBody.data.url, bearer);
  return reply.code(202).send(job);
});

async function runJob(jobId: string, url: string, token?: string): Promise<void> {
  try {
    updateJob(jobId, { status: "validating", stage: "重新验证仓库地址", progress: 8 });
    const safeUrl = await assertSafeRepositoryUrl(url);
    updateJob(jobId, { status: "cloning", stage: "临时克隆仓库", progress: 24 });
    const result = await analyzeRepository(safeUrl.toString(), token);
    updateJob(jobId, { status: "analyzing", stage: "生成图谱与工程指标", progress: 82 });
    const project = saveResult(safeUrl.toString(), result.graph, result.report);
    updateJob(jobId, { status: "completed", stage: "分析完成，临时源码已删除", progress: 100, projectId: project.id });
  } catch (error) {
    const message = error instanceof UrlPolicyError ? error.message : error instanceof Error ? error.message : "未知分析错误";
    updateJob(jobId, { status: "failed", stage: "分析失败", progress: 100, error: message.replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]") });
  }
}

app.get<{ Params: { id: string } }>("/v1/analysis-jobs/:id", async (request, reply) => {
  const job = getJob(request.params.id);
  return job || reply.code(404).send({ error: "找不到分析任务" });
});
app.get<{ Params: { id: string }; Querystring: { cursor?: string } }>("/v1/projects/:id/graph", async (request, reply) => {
  const project = getResult(request.params.id); if (!project) return reply.code(404).send({ error: "找不到项目" });
  const offset = Math.max(0, Number(request.query.cursor || 0));
  const page = project.graph.commits.slice(offset, offset + 300);
  return { commits: page, nextCursor: offset + 300 < project.graph.commits.length ? String(offset + 300) : undefined, truncated: project.graph.truncated };
});
app.get<{ Params: { id: string } }>("/v1/projects/:id/reports", async (request, reply) => getResult(request.params.id)?.report || reply.code(404).send({ error: "找不到项目" }));
app.delete<{ Params: { id: string } }>("/v1/projects/:id", async (request, reply) => deleteResult(request.params.id) ? reply.code(204).send() : reply.code(404).send({ error: "找不到项目" }));

const authBody = z.object({ code: z.string().min(4), codeVerifier: z.string().min(43), redirectUri: z.string().url() });
app.post("/v1/auth/github/exchange", async (request, reply) => {
  const body = authBody.safeParse(request.body); if (!body.success) return reply.code(400).send({ error: "OAuth 参数无效" });
  const clientId = process.env.GITHUB_CLIENT_ID; const clientSecret = process.env.GITHUB_CLIENT_SECRET;
  if (!clientId || !clientSecret) return reply.code(503).send({ error: "GitHub App 尚未配置" });
  const response = await fetch("https://github.com/login/oauth/access_token", { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify({ client_id: clientId, client_secret: clientSecret, code: body.data.code, redirect_uri: body.data.redirectUri, code_verifier: body.data.codeVerifier }) });
  const data = await response.json() as Record<string, unknown>;
  return response.ok && !data.error ? reply.send(data) : reply.code(401).send({ error: "GitHub 授权交换失败" });
});

const refreshBody = z.object({ refreshToken: z.string().min(16) });
app.post("/v1/auth/github/refresh", async (request, reply) => {
  const body = refreshBody.safeParse(request.body); if (!body.success) return reply.code(400).send({ error: "刷新令牌无效" });
  const clientId = process.env.GITHUB_CLIENT_ID; const clientSecret = process.env.GITHUB_CLIENT_SECRET;
  if (!clientId || !clientSecret) return reply.code(503).send({ error: "GitHub App 尚未配置" });
  const response = await fetch("https://github.com/login/oauth/access_token", { method: "POST", headers: { accept: "application/json", "content-type": "application/json" }, body: JSON.stringify({ client_id: clientId, client_secret: clientSecret, grant_type: "refresh_token", refresh_token: body.data.refreshToken }) });
  const data = await response.json() as Record<string, unknown>;
  return response.ok && !data.error ? reply.send(data) : reply.code(401).send({ error: "GitHub 令牌刷新失败" });
});

const revokeBody = z.object({ accessToken: z.string().min(16) });
app.post("/v1/auth/github/revoke", async (request, reply) => {
  const body = revokeBody.safeParse(request.body); if (!body.success) return reply.code(400).send({ error: "访问令牌无效" });
  const clientId = process.env.GITHUB_CLIENT_ID; const clientSecret = process.env.GITHUB_CLIENT_SECRET;
  if (!clientId || !clientSecret) return reply.code(503).send({ error: "GitHub App 尚未配置" });
  const basic = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
  const response = await fetch(`https://api.github.com/applications/${encodeURIComponent(clientId)}/token`, { method: "DELETE", headers: { accept: "application/vnd.github+json", authorization: `Basic ${basic}`, "content-type": "application/json", "x-github-api-version": "2022-11-28" }, body: JSON.stringify({ access_token: body.data.accessToken }) });
  return response.ok ? reply.code(204).send() : reply.code(502).send({ error: "GitHub 授权撤销失败" });
});

const port = Number(process.env.PORT || 8080);
if (process.env.NODE_ENV !== "test") await app.listen({ host: "0.0.0.0", port });
export { app };
