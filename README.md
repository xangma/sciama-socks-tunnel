# sciama-socks-tunnel

`grafana-sciama.sh` opens a Grafana UI that is only reachable from the Sciama network by:

- starting or reusing a dedicated SSH SOCKS tunnel
- launching a browser configured to use that SOCKS proxy
- cleaning up the tunnel when the browser exits

The script is designed for personal workstation use and does not require `sudo`.

## Features

- Works on macOS and Linux
- Uses an SSH ControlMaster socket to reuse only its own tunnel
- Uses a fresh Chromium-family browser profile for each run
- Supports Firefox via a dedicated preconfigured profile
- Cleans up the tunnel and temporary browser profile automatically

## Requirements

- `zsh`
- `ssh`
- A working SSH target or alias for the login host, for example `sciama-login`
- One of:
  - macOS: a Chromium-family browser binary, defaulting to Microsoft Edge
  - Linux: a Chromium-family browser command in `PATH`, defaulting to `google-chrome`

## Quick Start

Make the script executable and run it:

```sh
chmod +x grafana-sciama.sh
./grafana-sciama.sh
```

If you use an SSH config alias:

```sh
REMOTE=sciama-login ./grafana-sciama.sh
```

If you prefer a direct SSH target:

```sh
REMOTE=username@login1.sciama.icg.port.ac.uk ./grafana-sciama.sh
```

## Configuration

All runtime settings can be overridden with environment variables:

- `REMOTE`: SSH host or alias
- `CLUSTER_IP`: private Grafana target IP, default `10.50.0.6`
- `PORT`: target port, default `3000`
- `SOCKS_PORT`: local SOCKS5 port, default `8151`
- `URL`: full URL override, default `http://${CLUSTER_IP}:${PORT}`
- `BROWSER_BIN_MAC`: full macOS browser binary path
- `BROWSER_CMD_LINUX`: Linux browser command in `PATH`
- `FIREFOX_PROFILE_NAME`: required only for Firefox
- `AUTO_CLOSE_TERMINAL`: set to `1` to auto-close the launching Terminal window on macOS

Example:

```sh
REMOTE=sciama-login SOCKS_PORT=8152 ./grafana-sciama.sh
```

## Firefox

Firefox does not accept SOCKS proxy settings directly on the command line. To use Firefox:

1. Create a dedicated Firefox profile manually.
2. Set SOCKS5 proxy to `127.0.0.1:8151` in that profile.
3. Set `network.proxy.socks_remote_dns=true` in that profile.
4. Run the script with that profile name.

Example:

```sh
BROWSER_CMD_LINUX=firefox FIREFOX_PROFILE_NAME=SciamaSocks ./grafana-sciama.sh
```

## Notes

- The script was validated on macOS with an SSH alias `sciama-login`.
- The SOCKS control socket is keyed by both remote target and local port, so a tunnel for one SSH target will not be mistaken for another.
- The repository does not include site-specific secrets or SSH configuration.
