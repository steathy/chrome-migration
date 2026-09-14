# chrome-migration

Move a profile out of any Chromium-based browser into an **isolated Chrome
instance** with its own `--user-data-dir`, its own icon, and its own taskbar and
Start-menu identity.

Passwords, saved cards and cookies come across **without ever writing a plaintext
CSV** — they are decrypted with the source browser's key and re-encrypted with a
fresh one, in memory.

```powershell
irm https://raw.githubusercontent.com/steathy/chrome-migration/main/ChromeMigrate.ps1 | iex
```

That opens a menu in a window of its own. One file, no install, no modules.

---

## Why

A common way to keep identities apart — one family member per browser, or work in
Edge and personal in Brave — works, but caps out fast. There are only about five
actively-maintained Chromium browsers. Past that you end up on builds that are
one to ten years behind on security patches, which is a far bigger risk than
whatever the separation was protecting against.

One current Chrome with N data directories gives the same isolation without that
tax:

| Layer | Isolated by `--user-data-dir`? |
|---|---|
| Cookies, localStorage, IndexedDB, service workers | yes |
| HTTP cache, code cache, GPU shader cache | yes |
| Saved passwords, autofill, history, bookmarks, extensions | yes |
| HSTS, TLS session tickets, HTTP/2 and QUIC pools, DNS cache | yes |
| Browser, GPU and network processes | yes — separate process trees |
| Device fingerprint (GPU, fonts, screen, timezone, CPU count) | **no** |
| Saved-credential encryption vs. other instances | **no** — same Windows account, same DPAPI scope |

The last two rows are not limitations of this tool; no browser choice changes
them. Different vendors on one machine report the same GPU, fonts, screen and
timezone. If you need protection *between people*, give them separate Windows
accounts — that is the first boundary with its own DPAPI scope.

---

## Requirements

* Windows 10 or 11
* Windows PowerShell 5.1 (built in) or PowerShell 7+
* Chrome installed, for the target instances
* **The same Windows account that created the source profile.** The encryption
  key is DPAPI-wrapped to that account; a different one migrates everything
  except passwords, cards and cookies.

No admin rights, no downloads, no modules. SQLite comes from `winsqlite3.dll` and
AES-GCM from `bcrypt.dll`, both shipped with Windows.

---

## Running it

Three forms, and they behave differently:

| Form | Arguments | Notes |
|---|---|---|
| `irm <url> \| iex` | none possible | Always the menu, in its own window |
| `& ([scriptblock]::Create((irm <url>))) -List` | yes | Nothing on disk, still scriptable |
| `.\ChromeMigrate.ps1 -List` | yes | Sets exit code 1 on failure |

`iex` runs the text in the caller's scope, so it cannot receive parameters — use
the scriptblock form for those. It also means the script never calls `exit`
unless it is genuinely running as a file, since that would close your window.

The menu re-launches itself into a fresh console so it is not fighting your
prompt and scrollback. `-NoRelaunch` keeps it inline. Command-line runs always
stay inline — their output belongs where you asked for it.

```
 1  Scan for browsers and profiles
 2  Migrate a profile into an isolated Chrome instance
 3  Fix the taskbar icon for an instance
 4  Add an instance to the Start menu
 5  Change an instance picture (use your own image)
 6  Show existing instances
 7  Launch an instance
 8  Change the instance root folder
 0  Exit
```

If you copied the file from another machine it carries a Mark-of-the-Web; either
`Unblock-File .\ChromeMigrate.ps1`, or run
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ChromeMigrate.ps1`.

---

## Command line

Close the source browser first — migration refuses to start while it is running.

```powershell
# What is installed, and how much is in each profile
.\ChromeMigrate.ps1 -List

# Preview - writes nothing
.\ChromeMigrate.ps1 -Source Vivaldi -Name bob -DryRun

# Migrate
.\ChromeMigrate.ps1 -Source Vivaldi -Name bob -IncludePasswords -IncludeCards

# Taskbar icon, then a Start-menu entry
.\ChromeMigrate.ps1 -Name bob -SetTaskbarIcon
.\ChromeMigrate.ps1 -Name bob -StartMenu

