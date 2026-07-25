# devflow.sh

Landing page, installer endpoint, and protected Daytona preview proxy.

## Prerequisites

- Node.js 22+

## Local

```bash
npm install
npm run dev
```

## Check

```bash
npm run lint
npm test
```

## Preview proxy

Cloudflare Access protects `*.devflow.sh`. The Worker maps `box.devflow.sh` to
the `dv-box` sandbox and proxies its web terminal.

`DAYTONA_API_KEY` is a Worker secret. Deploy the wildcard Worker with:

```bash
npm run build
npx wrangler deploy --config wrangler.preview.jsonc
```
