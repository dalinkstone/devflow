import assert from "node:assert/strict";
import test from "node:test";

const workerUrl = new URL("../dist/server/index.js", import.meta.url);
workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
const { default: worker } = await import(workerUrl.href);

const context = {
  waitUntil() {},
  passThroughOnException() {},
};

const assets = {
  fetch: async () => new Response("Not found", { status: 404 }),
};

test("renders the devflow install page", async () => {
  const response = await worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: assets },
    context,
  );
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>devflow<\/title>/i);
  assert.match(html, /curl -fsSL https:\/\/devflow\.sh\/install \| sh/);
  assert.match(html, /Agents in the cloud/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton/i);
});

test("serves the install endpoint as shell", async () => {
  const response = await worker.fetch(
    new Request("https://devflow.sh/install"),
    { ASSETS: assets, DEVFLOW_HOST_SUFFIX: "devflow.sh" },
    context,
  );
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/plain/);
  const script = await response.text();
  assert.match(script, /^#!\/bin\/sh/);
  assert.match(script, /dalinkstone\/devflow\/main\/install\.sh/);
});

test("serves the installer on the deployment hostname", async () => {
  const response = await worker.fetch(
    new Request("https://devflow-shell.example.test/install"),
    { ASSETS: assets, DEVFLOW_HOST_SUFFIX: "devflow.sh" },
    context,
  );
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/plain/);
});

test("reserves www for the landing site", async () => {
  const response = await worker.fetch(
    new Request("https://www.devflow.sh/"),
    { ASSETS: assets, DEVFLOW_HOST_SUFFIX: "devflow.sh" },
    context,
  );
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Agents in the cloud/);
});

test("requires Cloudflare Access on sandbox hosts", async () => {
  const response = await worker.fetch(
    new Request("https://my-box.devflow.sh/"),
    {
      ASSETS: assets,
      DAYTONA_API_KEY: "test-key",
      DEVFLOW_HOST_SUFFIX: "devflow.sh",
    },
    context,
  );
  assert.equal(response.status, 401);
  assert.match(await response.text(), /Authentication required/);
});

test("starts a stopped sandbox and refreshes", async () => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ method: init.method || "GET", url });
    if (url.endsWith("/sandbox/dv-my-box")) {
      return Response.json({ name: "dv-my-box", state: "stopped" });
    }
    if (url.endsWith("/sandbox/dv-my-box/start")) {
      return new Response(null, { status: 202 });
    }
    return new Response("Not found", { status: 404 });
  };
  try {
    const response = await worker.fetch(
      new Request("https://my-box.devflow.sh/"),
      {
        ASSETS: assets,
        DAYTONA_API_KEY: "test-key",
        DEVFLOW_HOST_SUFFIX: "devflow.sh",
        DEVFLOW_REQUIRE_ACCESS: "false",
      },
      context,
    );
    assert.equal(response.status, 202);
    assert.match(await response.text(), /Starting <code>dv-my-box<\/code>/);
    assert.deepEqual(calls.map((call) => call.method), ["GET", "POST"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("proxies a running sandbox terminal", async () => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ init, url });
    if (url.endsWith("/sandbox/dv-my-box")) {
      return Response.json({ name: "dv-my-box", state: "started" });
    }
    if (url.endsWith("/ports/22222/preview-url")) {
      return Response.json({
        url: "https://22222-sandbox.proxy.daytona.work",
        token: "preview-token",
      });
    }
    if (url.startsWith("https://22222-sandbox.proxy.daytona.work")) {
      assert.equal(new Headers(init.headers).get("x-daytona-preview-token"), "preview-token");
      assert.equal(new Headers(init.headers).get("cookie"), null);
      return new Response("terminal");
    }
    return new Response("Not found", { status: 404 });
  };
  try {
    const response = await worker.fetch(
      new Request("https://my-box.devflow.sh/socket?x=1", {
        headers: { cookie: "CF_Authorization=secret" },
      }),
      {
        ASSETS: assets,
        DAYTONA_API_KEY: "test-key",
        DEVFLOW_HOST_SUFFIX: "devflow.sh",
        DEVFLOW_REQUIRE_ACCESS: "false",
      },
      context,
    );
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "terminal");
    assert.equal(
      calls.at(-1).url,
      "https://22222-sandbox.proxy.daytona.work/socket?x=1",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});
