# Port registry for vellox-srv10

One scheme for every solution on this server, dev and prod alike:

```
3 NN S   dev  (run by hand from /srv/dev: npm run dev, uvicorn, dotnet run, compose dev overrides)
4 NN S   prod (docker compose from /srv/prod, or a systemd unit)
  NN     solution number, 01–99, from the table below (00 is reserved for host infrastructure)
  S      slot: 0 web/UI, 1 API, 2 database, 3 cache/queue, 4–9 solution-specific
```

Same number, different thousands digit: the ledger studio is 3020 in dev and 4020 in prod. Ten
ports per solution; a solution that outgrows its block takes the next free NN as well. Nothing
binds 5000–9999 any more except what is listed under "host infrastructure".

Rules going forward:

- A new solution takes the next free NN in the table **before** its first `npm run dev`.
- Dev servers bind their 3NNS port explicitly in `package.json` / `run.sh`, never a framework
  default (3000, 5173, 8000 are all forbidden: they collide the moment two projects run).
- Prod compose files publish `${WEB_PORT:-4NN0}` and friends so the number lives here and in
  the compose default, not in a `.env` someone has to remember.
- Databases and caches in prod bind `127.0.0.1:4NN2` unless another host really needs them.
- The reverse proxy on 10.4.20.25 forwards `<name>.vellox.se` to `10.4.20.38:4NN0`. Change the
  proxy in the same commit as the compose default.

## Allocation

The allocation itself lives in **`/srv/ports.tsv`** on the server, one row per port, and that
file is the single source of truth. Read and maintain it with `ports.sh` in this repo:

```bash
bash /srv/dev/vellox-bootstrap/ports.sh            # the registry
bash /srv/dev/vellox-bootstrap/ports.sh check      # what listens but is not registered, legacy ports still in use
bash /srv/dev/vellox-bootstrap/ports.sh next       # next free solution number
bash /srv/dev/vellox-bootstrap/ports.sh free 3090  # is a port unregistered and not listening
bash /srv/dev/vellox-bootstrap/ports.sh add 3090 vellox-new dev web "next dev"
```

Solution numbers handed out so far: 01 scraper, 02 ledger-studio, 03 supplier-studio (formerly support), 04 report-converter,
05 restock, 06 brain, 07 analytics, 08 engine (formerly master; dev 3080/3081 = enginedev.vellox.se, prod 4080 = engine.vellox.se), 09 nordic-knots (custom/vellox-nordic-knots). Block 00 is
host infrastructure (sshd, pi-hole on 53/80/443, ttyd on 7681). Ports still in use at their old
numbers are registered with env `legacy` and the target port in the note, so `check` reports them
as pending rather than unknown.

## Inventory on 2026-09-22 and what moves

Where the current port already matches the scheme nothing changes. Everything else moves once,
in the project's own repo, and the proxy on 10.4.20.25 follows.

| Solution | Today | Where it is set | Target | Change |
|----------|-------|-----------------|--------|--------|
| vellox-scraper | dev 3010 | `package.json` (`${PORT:-3010}`) | 3010 | none; prod 4010 when it gets a compose file |
| vellox-ledger-studio | dev 3020, prod default 3020 | `package.json`, `deploy/docker-compose.yml` | 3020 / 4020 | prod compose default `WEB_PORT` 3020 → 4020 (done in this commit) |
| vellox-support | dev 3030 | `package.json`, `.env.example` `APP_URL` | 3030 | none; prod 4030 when it gets a compose file |
| vellox-report-converter | prod web 3001 (`WEB_PORT` in `.env`), dev web 3000, dev api 8000, dev redis 6379 | `.env`, `deploy/docker-compose.yml` default 3000, `deploy/docker-compose.dev.yml`, `web/package.json` (`next dev` with no port), `.env.example` `API_PORT`, `CORS_ORIGINS`, `API_INTERNAL_URL`, `REDIS_URL` | prod 4040; dev 3040 / 3041 / 3043 | set `WEB_PORT=4040`, compose default 4040, `next dev -p 3040`, uvicorn `--port 3041`, redis `3043:6379`, update the three URLs in `.env.example`; proxy upstream 3001 → 4040 |
| vellox-restock | portal 8080 (systemd unit and the process running now), vite dev 5173 | `deploy/*.service`, `frontend/vite.config.ts` (proxy target), README | prod 4050; dev 3050 / 3051 | done by 2026-11-12: portal and vite gone; dev `start-dev.sh` runs web (`next dev -p 3050`) and engine (uvicorn 127.0.0.1:3051) under the user unit `vellox-restock-dev`; prod `deploy/docker-compose.prod.yml` publishes `${WEB_PORT}` 4050 → container 3050, engine unpublished (4051 reserved); prod not deployed yet (restock.vellox.one answers 502) |
| vellox-brain | not running here; compose defaults web 3000, api 8000, postgres 5432, and the same in `.env` | `docker-compose.yml`, `docker-compose.prod.yml`, `.env`, `.env.example` (`CORS_ORIGINS`, `ENTRA_REDIRECT_URI`, `AUTH_FRONTEND_REDIRECT_URL`) | dev 3060 / 3061 / 3062, prod 4060 / 4061 / 4062 | change the three `*_PORT` defaults and values, and the localhost URLs; Entra redirect URI must be re-registered if the port is part of it |
| vellox-analytics | cube 4000, cube tesseract 4001 (container started by hand, not in compose), auth-bridge 8081, postgres 5433, dashboard/admin/export-ui vite 5174 / 5176 / 5173, export-agent 8765 | `docker-compose.yml`, `apps/*/vite.config.ts`, `apps/*/.env.example`, `apps/export-agent/Dockerfile` | see table (block 07) | this is the largest move: cube 4000 → 4077, tesseract 4001 → 4078 (add it to compose while at it), auth-bridge 8081 → 4071, postgres 5433 → 4072, export-agent 8765 → 4074, vite dev servers 5174 → 3070, 5176 → 3075, 5173 → 3076, and the proxy targets in the vite configs and `.env.example` files; proxy upstream for analytics.vellox.se follows |
| vellox-engine (formerly vellox-master) | api 5150, vite 5175 (`run.sh`), CORS allows 5173/5174 | `run.sh`, `Properties/launchSettings.json`, `src/frontend/vite.config.ts`, `Program.cs` CORS list | dev 3080 / 3081, prod 4080 | done 2026-10-07: api 3081, vite 3080 (`strictPort`), CORS list, user-systemd units; prod = one docker container on 4080 (`deploy/deploy.sh`) |
| pi-hole | 53, 80, 443 | `docker-compose.yml` | unchanged | none |

Order that avoids downtime: change the compose default and the proxy upstream together, `up -d`,
then check `ss -tlnp` shows only 3NNS/4NNS ports plus the infrastructure list. `sudo ss -tlnp`
shows which process owns each port; `docker ps --format '{{.Names}}\t{{.Ports}}'` shows the
published container ports.
