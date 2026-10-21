# WebTelemt by V2P

**English** | [Русский](README.ru.md)

## What it is

WebTelemt is a one-command installer for your own **Telegram WEB proxy** on Ubuntu 24.04.

A WEB proxy is a new proxy type in Telegram. Telegram traffic travels inside ordinary HTTPS requests to your domain on port 443. To your ISP or a filtering system, the server looks like a regular website with a valid certificate. Anyone who opens the domain in a browser sees a neutral "coming soon" page.

## What it does

- Turns a clean Ubuntu 24.04 VPS into a working Telegram WEB proxy in a few minutes.
- Gets and renews a free Let's Encrypt certificate for your domain.
- Shows a decoy website to everyone without the key. You pick one of three pages.
- Prints ready-to-use links (`tg://` and `https://t.me/…`) and a QR code for Telegram.
- Installs the `webproxy` command for day-to-day management: status, links, decoy switch, new secret, logs, update, uninstall.

```
Telegram ──► hidden WebView ──HTTPS :443──► Caddy ──HTTP──► Telemt ──► Telegram DC
(MTProto)    (bridge page)                  (TLS, real cert)  127.0.0.1:18080
```

Nothing is faked: the domain points to the server, the certificate is real, and a real web server answers. Telegram's own MTProto encryption stays end to end. HTTPS is an extra layer on top.

## What gets installed automatically

| Component | What it is for |
|---|---|
| System updates | `apt update && apt upgrade` before anything else |
| [Caddy](https://caddyserver.com/) (official apt repo) | HTTPS on port 443, automatic Let's Encrypt certificate |
| [Telemt](https://github.com/telemt/telemt) 3.5.14 | The proxy itself, in WEB mode. Downloaded from GitHub releases, SHA-256 verified |
| systemd service `telemt` | Starts the proxy on boot, runs as the unprivileged `telemt` user |
| Decoy page | Static site served to everyone without the key |
| `webproxy` command | Management after installation |
| Tools | `curl`, `jq`, `qrencode`, `dnsutils`, `openssl` and other small dependencies |
| ufw rules | Ports 80 and 443 are opened, **only if ufw is already enabled** |

The installer does not touch SSH settings and does not enable a firewall that was off.

## Server preparation

Before you run the installer:

1. **A VPS with Ubuntu 24.04** (x86_64 or arm64) and root access. 1 vCPU / 1 GB RAM is enough.
2. **A static public IPv4 address.**
3. **A domain or subdomain pointing to the server:**
   - create an **A record** `your.domain → server IP`;
   - on Cloudflare, set it to **DNS only** (grey cloud), not proxied;
   - **no AAAA record**, unless it points to this same server. Otherwise Let's Encrypt fails;
   - check that it resolves: `dig +short A your.domain @1.1.1.1` must return the server IP.

   Use a neutral name (`app`, `cdn`, `static`…), not `tg` or `proxy`.
4. **Ports 80 and 443 free and open.** Nothing else may listen on them, and your hosting firewall must allow them. Port 80 is needed for the certificate. **Port 443 is mandatory:** Telegram connects to WEB proxies only on 443, so other ports will not work.
5. **Outbound internet access** to GitHub, Let's Encrypt, the Caddy repository and Telegram.
6. **A Telegram client that supports the WEB proxy type** (recent Telegram Desktop, Android, iOS).

## Install in one command

```bash
curl -fsSL https://raw.githubusercontent.com/V2P-Dev/WebTelemt-by-V2P/main/webproxy-install.sh -o webproxy-install.sh && sudo bash webproxy-install.sh
```

## How the installation goes

The installer asks only three things: the **domain**, the **decoy page** (1–3) and an optional **e-mail** for Let's Encrypt. Everything else runs without questions, in 10 steps:

1. System update (`apt update && apt upgrade`).
2. Dependencies and the `webproxy` command.
3. Public IP detection and DNS check: the domain must point to this server.
4. Port check: 80 and 443 must be free.
5. Caddy from the official repository.
6. Telemt download and checksum verification.
7. Telemt config with a new secret, and the decoy page.
8. Services start; ufw rules if ufw is active.
9. Health check: proxy listening, HTTPS working, certificate valid.
10. Ready links and a QR code on screen, also saved to `/root/webproxy-links.txt`.

Running the installer again is safe: it keeps the secret, so existing links keep working.

### Non-interactive install

```bash
sudo bash webproxy-install.sh --domain your.domain --decoy 1 --email you@example.com -y
```

| Option | Description |
|---|---|
| `--domain D` | Proxy domain |
| `--decoy N` | Decoy page, 1–3 |
| `--email E` | E-mail for Let's Encrypt (optional) |
| `--telemt-version V` | Telemt version (default is pinned, or `latest`) |
| `--new-secret` | Generate a new secret even if a config exists |
| `--skip-dns-check` | Skip the DNS check |
| `-y`, `--yes` | No questions; fail if a value is missing |
| `--force` | Skip the OS version check |

## Decoy pages

Three abstract "coming soon" pages. None of them says what the site is about. Switch at any time with `webproxy decoy N`.

| 1 — Animated loader | 2 — Light minimalism | 3 — Bold contrast |
|---|---|---|
| ![Decoy 1](docs/decoy-1.jpg) | ![Decoy 2](docs/decoy-2.jpg) | ![Decoy 3](docs/decoy-3.jpg) |

## Management

```
webproxy status                    services, certificate, active sessions
webproxy links [--qr]              show links (and a QR code)
webproxy decoy [N]                 list decoys / switch to N
webproxy rotate-secret             new secret (old links stop working)
webproxy restart                   restart Telemt and Caddy
webproxy logs [telemt|caddy] [-f]  logs, secrets redacted
webproxy update [VERSION]          update Telemt (default: latest)
webproxy uninstall                 remove everything
```

## Limitations

- **Voice and video calls may not work** through a Telemt WEB proxy.
- The WEB proxy type is new; some Telegram versions may not support it yet.
- A blocked domain or IP cannot be fixed by disguise. Use a new domain or server.
- **Keep the link private.** Anyone who has it can use your proxy. If it leaks, run `webproxy rotate-secret`.

## Files on the server

| Path | Purpose |
|---|---|
| `/etc/telemt/telemt.toml` | Telemt config (secret, API token) |
| `/etc/caddy/Caddyfile` | Caddy config |
| `/var/lib/telemt/public/` | Current decoy page |
| `/etc/webproxy.conf` | Installer settings |
| `/root/webproxy-links.txt` | Ready links |

## Building from source

`webproxy-install.sh` is generated from `src/install.sh` with the `decoys/` folder packed inside. After editing either, run `bash build.sh`.

## Support the project

If WebTelemt is useful to you, you can support its development:

- [Boosty](https://boosty.to/v2p/donate)
- [DaLink](https://dalink.to/v2p)
