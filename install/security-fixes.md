# Security fixes

`install/security-fixes.sh` responds to two October 2026 incidents: the eMudhra
CA key compromise and the malicious LiteLLM 1.107.0 release. `install-tools.sh`
runs it before downloading anything, so `setup.sh` and `config-update` apply it
on every machine. It can also be run by itself:

```bash
bash install/security-fixes.sh
```

It exits non-zero, and setup stops, when a machine still trusts the forged
certificates or shows traces of the LiteLLM payload. Everything else it fixes
when it can and reports when it can't, usually because the fix needs sudo.
Fixed versions and indicators below were current on 2026-10-22.

## eMudhra intermediates

On 2025-04-30, eMudhra created eight intermediate CAs whose private keys anyone
can compute from the public certificates: six for TLS (EM DV, OV and EV TLS CA
G3B and G3C) and two for code signing (EM OV CS CA G3B and G3C). Sectigo
cross-signed a second copy of each, so 16 certificates share the 8 keys. The
roots above them weren't compromised, but a store that trusts any of them
accepts certificates forged for any domain. The keys were reported on
2026-10-17 and revoked on 2026-10-18, but non-browser clients rarely check
revocation.

- Tracker, test hosts, `chains.zip` and `proof.zip`: <https://emudhra.we-have-a-problem.com/>
- Cisco Talos, with the certificates' SHA-256 fingerprints: <https://blog.talosintelligence.com/compromised-intermediate-certificates/>
- Fixed versions by client: <https://safedep.io/emudhra-ca-key-compromise/>
- Red Hat RHSB-2026-012: <https://access.redhat.com/security/vulnerabilities/RHSB-2026-012>
- eMudhra's statement: <https://emudhra.com/en/post/certificate-security-incident>

### Trust store

The script builds `${XDG_DATA_HOME:-~/.local/share}/configs/ca-bundle.pem`. It
is a link to the system bundle when that is clean, and otherwise a copy without
the four roots above the intermediates (emSign Root TLS CA - G3, emSign ECC Root
CA - G3, emSign Root CS CA - G3, AAA Certificate Services) or any certificate
with one of the eight keys. Patched distribution stores, such as Ubuntu's
`ca-certificates` 20260816ubuntu0.24.04.1, drop the same four roots.

The bundle must reject every chain in `install/emudhra-chains` with `openssl
verify`, failing for want of an issuer, as of 2026-10-23 so the check still
works after the forged leaves expire in May 2027. Those are the 14 chains the
tracker's hosts serve, from its `chains.zip` (SHA-256
`7b949956955fc501a30f4d98d2f513d34c0bbbe92e29a968194c96e097ce2345`). Each
intermediate's fingerprint matches Talos's list, and each key signed its
`proof.zip` message. When the network allows, four of the live hosts are
checked too.

The script uses `/usr/bin/openssl` and `/usr/bin/curl` ahead of conda's or
Homebrew's copies, and fails if it can't read every certificate in the system
bundle, so a broken `openssl` can't produce an empty bundle that passes.

### Pointing tools at it

A CA file alone isn't enough. On Ubuntu 24.04, OpenSSL's `verify`, Python's
default SSL context, git (built with GnuTLS) and `/usr/bin/curl` (built with
`CApath=/etc/ssl/certs`) still read the system CA directory, which on an
unpatched host holds the compromised root. Given a clean `SSL_CERT_FILE` and a
directory holding emSign ECC Root CA - G3, both `openssl verify` and Python's
`urllib` accepted a forged chain. With only `GIT_SSL_CAINFO` set to an unrelated
CA, git still reached GitHub. And once a curlrc sets `capath`, curl ignores
`CURL_CA_BUNDLE`.

