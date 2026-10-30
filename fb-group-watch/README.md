# FB Group Watch

A small companion scanner for GitPulse. It checks the newest 5 posts in one Facebook group three times a day (12:00, 16:00, 20:00) and writes what changed to `gitpulse-fb.json`. GitPulse picks that file up and shows:

- **FB Post** (blue): a post that wasn't there before.
- **FB Comment** (purple): new comments on a post, e.g. "2 new comments on: …". Clicking it opens that comment.

It only reads. It never clicks, likes, comments or posts. It runs in a hidden Brave window with your own Facebook login.

> **Account risk.** Facebook's terms don't allow automated reading. This scanner keeps the footprint small: 2 page loads per run, 3 runs a day, random start times. If Facebook shows a login or checkpoint page, it stops immediately without retrying. The risk is low but not zero. Use a second account if that matters to you.

## Setup

1. **Install the prerequisites:**
   - [Brave](https://brave.com) in `/Applications`.
   - Node 20 or newer.
   - GitPulse 4.4 or newer.
2. **Install and log in:**
   ```
   cd fb-group-watch
   npm install
   mkdir -p logs
   node login.js
   ```
   `node login.js` opens a Brave window. Log in to Facebook with an account that is a member of the group. The window closes by itself once the group feed shows.
3. **Edit `config.js`:**
   - `groupURL` / `groupName`: the group to watch.
   - `selfName`: the name your own comments appear under, so they don't alert you.
4. **Run a first check:**
   ```
   node index.js
   ```
   It should print `Seeded: …`. The first run only records what's already there, so the backlog never pops up.
5. **Schedule it.** In `com.example.fb-group-watch.plist`, replace `__NODE__` with the output of `which node` and `__DIR__` with this folder's full path. Then run:
   ```
   cp com.example.fb-group-watch.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.fb-group-watch.plist
   ```
6. **Connect GitPulse:**
   1. Open GitPulse ▸ Settings and turn on **Watch a Facebook group**.
   2. Click **Choose feed file…** and pick `gitpulse-fb.json` in this folder.
   3. Pick a seen-log CSV. You can reuse the one from blog watch.

Never copy or share `profile/`. It holds a live Facebook login. It is git-ignored, along with `state.json`, `gitpulse-fb.json` and `logs/`.

## How it decides what's new

The scanner does two page loads per run:

- **"New posts" sort:** a post ID that is higher than every post seen before becomes an **FB Post**. The top 5 shift a little between loads, so an older post that drifts in is recorded silently, not flagged.
- **"Recent activity" sort:** a comment ID not seen before on that post becomes an **FB Comment**. Comments by `selfName` are skipped.

State lives in `state.json`, which keeps the latest 300 posts.

## Day to day

| Task | Command |
|---|---|
| Check now | `node index.js` |
| Preview without saving | `node index.js --dry` |
| Logged out or checkpoint (exit 1 in `logs/launchd.log`) | `node login.js`, then log in again |
| Stop the schedule | `launchctl bootout gui/$(id -u)/com.example.fb-group-watch` |
