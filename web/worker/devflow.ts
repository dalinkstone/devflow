const INSTALL_SCRIPT = `#!/bin/sh
set -eu
installer="$(mktemp)"
trap 'rm -f "$installer"' 0 1 2 15
curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh -o "$installer"
bash "$installer"
`;

export interface DevflowEnv {
  DAYTONA_API_KEY?: string;
  DAYTONA_API_URL?: string;
  DEVFLOW_HOST_SUFFIX?: string;
  DEVFLOW_REQUIRE_ACCESS?: string;
}

interface SandboxInfo {
  id?: string;
  name?: string;
  state?: string;
  status?: string;
}

interface PreviewInfo {
  token?: string;
  url?: string;
}

export interface PreviewTarget {
  sandbox: string;
  port: number;
}

export function installerResponse(): Response {
  return new Response(INSTALL_SCRIPT, {
    headers: {
      "cache-control": "public, max-age=300",
      "content-type": "text/plain; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

export function previewFromHostname(
  hostname: string,
  suffix = "devflow.sh",
): PreviewTarget | null {
  const ending = `.${suffix}`;
  if (!hostname.endsWith(ending)) return null;
  let label = hostname.slice(0, -ending.length);
  let port = 22222;
  const portMatch = label.match(/^(.*)--([0-9]{1,5})$/);
  if (portMatch) {
    label = portMatch[1];
    port = Number(portMatch[2]);
  }
  if (
    !label ||
    label === "www" ||
    label.includes(".") ||
    port < 1 ||
    port > 65535 ||
    !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)
  ) {
    return null;
  }
  return {
    sandbox: label.startsWith("dv-") ? label : `dv-${label}`,
    port,
  };
}

export function sandboxFromHostname(
  hostname: string,
  suffix = "devflow.sh",
): string | null {
  return previewFromHostname(hostname, suffix)?.sandbox ?? null;
}

function html(message: string, status = 200, refresh = false): Response {
  const refreshTag = refresh ? '<meta http-equiv="refresh" content="4">' : "";
  return new Response(
    `<!doctype html><html><head><meta charset="utf-8">${refreshTag}<meta name="viewport" content="width=device-width"><title>devflow</title><style>body{background:#0b0c0e;color:#f4f4f1;font:16px ui-monospace,SFMono-Regular,Menlo,monospace;display:grid;min-height:100vh;place-items:center;margin:0}main{max-width:42rem;padding:2rem}p{color:#a7aaa4}code{color:#86efac}</style></head><body><main><h1>devflow</h1><p>${message}</p></main></body></html>`,
    {
      status,
      headers: {
        "cache-control": "no-store",
        "content-type": "text/html; charset=utf-8",
        "x-content-type-options": "nosniff",
      },
    },
  );
}

function apiHeaders(env: DevflowEnv): Headers {
  const headers = new Headers({ authorization: `Bearer ${env.DAYTONA_API_KEY}` });
  return headers;
}

async function getSandbox(
  apiUrl: string,
  requestedName: string,
  env: DevflowEnv,
): Promise<{ info: SandboxInfo; name: string } | null> {
  const candidates = requestedName.startsWith("dv-")
    ? [requestedName, requestedName.slice(3)]
    : [requestedName, `dv-${requestedName}`];
  for (const name of candidates) {
    const response = await fetch(
      `${apiUrl}/sandbox/${encodeURIComponent(name)}`,
      { headers: apiHeaders(env) },
    );
    if (response.ok) {
      return { info: (await response.json()) as SandboxInfo, name };
    }
    if (response.status !== 404) {
      throw new Error(`Daytona lookup failed (${response.status})`);
    }
  }
  return null;
}

export async function proxySandbox(
  request: Request,
  env: DevflowEnv,
  requestedName: string,
  port = 22222,
): Promise<Response> {
  if (!env.DAYTONA_API_KEY) {
    return html("Preview proxy is not configured.", 503);
  }
  if (
    env.DEVFLOW_REQUIRE_ACCESS !== "false" &&
    !request.headers.get("cf-access-jwt-assertion")
  ) {
    return html("Authentication required.", 401);
  }

  const apiUrl = (env.DAYTONA_API_URL || "https://app.daytona.io/api").replace(/\/$/, "");
  let resolved: { info: SandboxInfo; name: string } | null;
  try {
    resolved = await getSandbox(apiUrl, requestedName, env);
  } catch (error) {
    return html(error instanceof Error ? error.message : "Daytona lookup failed.", 502);
  }
  if (!resolved) return html(`No sandbox named <code>${requestedName}</code>.`, 404);

  const state = (resolved.info.state || resolved.info.status || "").toLowerCase();
  if (state !== "started") {
    if (!["starting", "restoring", "creating"].includes(state)) {
      const start = await fetch(
        `${apiUrl}/sandbox/${encodeURIComponent(resolved.name)}/start`,
        { method: "POST", headers: apiHeaders(env) },
      );
      if (!start.ok) return html(`Could not start <code>${resolved.name}</code>.`, 502);
    }
    return html(`Starting <code>${resolved.name}</code>…`, 202, true);
  }

  const previewResponse = await fetch(
    `${apiUrl}/sandbox/${encodeURIComponent(resolved.name)}/ports/${port}/preview-url`,
    { headers: apiHeaders(env) },
  );
  if (!previewResponse.ok) return html(`Could not open port <code>${port}</code>.`, 502);
  const preview = (await previewResponse.json()) as PreviewInfo;
  if (!preview.url || !preview.token) return html("Daytona returned an invalid preview.", 502);

  const incoming = new URL(request.url);
  const upstream = new URL(preview.url);
  upstream.pathname = incoming.pathname;
  upstream.search = incoming.search;

  const headers = new Headers(request.headers);
  for (const name of [
    "authorization",
    "cf-access-authenticated-user-email",
    "cf-access-jwt-assertion",
    "cf-connecting-ip",
    "cf-ipcountry",
    "cf-ray",
    "host",
    "x-forwarded-for",
  ]) {
    headers.delete(name);
  }
  const cookie = headers.get("cookie");
  if (cookie) {
    const kept = cookie
      .split(";")
      .map((part) => part.trim())
      .filter((part) => !/^CF_[^=]*=/i.test(part));
    if (kept.length > 0) headers.set("cookie", kept.join("; "));
    else headers.delete("cookie");
  }
  headers.set("x-daytona-preview-token", preview.token);
  headers.set("x-daytona-skip-preview-warning", "true");
  headers.set("x-daytona-trust-forwarded-host", "true");
  headers.set("x-forwarded-host", incoming.host);

  const response = await fetch(upstream, {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    redirect: "manual",
  });
  const location = response.headers.get("location");
  if (location && response.status >= 300 && response.status < 400) {
    const redirect = new URL(location, upstream);
    if (redirect.origin === upstream.origin) {
      redirect.protocol = incoming.protocol;
      redirect.host = incoming.host;
      const responseHeaders = new Headers(response.headers);
      responseHeaders.set("location", redirect.toString());
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: responseHeaders,
      });
    }
  }
  return response;
}
