# NET.md

Shared .NET and C# guidance for this webroot.

This file applies to:
- `net/` for legacy ASP.NET / Web Forms-era code
- `core/` for legacy .NET Core-era code
- `host/net/` for the newer cross-platform .NET host
- `net10/` and `core10/` for `.NET 10` migration work that should not modify the legacy repos directly

## Current Target

As of April 14, 2026, Microsoft lists `.NET 10` as the active LTS release:
- https://dotnet.microsoft.com/en-us/platform/support/policy
- https://learn.microsoft.com/en-us/dotnet/core/releases-and-support

The `host/net/` host in this repo targets `net10.0`.

## Shared Config Standard

Use `docker/.env` for shared local .NET settings instead of creating new XML-only local config.

Notes:
- Legacy `web.config` and older XML settings in `net/` or `core/` may still exist for compatibility.
- Do not assume those files are the source of truth for local shared development settings.
- Do not break existing AWS EC2 / RDS production connection flows in legacy repos unless explicitly asked.
- `CoreDatabase` placeholders live in `docker/.env` and `docker/.env.example`.
- `CORE_*` is for the Microsoft SQL Server Core database and normally uses port `1433`.

Relevant shared variables:
- `DOTNET_HOST`
- `DOTNET_PORT`
- `DOTNET_ENVIRONMENT`
- `DOTNET_SITE_ROOT`
- `DOTNET_STATS_ROOT`
- `CORE_HOST`
- `CORE_PORT`
- `CORE_NAME`
- `CORE_USER`
- `CORE_PASSWORD`
- `CORE_SSL_MODE`
- `CORE_PROVIDER`
- `DOTNET_LEGACY_CORE_BASE_URL`

## Code CLI Commands

Preferred agent command:

```bash
start net
```

Direct commands:

```bash
bash host/net/net.sh install-sdk
bash host/net/net.sh install
bash host/net/net.sh start
bash host/net/net.sh start --install-sdk
bash host/net/net.sh status
bash host/net/net.sh stop
```

What `host/net/net.sh` does:
- reads `host/net/net.yaml`
- loads `docker/.env` when present
- starts the newer `host/net/` host on `DOTNET_PORT` or the YAML default
- serves the current webroot root as the `.NET 10` site root
- excludes the legacy `/net/` and `/core/` paths, which belong to the legacy backend on port `8004`
- passes `DOTNET_STATS_ROOT` to the `.NET 10` host so `core10/admin/stats/` can browse report folders

If `dotnet` is missing:
- `bash host/net/net.sh install-sdk` tries a package-manager install first
- supported first-pass package managers are `brew`, `winget`, `apt-get`, `dnf`, `yum`, and `pacman`
- if no supported package manager is available, it falls back to a portable user-space install in `~/.dotnet`
- `bash host/net/net.sh start --install-sdk` combines install and start

## Local Server Behavior

The newer `host/net/` host is the cross-platform local path for Code CLIs.

It is intended to:
- serve the current webroot root as static/site content
- expose a health endpoint at `/healthz`
- provide a single place to grow newer ASP.NET Core endpoints without changing legacy `net/` and `core/` layouts
- own the webroot outside `/net/` and `/core/`

Missing page/file behavior:
- `fallback_to_root_on_missing: false` in `host/net/net.yaml` means unknown paths return `404`
- set `fallback_to_root_on_missing: true` in `host/net/net.yaml` to restore the older behavior that falls back to the webroot `index.html`
- restart with `bash host/net/net.sh stop` and `bash host/net/net.sh start` after changing the setting

Default local URL:

```bash
http://localhost:8010
```

Health check:

```bash
curl http://localhost:8010/healthz
```

## Legacy Support

`net/` and `core/` are kept in place and are represented by `.backend` manifests for nginx code generation.

Current intent:
- `net/` remains legacy ASP.NET-compatible code and should be routed to the legacy backend on port `8004`
- `core/` remains legacy ASP.NET-compatible code and should be routed to the legacy backend on port `8004`
- `host/net/` is the newer `.NET 10` host for cross-platform local development on port `8010`
- `net10/PLAN.md` and `core10/PLAN.md` track incremental migration into `.NET 10` repos without changing the legacy repos directly

Do not rewrite legacy config into a Microsoft-only pattern when a shared shell, YAML, or `.env` pattern works across Rust, Python, Node.js, and .NET.

## Nginx Backend Manifests

Each backend-capable repo can expose a `.backend` file with:

```text
path:
backend:
port:
```

Generate nginx config from manifests with:

```bash
python3 docker/nginx/generate-nginx-conf.py
nginx -s reload
```

Combined form:

```bash
python3 docker/nginx/generate-nginx-conf.py && nginx -s reload
```
