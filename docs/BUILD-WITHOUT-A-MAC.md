# Using VisionClaude with an iPhone and no Mac

You don't need a Mac. GitHub builds the iPhone app on its own Mac machines and
sends it to your phone through **TestFlight** (Apple's app for installing test
builds). The part that talks to Claude runs on your Windows or Linux PC.

```
Meta glasses ──Bluetooth──▶ iPhone (VisionClaude app) ──Wi-Fi / Tailscale──▶ your PC (Claude Code + channel)
```

What you need:

- An iPhone and Meta Ray-Ban glasses paired in the **Meta AI** app
- An **Apple Developer Program** membership ($99/year), which TestFlight requires
- A GitHub account with this repository forked (you've done this)
- A Windows, Linux or Mac computer that stays on while you use the glasses, with Claude Code

Every step below can be done in a web browser on your PC.

---

## Part 1: Apple (one-time)

1. **Join the Apple Developer Program** at <https://developer.apple.com/programs/enroll/>.
   Approval can take from a few minutes to a couple of days.

2. **Find your Team ID** at <https://developer.apple.com/account> → *Membership details*.
   It is 10 characters, like `AB12CD34EF`.

3. **Register a bundle ID** (your app's unique name):
   <https://developer.apple.com/account/resources/identifiers/list> → **+** →
   *App IDs* → *App* → Continue.
   - Description: `VisionClaude`
   - Bundle ID: *Explicit*, e.g. `com.yourname.visionclaude` (it can't be `com.claudevision.app`, because that one is taken)
   - Leave the capabilities alone → Continue → Register

4. **Create the app record** at <https://appstoreconnect.apple.com/apps> → **+** → *New App*:
   - Platform: iOS
   - Name: anything unique, e.g. `VisionClaude (yourname)`. Nobody else sees it.
   - Bundle ID: pick the one from step 3
   - SKU: anything, e.g. `visionclaude`
   - User access: Full Access

5. **Create an API key** so GitHub can sign and upload for you:
   <https://appstoreconnect.apple.com/access/integrations/api> → *Team Keys* → **+**
   (the first time, click *Request Access* first).
   - Name: `GitHub`
   - Access: **Admin**. GitHub needs this to create the signing certificate automatically.
   - Click *Download*. **You can only download the `.p8` file once**, so keep it safe.
   - Note the **Key ID** (next to the key) and the **Issuer ID** (at the top of the page).

## Part 2: Meta (optional to start)

While **Developer Mode** is on for your glasses, you can skip this part.

- **Turn on Developer Mode:** Meta AI app → Settings → your glasses → Developer Mode → ON.
  Then restart the glasses: hold the button for 15 seconds to power off, then press it to power on.

To have it work without Developer Mode, register the app with Meta:
<https://developers.meta.com> → create an app → *Wearables* → iOS configuration
with your Team ID and bundle ID → create a version → assign it to a release channel.
Copy the **App ID** and **Client Token**.

## Part 3: GitHub secrets (one-time)

In your fork on GitHub: **Settings → Secrets and variables → Actions → New repository secret**.
Add each of these:

| Secret name | Value |
|---|---|
| `APPLE_TEAM_ID` | Team ID from step 2 |
| `BUNDLE_ID` | Bundle ID from step 3, e.g. `com.yourname.visionclaude` |
| `ASC_KEY_ID` | Key ID from step 5 |
| `ASC_ISSUER_ID` | Issuer ID from step 5 |
| `ASC_KEY_P8` | Open the downloaded `AuthKey_XXXX.p8` in Notepad and paste **everything**, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `META_APP_ID` | *(optional)* Meta App ID |
| `META_CLIENT_TOKEN` | *(optional)* Meta Client Token, looks like `AR\|123…\|abc…` |

Secrets are encrypted. They never show up in the code or the build logs.

## Part 4: Build and install

1. In your fork, go to **Actions → iOS → Run workflow**. Pick the branch, leave
   *Sign and upload to TestFlight* ticked, and click **Run workflow**.
2. Wait for the **TestFlight** job to turn green (about 10–20 minutes). Apple then
   processes the build, which takes another 5–30 minutes.
3. In App Store Connect → your app → **TestFlight** → *Internal Testing* → **+**,
   create a group (e.g. `Me`), add yourself as a tester, and add the build to the group.
4. On your iPhone, install **TestFlight** from the App Store. Open the invite email
   (or just open TestFlight) and tap **Install** next to VisionClaude.

TestFlight builds expire after 90 days. To get a fresh one, run the workflow again.

## Part 5: Run Claude on your PC

### Windows (PowerShell)

```powershell
powershell -c "irm bun.sh/install.ps1 | iex"
npm install -g @anthropic-ai/claude-code
git clone https://github.com/<your-username>/visionclaude.git
cd visionclaude\ClaudeVision\channel
bun install
cd ..\..
claude --dangerously-load-development-channels "server:visionclaude"
```

Install [Node.js](https://nodejs.org) first if you don't have `npm`. When Windows
Firewall asks about Bun, allow it on **private networks**.

### Linux

```bash
curl -fsSL https://bun.sh/install | bash
npm install -g @anthropic-ai/claude-code
git clone https://github.com/<your-username>/visionclaude.git
cd visionclaude/ClaudeVision/channel && bun install && cd ../..
claude --dangerously-load-development-channels "server:visionclaude"
```

Run `claude` from the **root of the repo**. The included `.mcp.json` starts the
VisionClaude channel automatically.

Then open <http://localhost:18790> on the PC. It shows your **IP address** and **Channel Token**.

## Part 6: Connect everything

1. Open VisionClaude on the iPhone → **Settings**.
   - Host: the IP shown on the dashboard
   - Port: `18790`
   - Channel Token: the token from the dashboard
   - Tap **Connect**
2. In Settings, tap **Connect Glasses via Meta AI** and approve in the Meta AI app.
3. Switch the camera source to **Meta Ray-Ban**, then say *"What am I looking at?"*

## Using it away from home Wi-Fi

By default the phone has to be on the same Wi-Fi as the PC. To use it anywhere,
including on cellular:

1. Install [Tailscale](https://tailscale.com/download) on the PC and on the iPhone,
   and sign in with the same account on both.
2. In VisionClaude Settings, use the PC's **Tailscale IP** (starts with `100.`) as the Host.

The PC still needs to be on, with Claude Code running.

## Troubleshooting

- **TestFlight job fails at "Check secrets":** a secret is missing or misspelled. Names must match the table exactly.
- **"No profiles for '…' were found" / signing errors:** the API key needs the **Admin** role, and `BUNDLE_ID` must match the identifier you registered.
- **Upload fails with "No suitable application records":** create the app record (Part 1, step 4) with exactly the same bundle ID.
- **Glasses won't connect:** check that Developer Mode is still on (it can switch off after Meta AI updates), keep the glasses' hinges open, and try **Connect Glasses via Meta AI** again.
- **Phone can't reach the PC:** check that both are on the same Wi-Fi (or both on Tailscale), the firewall allows Bun, and <http://localhost:18790> works on the PC.
