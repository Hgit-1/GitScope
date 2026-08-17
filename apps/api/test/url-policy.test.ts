import test from "node:test";
import assert from "node:assert/strict";
import { assertSafeRepositoryUrl, isPublicIp, parseRepositoryUrl, UrlPolicyError } from "../src/url-policy.js";

test("accepts a normal HTTPS repository URL", async () => {
  const url = await assertSafeRepositoryUrl("https://github.com/flutter/flutter.git", async () => ["140.82.112.4"]);
  assert.equal(url.hostname, "github.com");
});

test("rejects credentials, non-HTTPS schemes and custom ports", () => {
  assert.throws(() => parseRepositoryUrl("http://github.com/flutter/flutter"), UrlPolicyError);
  assert.throws(() => parseRepositoryUrl("https://token@github.com/flutter/flutter"), UrlPolicyError);
  assert.throws(() => parseRepositoryUrl("https://github.com:8443/flutter/flutter"), UrlPolicyError);
});

test("blocks loopback and private DNS answers", async () => {
  await assert.rejects(() => assertSafeRepositoryUrl("https://git.example.com/acme/mobile", async () => ["127.0.0.1"]), UrlPolicyError);
  await assert.rejects(() => assertSafeRepositoryUrl("https://git.example.com/acme/mobile", async () => ["10.2.3.4"]), UrlPolicyError);
  await assert.rejects(() => assertSafeRepositoryUrl("https://git.example.com/acme/mobile", async () => ["fd00::1"]), UrlPolicyError);
});

test("classifies common public and protected IPs", () => {
  assert.equal(isPublicIp("8.8.8.8"), true);
  assert.equal(isPublicIp("192.168.1.10"), false);
  assert.equal(isPublicIp("2606:4700:4700::1111"), true);
  assert.equal(isPublicIp("::1"), false);
});
