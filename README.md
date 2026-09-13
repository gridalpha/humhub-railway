# humhub-railway

[HumHub](https://www.humhub.com) — the open-source social network — packaged for
[Railway](https://railway.com).

It is the official `humhub/humhub` image plus one boot wrapper. The wrapper is
set as the service start command and ends by exec'ing the image's own
`/docker-entrypoint.sh`, so FrankenPHP, the cron scheduler and the queue workers
still start exactly as upstream ships them.

## What the wrapper adds

| Concern | What it does |
|---|---|
| Listener | Binds FrankenPHP to Railway's `$PORT` over plain HTTP; the Railway edge terminates TLS. |
| Reverse proxy | Trusts `100.64.0.0/10`, `fd00::/8` and `152.233.0.0/17` so Yii reads the real client IP and marks the session cookie `Secure`. |
| Startup order | Polls the database with one PDO connection before touching a migration — Railway has no service start ordering. |
| First boot | Runs `installer/install-db`, `write-site-config`, `create-admin-account` and `set-base-url` before the listener opens, so the public URL never serves an unclaimed setup wizard. |
| Defaults | Seeds the SMTP settings and the registration policy **once**, leaving every later change in the admin UI alone. |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | Port FrankenPHP binds and Railway probes |
| `HUMHUB_CONFIG__COMPONENTS__DB__DSN` | — | `mysql:host=…;port=…;dbname=…` |
| `HUMHUB_CONFIG__COMPONENTS__DB__USERNAME` | — | Database user |
| `HUMHUB_CONFIG__COMPONENTS__DB__PASSWORD` | — | Database password |
| `HUMHUB_ADMIN_USERNAME` | `admin` | First admin account, first boot only |
| `HUMHUB_ADMIN_PASSWORD` | generated | First admin password. When empty, one is generated into `/data/config/initial-admin-password.txt` |
| `HUMHUB_ADMIN_EMAIL` | `admin@example.com` | First admin's email address |
| `HUMHUB_SITE_NAME` | `HumHub` | Network name |
| `HUMHUB_SYSTEM_EMAIL` | `noreply@<public domain>` | From address on system mail |
| `HUMHUB_BASE_URL` | `https://$RAILWAY_PUBLIC_DOMAIN` | Set only for a custom domain; applied on every boot when present |
| `HUMHUB_ENABLE_REGISTRATION` | `false` | `true` opens anonymous sign-up on the first boot |
| `HUMHUB_SMTP_HOST` | — | SMTP host, seeded on the first boot |
| `HUMHUB_SMTP_PORT` | `1025` | SMTP port |
| `HUMHUB_SMTP_USERNAME` / `HUMHUB_SMTP_PASSWORD` | empty | SMTP credentials |
| `HUMHUB_SMTP_USE_SMTPS` | `0` | `1` for implicit TLS |
| `HUMHUB_PHP_MEMORY_LIMIT` | `512M` | PHP `memory_limit` |

Every `HUMHUB_CONFIG__*`, `HUMHUB_WEB_CONFIG__*` and `HUMHUB_FIXED_SETTINGS__*`
variable the upstream image understands still works unchanged.

## Storage

One volume at `/data` — uploads, published assets, the dynamic config, installed
marketplace modules and themes.

## Licence

The wrapper is MIT. HumHub itself is AGPL-3.0-or-later with the HumHub licence
terms; see [humhub/humhub](https://github.com/humhub/humhub).
