// One-time (or after the session expires) manual Facebook login.
//   node login.js
// Opens a real Brave window on the group. Log in yourself (2FA included); the
// window closes once the group feed renders. The persistent profile in
// profile/ (700) is then reused headless by index.js.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const cfg = require('./config');

(async () => {
  const dir = path.join(__dirname, 'profile');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  fs.chmodSync(dir, 0o700);
  const ctx = await chromium.launchPersistentContext(dir, { executablePath: cfg.brave, headless: false, viewport: null });
  const page = ctx.pages()[0] || await ctx.newPage();
  await page.goto(cfg.groupURL);
  console.log('Log in to Facebook in the opened window. Waiting up to 10 min...');
  const until = Date.now() + 600000;
  for (;;) {
    // A public group renders its feed logged out too, so the feed alone proves
    // nothing. c_user is the cookie Facebook sets only for a signed-in account.
    const signedIn = (await ctx.cookies('https://www.facebook.com')).some((c) => c.name === 'c_user');
    const feed = signedIn && await page.evaluate(() => !!document.querySelector('div[role="feed"]')).catch(() => false);
    if (feed) break;
    if (signedIn && !/\/groups\//.test(page.url())) await page.goto(cfg.groupURL).catch(() => {});
    if (Date.now() > until) throw new Error('Timed out waiting for login');
    await new Promise((r) => setTimeout(r, 2000));
  }
  await page.waitForTimeout(3000);
  console.log('Logged in, group feed visible. Profile saved.');
  await ctx.close();
})().catch((e) => { console.error(e.message); process.exit(1); });
