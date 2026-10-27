# GameBoost

**A safe, reversible gaming optimizer for Windows 10 and 11.** It's made for laptops and budget GPUs (RTX 2050, GTX 1650, RTX 3050, Radeon RX 6500M and similar), but it works on any PC.

GameBoost doesn't rely on placebo registry hacks or permanently disable services, and it never deletes files. It makes a few changes that actually help, it **won't break your work while you game**, and **every change can be undone with one click**.

---

## What it does

| | Feature | What it means for you |
|---|---|---|
| 🔍 | **PC Check** | Finds what's holding your FPS back: running on battery, single-channel RAM, an old driver, an HDD, a full disk, or too many startup apps. It's read-only and changes nothing. |
| ⚙️ | **One-time tune-up** | Turns on Game Mode and GPU scheduling, turns off Xbox background recording, turns on windowed-game optimizations, and tells the Windows scheduler to favor games. |
| 🎮 | **Every game on the fast GPU** | Finds games from **Steam, Epic, Ubisoft, EA, GOG, Xbox, and Riot** and forces them onto your dedicated GPU instead of the weak integrated chip. This is the #1 cause of low FPS on laptops. |
| 🔄 | **Auto-setup for future games** | Turn it on once, and every game you install later (Black Myth: Wukong, whatever comes next) is set up automatically at your next login. |
| 🚀 | **Boost mode** | Pauses background services and apps **only while you play**, then puts everything back when you're done. |
| ↩️ | **Undo everything** | Every setting is backed up before it's changed. One click restores your PC exactly as it was. |

---

## 🛡️ How Boost keeps your work safe

Most "game booster" scripts kill everything in sight. If VS Code is open and a dev server is running in the background, those scripts can take down your server, your database, or Docker in the middle of your work.

**GameBoost works the other way around.** It never closes "everything except a few things." It only touches a **short, curated list** of things known to be safe to pause, and even those are skipped if you're using them.

**Never touched (protected automatically):**
- **Any app with an open window**, such as VS Code, your browser, Discord, or OBS
- **Anything serving on a network port**, such as `npm run dev`, Vite, Django, Flask, Docker, Postgres, MySQL, Redis, or Ollama. If it's listening on a port, it's protected.
- **Everything started by a protected app.** For example, a `node` server you launched from VS Code's terminal is protected because VS Code is.
- **Anything in your `protect` list** in `config.json`, which ships with common IDEs, runtimes, databases, Docker, WSL, and game launchers

**Not closed, just made to wait:** heavy apps you're still using, like VS Code or Chrome, get **lower CPU priority** during the session. They keep running normally but give way to the game when CPU is tight.

**Paused while you play, then restored:**
- Windows Search indexing, Superfetch, telemetry, Delivery Optimization, and error reporting
- Edge, Google, and Adobe updaters
- Cloud sync in the background (OneDrive, Dropbox, Google Drive), which reopens afterwards
- The power plan is switched to maximum performance, then switched back

Before Boost changes anything, it **shows you exactly what it will keep running and what it will pause**. Example:

```
Keeps running - your work is safe:
   + node      (serving on port 3000, 5173)
   + postgres  (serving on port 5432)
   + Code      (protected)

Left alone because they are in use:
   = Dropbox (has an open window)

Paused until you finish gaming:
   - Power: switch to maximum performance
   - Service: Windows Search - Windows Search indexing - heavy disk and CPU use
   - Service: SysMain - Superfetch - preloads apps into RAM...
   - Lower priority (still running): Code, chrome
```

Services are **stopped, never disabled**. The session is saved to disk before anything changes, so if your PC crashes or you close the window, GameBoost offers to restore everything the next time it opens.

---

## Quick start

1. **Download** this repo (green **Code** button → **Download ZIP**) and extract it somewhere permanent, for example `C:\Tools\GameBoost`.
2. Double-click **`GameBoost.bat`** and click **Yes** when Windows asks for admin permission.
   - If you see *"Windows protected your PC"*, click **More info** → **Run anyway**. The scripts are plain text, so you can read every line before running them.
3. Run **[1] Check**, then **[2] Optimize Windows**, then **[7] Auto-setup new games**. Restart your PC.
4. Before each gaming session, double-click **`Boost-Now.bat`**. When you're done playing, press **Enter** in that window.

---

## Command line

```powershell
.\GameBoost.ps1                         # menu
.\GameBoost.ps1 -Action Check           # PC check (no admin needed)
.\GameBoost.ps1 -Action Tune            # one-time tweaks + scan games
.\GameBoost.ps1 -Action Scan            # set up newly installed games
.\GameBoost.ps1 -Action Preview         # see what Boost would do
.\GameBoost.ps1 -Action Boost           # boost, wait for Enter, restore
.\GameBoost.ps1 -Action Boost -NoWait   # boost and exit...
.\GameBoost.ps1 -Action Restore         # ...then restore later
.\GameBoost.ps1 -Action AutoScanOn      # auto-setup new games at login
.\GameBoost.ps1 -Action Undo            # reverse everything
```