# Use your own picture
.\ChromeMigrate.ps1 -Name bob -SetIcon -Icon C:\pics\bob.png
```

This creates `C:\Browsers\bob`, seeds it from the source profile, and puts a
desktop shortcut with a generated colour-coded icon. **The source browser is only
ever read** — nothing in it is modified or deleted, so rollback is deleting the
new folder and the shortcut.

| Parameter | Meaning |
|---|---|
| `-List` | Show detected browsers, profiles, login/card/extension counts |
| `-Source <name>` | Source browser |
| `-Name <label>` | Instance name — folder, profile name, shortcut, icon letters |
| `-Root <path>` | Parent folder for instances. Default `C:\Browsers` |
| `-SourceProfile <name>` | Which source profile. Default: first found |
| `-SourceUserData <path>` | Override auto-detection |
| `-ChromePath <path>` | Target executable. Default: installed Chrome |
| `-IncludePasswords` | Migrate saved logins (both stores) |
| `-IncludeCards` | Migrate saved credit cards |
| `-IncludeCookies` | Migrate live sessions. **Off by default** |
| `-IncludePreferences` | Carry settings over, extension block stripped |
| `-Icon <path>` | Use your own image instead of the lettered disc |
| `-SetIcon` | Replace an existing instance's icon |
| `-SetTaskbarIcon` | Read the AUMID off the instance's window and write it onto the shortcut |
| `-StartMenu` | Install an AUMID-free copy for Start |
| `-ShowAumid` | Print the AUMID currently on the shortcut |
| `-NoShortcut` / `-ShortcutPath` | Skip or relocate the shortcut |
| `-NoRelaunch` | Keep the menu in the current console |
| `-Force` | Overwrite an existing instance |
| `-DryRun` | Report only, write nothing |
| `-IgnoreRunningCheck` | Last resort — migrate anyway. See below |

`-IncludeCookies` is off deliberately. For a banking or finance profile you
generally *want* to log in fresh, and stale session cookies are a liability.

---

## It will not migrate while the source browser is running

A live SQLite database copies in a torn state, so this is a hard gate with three
independent signals; any one blocks:

1. a process running out of the browser's install directory
2. a process with the browser's user-data path on its command line
3. a profile database (`Cookies`, `Web Data`, `History`, `Login Data`) held open
   by anyone — opened with `FileShare.None`, which fails if *any* other handle
   exists

Signal 3 is the backstop: it needs no knowledge of where the browser was
installed, so a source that failed to resolve on disk still cannot slip past. A
dry run is allowed through with a warning, since it only reads.

`-IgnoreRunningCheck` exists for the case where the guard misfires — an antivirus
or backup agent holding a database open looks identical to a running browser. It
is not offered in the menu.

---

## Icons

Each instance gets a coloured disc with its initials at
`<Root>\_icons\<Name>.ico`, written as a real multi-resolution ICO —
16/24/32/48/64 as uncompressed 32-bit BMP, 128/256 as PNG.

That matters. A single 256px PNG-compressed entry is legal, but it leaves every
shell consumer — Explorer's thumbnail handler, its icon handler, the shortcut
renderer, the taskbar — to rescale it themselves. They do not all agree, and they
cache the result, which is how one folder ends up showing some icons large and
some small. Giving each consumer an exact-size match removes the guesswork.

To use your own picture:

```powershell
.\ChromeMigrate.ps1 -Name bob -SetIcon -Icon C:\pics\bob.png
```

or menu option **5**. Any format GDI+ reads — `.png`, `.ico`, `.jpg`, `.bmp`.
Non-square input is centred on a transparent square rather than stretched. It
rebuilds the `.ico`, re-points every shortcut for that instance (desktop, common
desktop and Start menu), preserves the taskbar AUMID, and nudges the shell to
drop its cached icons.

You can also just overwrite `<Root>\_icons\<Name>.ico` yourself — the shortcut
already points there. Expect to have to unpin and re-pin, since the shell caches
shortcut icons hard and a plain overwrite usually shows no change.

Leaving `-Icon` off with `-SetIcon` regenerates the lettered disc, which is the
quick way to bring older instances up to the multi-size format.

---

## Supported sources

Sidekick, Edge, Brave, Vivaldi, Opera, Opera GX, Cent Browser, SRWare Iron
(installed and portable), Comodo Dragon, Maxthon, Blisk, Chromium — and Yandex
with a caveat.

**Chrome is not a source.** It is the destination, and Chrome-to-Chrome is just a
folder copy.

Real per-browser differences the script handles:

* **Opera** keeps its profile at the root of `Opera Stable` rather than in a
  `Default` subfolder. Both layouts are detected.
* **Cent Browser** and **SRWare Iron** both ship their binary *as* `chrome.exe`.
  "Is it running?" is therefore decided by executable path, not process name —
  matching on the name would flag real Chrome and refuse to run.
* **SRWare Iron** installs to `SRWare Iron (64-Bit)` and stores its profile in
  `%LOCALAPPDATA%\Chromium\User Data` — the same directory real Chromium uses.
  That path is treated as *shared*: Iron claims it only when Iron's executable is
  installed. Where entries still collide, the one with an executable wins, and
  `-List` prints a `NOTE:` when two installed browsers genuinely conflict. A
  profile whose browser was uninstalled is still listed, so orphaned data stays
  reachable.
* **SRWare Iron portable** is a separate source, `IronPortable`. SRWare's own zip
  unpacks to `IronPortable64`, where `IronPortable.exe` is only a launcher: the
  browser runs from `Iron\` beside it and the profile lives in `Profile\`. It
  never touches Chromium's directory, so it is kept apart from the installed
  Iron's shared-directory rule. A copy outside `Program Files` needs
  `-SourceUserData '<folder>\Profile'`.
* **Maxthon** ships as a portable zip as well as an installer, and the two keep
  their profile in different places: the portable build beside `Maxthon.exe`
  (`C:\Program Files\MaxthonPortable\User Data`), the installed one *inside* its
  `Application` folder (`%LOCALAPPDATA%\Maxthon\Application\User Data`) rather
  than next to it. Both are detected. A portable copy unpacked anywhere else
  needs `-SourceUserData`.
* **Vivaldi** writes a `Local State` that Windows PowerShell's `ConvertFrom-Json`
  rejects — it throws on empty and case-duplicate property names. The os_crypt
  key is read with a tolerant parser plus a text fallback.
* **Edge** keeps background processes alive when Startup Boost is on, so it reads
  as running even with no window open — and it genuinely is, holding the profile
  databases. Turn Startup Boost off at `edge://settings/system` and end any
  leftover `msedge.exe`.
