#!/usr/bin/env node

import assert from "node:assert/strict";
import { BlockList, isIP } from "node:net";

const blockedIpv4 = new BlockList();
const blockedIpv6 = new BlockList();

for (const [network, prefix] of [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.168.0.0", 16],
]) {
  blockedIpv4.addSubnet(network, prefix, "ipv4");
}

for (const [network, prefix] of [
  ["::", 128],
  ["::1", 128],
  ["fc00::", 7],
  ["fe80::", 10],
]) {
  blockedIpv6.addSubnet(network, prefix, "ipv6");
}

function fail(message) {
  throw new Error(message);
}

export function validatePublicOrigin(value) {
  if (value !== value.trim() || !value.toLowerCase().startsWith("https://")) {
    fail("must be an exact HTTPS origin");
  }

  let url;
  try {
    url = new URL(value);
  } catch {
    fail("must be a valid URL");
  }

  if (url.protocol !== "https:") fail("must use HTTPS");
  if (url.username || url.password) fail("must not contain credentials");
  const authority = value.slice("https://".length);
  if (
    authority.search(/[/?#]/) !== -1 ||
    url.pathname !== "/" ||
    url.search ||
    url.hash
  ) {
    fail("must be an origin only, without a path, query, or fragment");
  }

  if (url.port) {
    const port = Number(url.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      fail("must contain a valid port");
    }
  }

  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const addressFamily = isIP(hostname);
  if (addressFamily) {
    const blocked =
      addressFamily === 4
        ? blockedIpv4.check(hostname, "ipv4")
        : hostname.toLowerCase().startsWith("::ffff:") ||
          blockedIpv6.check(hostname, "ipv6");
    if (blocked) {
      fail("must not use a private, loopback, or internal IP address");
    }
    return;
  }

  if (hostname.length > 253) fail("must contain a valid DNS hostname");
  const labels = hostname.split(".");
  if (
    labels.some(
      (label) =>
        label.length < 1 ||
        label.length > 63 ||
        !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label),
    )
  ) {
    fail("must contain valid DNS labels");
  }

  if (labels.length < 2) {
    fail("must not use a single-label or Compose service hostname");
  }
}

function expectInvalid(value) {
  assert.throws(() => validatePublicOrigin(value), undefined, value);
}

function selfTest() {
  for (const value of [
    "https://glocke.localhost",
    "https://glocke.example.com",
    "https://glocke.example.com:443",
    "https://glocke.example.com:8443",
    "HTTPS://GLOCKE.EXAMPLE.COM",
    "https://8.8.8.8",
  ]) {
    assert.doesNotThrow(() => validatePublicOrigin(value), value);
  }

  for (const value of [
    "http://glocke.example.com",
    "https://user:secret@glocke.example.com",
    "https://glocke.example.com/",
    "https://glocke.example.com/path",
    "https://glocke.example.com?query",
    "https://glocke.example.com#fragment",
    "https://foo..bar",
    "https://-label.example.com",
    "https://label-.example.com",
    "https://glocke.example.com:99999",
    "https://glocke.example.com:0",
    "https://glocke-backend",
    "https://127.0.0.1",
    "https://10.0.0.1",
    "https://[::1]",
    "https://[fd00::1]",
    " https://glocke.example.com",
  ]) {
    expectInvalid(value);
  }

  console.log("Public origin validator self-tests passed");
}

if (process.argv[2] === "--self-test") {
  selfTest();
} else if (process.argv.length === 3) {
  try {
    validatePublicOrigin(process.argv[2]);
  } catch (error) {
    console.error(`Invalid public origin ${JSON.stringify(process.argv[2])}: ${error.message}`);
    process.exitCode = 1;
  }
} else {
  console.error(`Usage: ${process.argv[1]} URL | --self-test`);
  process.exitCode = 2;
}
