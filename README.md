# antigravity-wsl-harness

Workarounds for two problems when using the Antigravity IDE (Google's VS Code fork) with a WSL distro on Windows.

This is a personal setup, published as is. User names are placeholders that you fill in, and the distro name is hardcoded; see [Adapting it](#adapting-it). Nothing here is supported by Google or Microsoft.

## The two problems

**1. Closing one WSL window disconnects all the others.**
Antigravity's built-in Remote-WSL extension (a fork of [open-remote-wsl](https://github.com/jeanp413/open-remote-wsl)) starts the server from the first window that opens a WSL folder. That window's `wsl.exe` process is the only thing keeping the server alive; later windows just find it "already running". Close or reload the first window and the server goes down with it, so every other WSL window shows "cannot reconnect" until it is reloaded. Closest upstream report: [open-remote-wsl#2](https://github.com/jeanp413/open-remote-wsl/issues/2).

**2. Source Control is empty after a long sleep or hibernate.**
The client allows the remote extension host connection 3 hours to reconnect, measured in wall-clock time. After a longer sleep, the first retry on wake happens before WSL's localhost forwarding is back. It fails and is treated as "grace time expired". The window keeps working, but its remote extension host (Git, language servers) is gone until Reload Window. This is fixed upstream in [microsoft/vscode#338062](https://github.com/microsoft/vscode/pull/338062) (VS Code 1.141). Antigravity 2.8.0 is built on VS Code 1.107 and does not have the fix.

## What this does

| Piece | Purpose |
|---|---|
| `antigravity-server.service`, `antigravity-server-launch.sh` | Runs the Antigravity server as a systemd service inside the distro, using the same pid, token and log file conventions as the IDE's own install script. The IDE finds it "already running", so no window owns the server. |
| `antigravity-server-update.timer`, `antigravity-server-update-check.sh` | Every minute: if the Windows IDE now wants a different server version (after an IDE update), restart the service on that version, but only once it is fully installed and no window would be disrupted. |
| `antigravity-client-patch.service`, `antigravity-client-patch.sh` | Changes one constant in the Windows-side client bundle (reconnection grace 3 h to 7 d) and updates the matching checksum in `product.json`. Started on every timer tick; does nothing unless an unpatched copy appears, which is after each IDE update. |
| `windows/.wslconfig` | Keeps the distro and the WSL VM alive when no Windows client is attached (`instanceIdleTimeout=-1`, `vmIdleTimeout=-1`), plus a memory cap. |
| `etc/binfmt.d/WSLInterop.conf`, `etc/profile.d/zzz-unexport-ps1.sh` | Fedora Remix specifics: keep Windows interop registered under systemd, and stop an exported `PS1` from leaking into IDE terminals. Probably not needed on other distros. |

Each script and unit starts with a comment that explains what it does and why.

## Status

- Problem 1: in daily use since July 2026, across Antigravity 2.1 to 2.7.
- Problem 2: the client patch was added on 2026-11-24 and has not yet been confirmed across a long hibernate. It stops being needed once Antigravity includes the upstream fix; the script logs a notice when it sees that.
- Tested with WSL 2.7.13, Fedora Remix (Fedora 42, systemd 257) and a per-user Antigravity IDE install.

## Layout

The repository mirrors the file system. Once the placeholders are filled in, `etc/` and `usr/` go into the distro as they are. `windows/.wslconfig` goes to `%USERPROFILE%\.wslconfig`.

## Requirements

- WSL 2.5.4 or newer (for `instanceIdleTimeout=-1`), with systemd enabled in the distro (`[boot] systemd=true` in `/etc/wsl.conf`).
- In the distro: bash, `flock`, `pgrep`, `xxd`, and a coreutils whose `mv` supports `--no-copy`. `jq` is optional.
- Antigravity IDE installed per user in its default location on Windows.

## Adapting it

| What | In the files | Where |
|---|---|---|
| Linux user that runs the IDE server | placeholder `YOUR_LINUX_USER` | `User=` and `HOME=` in `antigravity-server.service` and `antigravity-client-patch.service`; `AG_DATA` and `pgrep -u` in `antigravity-server-common.sh`; the usage comment in the test script |
| That user's uid | `1000` | `user@1000.service` in `20-user-manager.conf` |
| Windows profile folder (the name under `C:\Users`) | placeholder `YOUR_WINDOWS_USER` | `AG_PRODUCT_JSON` in `antigravity-server-common.sh`; the paths at the top of the test script |
| Distro name | `fedoraremix` | `DISTRO_NAME` in `antigravity-server-launch.sh` |

The install steps below fill in the two placeholders. Change the uid and the distro name by hand if yours differ.

## Install

Close all IDE windows that are connected to WSL. Then, in the distro, as root, from a checkout of this repository:

```sh
LINUX_USER=alice       # the Linux user that runs the IDE server
WINDOWS_USER=Alice     # your folder name under C:\Users

grep -rlE 'YOUR_(LINUX|WINDOWS)_USER' etc usr \
  | xargs sed -i "s/YOUR_LINUX_USER/$LINUX_USER/g; s/YOUR_WINDOWS_USER/$WINDOWS_USER/g"

cp -r etc usr /
systemctl daemon-reload
systemctl enable --now antigravity-server.service antigravity-server-update.timer
loginctl enable-linger "$LINUX_USER"
```

Lingering starts the user's systemd manager at boot, which the launcher waits for before it captures the session environment.

On Windows, merge `windows/.wslconfig` into `%USERPROFILE%\.wslconfig` and run `wsl --shutdown` once so it takes effect.

## Checking that it works

```sh
systemctl status antigravity-server        # active, one server process
journalctl -u antigravity-server -b        # "Environment adopted from a live WSL session"
journalctl -u antigravity-client-patch     # one line per patched IDE version
sudo -u "$LINUX_USER" /usr/local/bin/antigravity-client-patch.sh --dry-run
```

For problem 1: open two WSL windows and close the first one. The second stays connected.

For problem 2: after a sleep, the IDE's `renderer.log` should show `starting reconnection with grace time: 604800000ms` on the `ExtensionHost` line (it shows `10800000ms` without the patch).

The client patch has a test suite that works on a throwaway copy of the IDE files and never writes to the real install:

```sh
systemd-run --wait --pipe --collect -p User="$LINUX_USER" /bin/bash \
  /usr/local/share/antigravity-harness/antigravity-client-patch-test.sh
```

The last line should end with `FAILS=0`.

## Things to know

- Terminals and extension hosts are children of the service. `systemctl restart antigravity-server` kills them all, like closing every window. The update checker therefore waits until no window is connected.
- The server's environment is captured from a real `wsl.exe` session when the service starts. New Windows `PATH` entries reach IDE terminals only after the next service start.
- `wsl --shutdown`, a WSL update or a Windows sign-out still stops everything. Each window needs one reload afterwards.
- The client patch edits two files of the installed IDE (`workbench.desktop.main.js` and `product.json`). Updating or reinstalling Antigravity restores the originals, and the script then patches the new version again.
- On WSL older than 3.0, killing a `wsl.exe` client while its login session is being created can crash the distro's init process (microsoft/WSL#41592). The launcher and `20-user-manager.conf` are written to avoid that; their comments have the details.

## Removing it

```sh
systemctl disable --now antigravity-server.service antigravity-server-update.timer
rm -r /etc/systemd/system/antigravity-* /usr/local/bin/antigravity-* \
      /usr/local/lib/antigravity-server-common.sh /usr/local/share/antigravity-harness
systemctl daemon-reload
```

Update or reinstall Antigravity to drop the client patch. Reload each IDE window once.
