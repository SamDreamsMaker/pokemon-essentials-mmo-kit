# Installing the PEMK server on Windows — from zero

This guide is for someone who has **never used Linux**. It gets the dedicated
PEMK server running on your Windows PC so you can play and test. You'll do the
install **once**; after that, starting the server is a single double-click.

The server is a Linux program (Ruby + PostgreSQL). On Windows it runs inside
**WSL** — a lightweight Linux that Windows ships with, no separate PC or virtual
machine needed. The game itself still runs as a normal Windows program.

**Time:** about 20–30 minutes the first time, most of it unattended downloads.

---

## What you'll end up with

```
Windows
├─ Game.exe (the mkxp-z client)  ──TCP 127.0.0.1:9998──┐
└─ WSL (Debian Linux)                                  │
   ├─ PEMK server (Ruby)  ◀───────────────────────────┘
   └─ PostgreSQL database (your accounts, money, Pokémon…)
```

You never open a Linux terminal for day-to-day play — `PlayMMO-server.bat` does
it for you. You only use the terminal **once**, for the install below.

---

## Step 1 — Install WSL + Debian

1. Open the **Start menu**, type `PowerShell`, right-click **Windows PowerShell**
   and choose **Run as administrator**.
2. Run:
   ```powershell
   wsl --install -d Debian
   ```
   This turns on WSL and downloads **Debian** (the Linux we use).
3. **Restart your PC** if it asks you to.
4. After the restart, a black **Debian** window opens on its own (or open it from
   the Start menu by typing `Debian`). The first launch takes a minute, then asks
   you to create a Linux username and password:
   - Pick any username (e.g. your first name, lowercase, no spaces).
   - Pick a password. **You won't see anything as you type it — that's normal.**
     Press Enter. You'll type this password occasionally for admin steps.