* **Yandex** installs machine-wide as often as per-user, putting its executable at
  `C:\Program Files\Yandex\YandexBrowser\Application\browser.exe` while the
  profile stays in `%LOCALAPPDATA%`. It also does not use `Login Data` or
  `Web Data` at all — it has `Ya Passman Data` and `Ya Credit Cards`, and its
  password blobs carry neither a `v10` header nor a DPAPI one. It uses its own
  crypto, so **passwords and cards cannot be migrated**. The script reports the
  real login count, says so plainly, and skips them rather than silently
  reporting zero. Everything unencrypted still moves — export Yandex passwords to
  CSV from its own UI.

---

## How the encrypted data moves

Chromium keeps an AES-256 key in `Local State`, DPAPI-wrapped to your Windows
account. Because source and target run under the same account, the script can:

1. Unwrap the source key via DPAPI
2. Generate a **new** random 32-byte key for the target and write it into the
   target's `Local State`
3. Decrypt each secret with the old key and re-encrypt with the new one, in
   Chromium's `v10` container:
   `"v10" || 12-byte nonce || ciphertext || 16-byte tag`

Secrets exist only in memory. The new instance ends up with its **own**
independent key rather than inheriting the source's.

Values with no version prefix predate Chrome 80 and are DPAPI-wrapped directly;
Chrome still reads those, so the script does too, rewriting them as `v10`. `v20`
(app-bound, Chrome 127+) cannot be converted — that key is bound to the
originating executable.

**Expected on first launch:** Chrome rewrites `os_crypt.encrypted_key` in
`Local State`. That is a DPAPI *re-wrap*, not a new key — DPAPI output is
randomised, so the base64 changes while the underlying AES key does not.

---

## What is not migrated

* **Cache** — disposable, version-specific, and copying it risks corruption.
* **Extensions** — must be reinstalled. The script prints each one's Web Store URL
  and flags Manifest V2 add-ons, which current Chrome refuses to load at all.
  Common replacements: uBlock Origin → uBlock Origin **Lite**; legacy 1Password
  ("desktop app required") → the current extension; Proxy SwitchyOmega 2.x → the
  maintained V3 fork.
* **Cookies**, unless `-IncludeCookies` is passed.

---

## Troubleshooting

