import { isIP } from "node:net";
import { resolve4, resolve6 } from "node:dns/promises";

export class UrlPolicyError extends Error {}

function isPrivateV4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => Number.isNaN(part))) return true;
  const [a, b] = parts;
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224;
}

function isPrivateV6(ip: string): boolean {
  const value = ip.toLowerCase();
  return value === "::" || value === "::1" || value.startsWith("fc") || value.startsWith("fd") || value.startsWith("fe8") || value.startsWith("fe9") || value.startsWith("fea") || value.startsWith("feb") || value.startsWith("::ffff:127.") || value.startsWith("::ffff:10.") || value.startsWith("::ffff:192.168.");
}

export function isPublicIp(address: string): boolean {
  const version = isIP(address);
  if (version === 4) return !isPrivateV4(address);
  if (version === 6) return !isPrivateV6(address);
  return false;
}

export function parseRepositoryUrl(input: string): URL {
  let parsed: URL;
  try { parsed = new URL(input); } catch { throw new UrlPolicyError("仓库地址格式无效"); }
  if (parsed.protocol !== "https:") throw new UrlPolicyError("仅允许 HTTPS 仓库地址");
  if (parsed.username || parsed.password) throw new UrlPolicyError("仓库地址不能包含凭据");
  if (parsed.port && parsed.port !== "443") throw new UrlPolicyError("仅允许标准 HTTPS 端口");
  if (!parsed.hostname || parsed.hostname === "localhost" || parsed.hostname.endsWith(".local")) throw new UrlPolicyError("不允许本机或局域网仓库地址");
  const pathParts = parsed.pathname.replace(/\.git$/, "").split("/").filter(Boolean);
  if (pathParts.length < 2) throw new UrlPolicyError("仓库地址必须包含所有者与仓库名称");
  parsed.hash = "";
  return parsed;
}

export type Resolver = (hostname: string) => Promise<string[]>;

const defaultResolver: Resolver = async (hostname) => {
  if (isIP(hostname)) return [hostname];
  const [v4, v6] = await Promise.all([
    resolve4(hostname).catch(() => []),
    resolve6(hostname).catch(() => []),
  ]);
  return [...v4, ...v6];
};

export async function assertSafeRepositoryUrl(input: string, resolver: Resolver = defaultResolver): Promise<URL> {
  const parsed = parseRepositoryUrl(input);
  const addresses = await resolver(parsed.hostname);
  if (!addresses.length) throw new UrlPolicyError("无法解析仓库域名");
  if (addresses.some((address) => !isPublicIp(address))) throw new UrlPolicyError("仓库域名解析到受保护的网络地址");
  return parsed;
}