> **If `wsl --install` fails** or says virtualization is off, see
> [Troubleshooting](#troubleshooting) at the bottom — usually one BIOS setting.

You now have a Linux prompt that looks like `yourname@PC:~$`. Leave this window
open for the next step.

---

## Step 2 — Run the one-time setup script

The repo lives on your Windows drive. WSL can read your `C:` drive at `/mnt/c`.
In the **Debian** window, go to the server folder and run the setup script
(replace the path if your repo is elsewhere):

```bash
cd "/mnt/c/Pokemon Essentials MMO Kit/server"
bash bin/setup.sh
```

`setup.sh` is **idempotent** — safe to run again anytime. It will:

1. Install Ruby, PostgreSQL and the build tools (this one step needs your Linux
   password — type it when prompted; again, the typing is invisible).
2. Create a **private database cluster** just for PEMK in your Linux home folder
   (`~/pemk-pgdata`, port **55432**). It never touches any other PostgreSQL you
   might have.
3. Write its settings to `~/pemk-env.sh`.
4. Create the `pemk` (play) and `pemk_test` (tests) databases.
5. Install the Ruby libraries and set up the database tables.

When it finishes you'll see:

```
==> Done. Start the server with:  bash bin/dev-server.sh   (or PlayMMO-server.bat)
==> Run the tests with:           bash bin/run-tests.sh
```

That's it — the install is done. You can close the Debian window; the next steps
are all double-clicks from Windows.

---

## Step 3 — Start the server

In Windows Explorer, go to the repo folder and **double-click
`PlayMMO-server.bat`**.

A console window opens and ends with:

```
PEMK server starting on 0.0.0.0:9998 (Ctrl-C to stop)
```

**Leave this window open while you play.** Closing it (or pressing Ctrl-C) stops
the server. It automatically starts the database, applies any new updates, and
frees the port from a previous run — so you can just re-launch it whenever.

---

## Step 4 — Play

1. Double-click **`PlayMMO-debug.bat`**. At the load screen choose **Create
   account**, enter an **email + password**, then play the short intro (it sets
   your character's name). Your progress now lives on the server.
2. To test multiplayer on the same PC, also double-click **`PlayMMO-guest.bat`** —
   a second window that reads `mmo_config_guest.txt`. Create a **different**
   account there so the two windows are two separate players.
3. Get both characters onto the same map — each appears in the other's world.
   - **Battle:** pause menu → **Battle Player** → pick the other → they accept.
   - **Trade:** pause menu → **Trade Player**.

Later launches log straight in with the saved session — no need to re-enter your
password.

---

## Everyday use (after install)

| I want to… | Do this |
|---|---|
| **Start the server** | Double-click `PlayMMO-server.bat`, leave it open |
| **Stop the server** | Close its window (or Ctrl-C in it) |
| **Play** | `PlayMMO-debug.bat` (+ `PlayMMO-guest.bat` for a 2nd player) |
| **Run the server tests** | In Debian: `cd "/mnt/c/Pokemon Essentials MMO Kit/server" && bash bin/run-tests.sh` |
| **Re-install / repair** | Re-run `bash bin/setup.sh` (safe to repeat) |

---

## Playing with friends over the network

By default the server only accepts connections from your own PC. To let friends
join:

1. Keep the server running on your PC (`PlayMMO-server.bat` already binds all
   interfaces, `0.0.0.0:9998`).
2. **Allow the port through the firewall.** The first time the server runs,
   Windows may pop up a firewall prompt — click **Allow**. Otherwise add an
   inbound rule for **TCP port 9998**.
3. Share your address:
   - **Same house / LAN:** run `ipconfig` in PowerShell, share your **IPv4
     Address** (like `192.168.1.20`).
   - **Over the internet:** port-forward TCP **9998** on your router to your PC,
     and share your public IP. (Easier and safer: use **Tailscale** and share
     your Tailscale IP — no port-forwarding, and it's encrypted.)
4. **Each friend** edits `mmo_config.txt` in their game folder:
   ```ini
   host = <your address>
   port = 9998
   ```
   then launches `Game.exe` and creates their account in-game.

> ⚠️ The connection is plain (unencrypted) TCP. Only play with **people you
> trust**, or over **Tailscale**. A public server exposed without TLS is a
> security risk — details in [`ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md).

---

## Troubleshooting

**`wsl --install` says it's not recognized, or nothing downloads.**
You need Windows 10 (2004+) or Windows 11. Update Windows, then retry in an
**administrator** PowerShell.

**It complains about virtualization / "Hyper-V" / error `0x80370102`.**
Virtualization is off in your BIOS. Reboot into BIOS/UEFI (usually Del or F2 at
startup), enable **Intel VT-x** / **AMD-V** (sometimes called "SVM" or
"Virtualization Technology"), save, and boot back to Windows.

**The Debian window closes instantly / "no distribution."**
Run `wsl --install -d Debian` again in an admin PowerShell, reboot, then open
**Debian** from the Start menu so it can finish first-time setup (the username/
password step).

**`PlayMMO-server.bat` flashes and closes, or says "command not found".**
The one-time setup didn't complete. Open **Debian** and run
`bash "/mnt/c/Pokemon Essentials MMO Kit/server/bin/setup.sh"` again, watching for
any error near the end.

**"Port 9998 already in use" or the game can't connect.**
An old server is still running. `PlayMMO-server.bat` normally clears it, but you
can force it: in Debian run `pkill -f 'ruby bin/pemk_server.rb'`, then relaunch
the `.bat`.

**Your repo isn't on `C:`.**
Use its real path under `/mnt`. A folder at `D:\Games\PEMK` is
`/mnt/d/Games/PEMK` in WSL. Keep the quotes around paths that contain spaces.

**Reset everything and start clean.**
In Debian: stop the server, then
`rm -rf ~/pemk-pgdata ~/.pemk-bundle ~/pemk-env.sh` and re-run `bin/setup.sh`.
This wipes the local server database (accounts, saved money/Pokémon) — only do it
if you want a fresh start.

---

## What the install created (for reference)

Everything lives in your Linux home folder — nothing is installed system-wide
except the base packages, and nothing here conflicts with other software:

| Path | What it is |
|---|---|
| `~/pemk-pgdata` | the PEMK PostgreSQL database cluster (port 55432) |
| `~/pemk-env.sh` | generated settings (paths, `DATABASE_URL`) the scripts load |
| `~/.pemk-bundle` | the server's Ruby libraries |
| databases `pemk`, `pemk_test` | your live data, and the isolated test data |

To understand what the server actually stores and how secure it is, read
[`ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md).