- `.bashrc.d/10-ca-bundle.sh` sets `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
  `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO` to the bundle, and `SSL_CERT_DIR` and
  `GIT_SSL_CAPATH` to an empty directory, in shells where they aren't already
  set.
- `install/ca-env.sh` forces the same for the installer, the skills clone in
  `setup.sh` and the script's own Homebrew step. It also points `CURL_HOME` at a
  curlrc that sets both `cacert` and `capath`.
- `hyprkarl/apps/t3code-remote-update.sh` downloads with each host's bundle.
- npm gets `cafile` in `~/.npmrc`, since Node itself keeps its own roots.

These reach programs started from a shell or by setup. systemd services, cron
jobs and desktop apps keep their own trust until the system store and the
runtimes are updated.

### System and Homebrew stores

The system's `ca-certificates` is upgraded with `sudo -n`, so never with a
password prompt, and never on the lab servers or macOS. macOS doesn't update
`/etc/ssl/cert.pem` for this; Apple's own blocking of the intermediates was
still incomplete on 2026-10-22, so Macs use the filtered copy. Homebrew's
`ca-certificates` (fixed in 2026-09-25_1) is upgraded on its own. On Linux,
brew's sandboxed post-install left `etc/ca-certificates/cert.pem` empty on
2026-10-22, which breaks all of brew's TLS. Running the formula's
`libexec/post-install` directly rebuilt it, so the script does that and checks
the result against the chains.

### Runtimes with their own roots

These embed or ship roots that the bundle doesn't replace, so the script lists
installs older than their fixes, as given by the tracker: Node 22.23.4, 24.22.1
and 26.12.1 (21 and below, 23 and 25 get no fix), uv 0.13.4, Bun 1.4.4, Deno
2.9.8, pixi 0.82.1, conda 26.9.4, and Claude Code 2.1.303. `install-tools.sh`
updates uv, pixi, Node's LTS and Claude Code right after. Java reads its own
`cacerts`, which the system update doesn't always rebuild; with passwordless
sudo the script runs `update-ca-certificates -f`.

### Tailscale

Tailscale 1.104.2 is built with Go 1.27.3, which distrusts the intermediates
whatever the system store says. Traffic between nodes is WireGuard and doesn't
use Web PKI, but the client fetches the control server's key over HTTPS at each
start without pinning it, so an older client on a store that trusts the forged
certificates can be pointed at a fake control server. The script updates older
installs where it can and checks that the running daemon is updated too.

- TS-2026-013: <https://tailscale.com/security-bulletins>
- Control key fetch: [`control/controlclient/direct.go`](https://github.com/tailscale/tailscale/blob/main/control/controlclient/direct.go) (`loadServerPubKeys`)
- Tailnet Lock, which stops a control server adding nodes: <https://tailscale.com/kb/1226/tailnet-lock>

## LiteLLM 1.107.0

A compromised release pipeline published `litellm` 1.107.0 to PyPI (2026-10-21,
11:39 to about 13:23 UTC) and pointed LiteLLM's Docker Hub and GHCR tags at
malicious images. `cook.pth` and `sitecustomize.py` run a credential stealer at
every Python start, pip included, and a detached daemon holds
`/tmp/remote_code_loader.lock`. The last clean release is 1.106.2.

The script never starts Python. It looks in environments, caches and the
storage drive for `litellm-1.107.0` packages, `cook.pth`, `cook.py`, their
`.pyc` files, and any `sitecustomize.py` that names the payload. It also checks
for the marker files, `PRIVCOLLECT_ACTIVE`, this user's processes, and the
images' digests. pip's HTTP cache stores downloads under hashed names, so a
cached wheel can't be found by name.

- Advisory: <https://docs.litellm.ai/blog/security-incident-oct-21-2026>
- Indicators: <https://github.com/BerriAI/litellm/issues/47826>

## Other hygiene

- pip `trusted-host` turns off certificate checks for an index. The script
  removes it from this user's pip configs, with a backup under
  `${XDG_STATE_HOME:-~/.local/state}/configs/config-backups/security-fixes`.
  Packages such as `nvidia-pyindex` add it.
- Links on the PATH to missing files under `/tmp` can be recreated by any user;
  the script removes them.
- Credential files and the directories holding keys, tokens and agent
  transcripts lose group and other access. With a umask of `002`, new files in
  them are world-readable, so the directories themselves go to 700.

## Undoing it

Delete `configs/ca-bundle.pem` and the `cafile` line in `~/.npmrc`, then open
new shells. Running shells keep the variables until you `unset SSL_CERT_FILE
REQUESTS_CA_BUNDLE CURL_CA_BUNDLE SSL_CERT_DIR GIT_SSL_CAINFO GIT_SSL_CAPATH`.
Removed pip settings are in the backup directory above.