---

## Customizing (`config.json`)

| Setting | What it does |
|---|---|
| `protect.processes` | Apps Boost must never touch. Add your own, e.g. `"MyServer"` (no `.exe`). |
| `protect.windowedApps` / `listeningPorts` | Automatic protection rules. Leave these `true`. |
| `boost.pauseServices` | Windows services paused during Boost. Set `"enabled": false` to keep one running. |
| `boost.closeApps` | Background apps closed during Boost. Teams, Slack, Spotify, and Edge are included but **off** by default. |
| `boost.lowerPriority` | Apps that keep running at lower CPU priority while you play. |
| `games.extraLibraryFolders` | A folder that contains your games, e.g. `"D:\\MyGames"`. Use double backslashes. |
| `games.extraGameFolders` | A single game's folder, if it's installed somewhere unusual. |

---

## What GameBoost does NOT do (on purpose)

- ❌ Disable Windows Defender, the firewall, or Windows Update permanently
- ❌ Delete files or "clean" the registry
- ❌ Overclock or undervolt anything
- ❌ Apply placebo network or "Nagle" tweaks that don't help modern games
- ❌ Touch anything it can't put back

---

## Things a script can't do (but you should)

**On laptops:**
- **Keep the charger plugged in.** Laptop GPUs are heavily throttled on battery.
- **Use your laptop maker's app** (Armoury Crate, Lenovo Vantage, Omen Gaming Hub, NitroSense, MSI Center) to set **Turbo/Performance** mode. If it has a **dGPU-only / MUX switch** option, turn it on, often for +10–20% FPS.
- **Keep it cool.** Raise the back of the laptop or use a cooling pad.

**Graphics driver settings:**
- **NVIDIA Control Panel** → Manage 3D settings: set *Power management mode* to **Prefer maximum performance** and *Low latency mode* to **On**.
- **AMD Adrenalin:** turn on **Radeon Anti-Lag**. Turn off **Radeon Chill** while gaming.

**In-game, these usually help most:**
1. **Upscaling:** turn on **DLSS** (NVIDIA RTX), **FSR**, or **XeSS** and set it to Quality or Balanced. This is the biggest single FPS gain.
2. **Texture quality:** match it to your VRAM. 4 GB cards → Medium textures. Going over VRAM causes stutter.
3. **Lower these first:** shadows, volumetric fog/clouds, ambient occlusion, and ray tracing
4. **Frame generation** (DLSS 3/4 FG on RTX 40/50, FSR 3 FG on most GPUs) can double displayed FPS when your base FPS is already 40+.
5. Turn off V-Sync in the game and use your monitor's G-Sync/FreeSync if it has it.

**Hardware upgrades with the best value:**
- **16 GB dual-channel RAM** (2 sticks). Single-channel RAM can cost 15–30% FPS.
- **Games on an SSD**, not an HDD

> **Honest expectations:** GameBoost removes software overhead and makes sure your GPU is actually used. It can't turn an entry-level GPU into a high-end one. On an RTX 2050 class card, expect 1080p at low-to-medium settings with upscaling in demanding new games.

---

## FAQ

**Is it safe?** Every change is backed up to `%LOCALAPPDATA%\GameBoost\` and reversed by Undo. The one-time tune-up also creates a Windows restore point when System Protection is on. A log is kept at `%LOCALAPPDATA%\GameBoost\gameboost.log`.

**My dev server was protected, but I want Boost to pause it.** Close it yourself before gaming. Boost will never decide to stop your work for you.

**A game isn't found.** Use **[6] Add a game manually**, or add its folder to `games.extraLibraryFolders` in `config.json`.

**Xbox / Game Pass games?** Games installed in an `XboxGames` folder are scanned. Older Store games inside the protected `WindowsApps` folder can't be scanned. For those, set **Settings → System → Display → Graphics → High performance** by hand.

**I moved the GameBoost folder and auto-setup stopped.** Turn auto-setup off and on again from the new location.

---

## Requirements

- Windows 10 (1903+) or Windows 11
- Windows PowerShell 5.1, which is built into Windows
- Admin rights for everything except Check and Scan

## Contributing

Pull requests are welcome, especially:
- More launchers (Battle.net, Rockstar, itch.io)
- More services or apps that are **safe** to pause, with a short reason for each
- Translations

Please keep the project's rule: **every change must be reversible and must never touch something the user is using.**

## License

[MIT](LICENSE) © 2026 Vardan Chaturvedi

*GameBoost is not affiliated with Microsoft, NVIDIA, AMD, Intel, Valve, Epic, Ubisoft, EA, or any game publisher. Use at your own risk.*