**`running scripts is disabled on this system`**
Execution policy, separate from Mark-of-the-Web. Either
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ChromeMigrate.ps1`, or
`Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force`
(after which `Unblock-File` is still needed for copied scripts).

**`<browser> is still running` when you are sure it is closed**
Read the listed reasons. Chromium browsers commonly leave background processes
behind (Edge's Startup Boost, "continue running background apps when closed" in
most others) — check the tray, or end the process by the PIDs printed. If the
only signal is *"profile files are held open"* and no browser process exists, an
antivirus or backup agent is likely holding the database.

**`passwords: 73/80 re-encrypted, 7 skipped`**
Usually not a loss. When a profile's `os_crypt` key is regenerated, Chromium
orphans the old rows and saves fresh ones on the next successful login — so
unreadable rows normally have readable twins. Check
`chrome://password-manager/passwords` in the new instance before deleting
anything. Rows with an empty `password_value` are never-save entries and
federated logins ("Sign in with Google"), which hold no password by design.

**`[Type] does not contain a method named '...'`**
An older copy ran earlier in the same PowerShell session and .NET cannot unload a
type. **Open a new PowerShell window.**

**`nothing incremented` when setting the taskbar icon**
That is 1.2 or earlier, which waited for Explorer's taskbar-switch counters to
move after you clicked the window — and those often did not. The current version
reads the AUMID straight off the instance's window and needs no clicks.

**`no <name> window appeared within 30 seconds`**
The instance did not open, or is running on a different folder than
`<Root>\<Name>`. Open it from its desktop shortcut and run `-SetTaskbarIcon`
again — an instance that is already running is read without relaunching it.

**Taskbar still shows the Chrome logo**
The pinned `.lnk` is a copy. Unpin, re-run `-SetTaskbarIcon`, re-pin, and launch
from the pinned icon. If it persists, restart Explorer to clear the icon cache.

**`could not unwrap ...'s key via DPAPI`**
You are signed in as a different Windows account than the one that created the
profile. Everything else still migrates; use CSV export/import for passwords.

---

## Security notes

* **Do not sign in to a Google account with sync enabled** unless you want the
  instances pooled. Sync follows the account, not the data directory, and undoes
  the isolation in one click. Use one account per instance, or stay signed out.
* **Same Windows account means the same DPAPI scope.** Instances are isolated
  from each other's *sessions*, not cryptographically. Anything running as you
  can read every instance. For separation between people, use Windows accounts.
* **Keep finance instances extension-free.** A compromised extension with host
  permissions is the most realistic way a session gets stolen on a patched
  browser. Do not carry over UA spoofers, cookie editors, userscript managers or
  proxy switchers — a UA spoofer in particular makes the fingerprint internally
  inconsistent, which fraud systems flag.
* **Banks want a stable device fingerprint.** Randomising it causes more step-up
  challenges, not fewer.
* A password manager with its own vault survives migrations like this one. A
  browser password store is exactly what breaks.
* **Read before you pipe.** `irm | iex` runs whatever is at that URL. The whole
  point of this script is that it can read your saved passwords, so treat it the
  way you would any other tool with that reach — open the raw file first.

---

## Verified on

Windows 10 Pro and Windows 11 Pro, PowerShell 5.1.

* Sidekick 124.61.1.50294 → Chrome 151, full round trip — 50/50 logins and
  2828/2847 cookies re-encrypted
* Vivaldi 8.1.4087.61 → Chrome 151 — 33/35 re-encrypted; the two remaining rows
  hold empty passwords by design
* Re-encrypted passwords verified byte-identical to the originals by comparing
  SHA-256 digests of the decrypted plaintext on both sides
* All three invocation forms exercised, including the literal `irm <url> | iex`
  against the published copy
* Detection exercised against Sidekick, Edge, Brave, Vivaldi, Yandex, Opera,
  Cent Browser, Comodo Dragon and Chromium on one machine
* Running guard confirmed firing on all three signals for Edge with Startup Boost
  on, and on none of them for a closed browser
* Generated ICOs confirmed to carry all seven frames, with Windows resolving
  16/32/48 to exact matches
* Maxthon (portable and installed) and Blisk detected and migrated end to end
  against their on-disk layouts rebuilt in a sandbox — not yet against the real
  browsers
* `-SetTaskbarIcon` confirmed to write exactly the AUMID the instance's window
  reports, with no clicks — for an instance not yet running, one already
  running, and `bob` next to `bob2`
* SRWare Iron portable detected and migrated end to end against its layout rebuilt
  in a sandbox, next to a leftover Chromium profile that it does not claim

---

## Licence

MIT. Use at your own risk; the source browser is never modified, so the rollback
is always to delete the new instance.
