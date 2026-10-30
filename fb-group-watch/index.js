// FB Group Watch: checks the newest posts in one Facebook group and writes new
// posts / new comments to a JSON file that GitPulse shows as chips. Read-only:
// it never clicks, likes, comments or posts. No AI involved.
//
//   node index.js            check now, update state + GitPulse file
//   node index.js --dry      print what would be added, change nothing
//   node index.js --jitter   wait 0-5 min first (used by launchd, so runs don't
//                            land at the exact same minute every time)
//
// Two page loads per run:
//   "New posts" sort      top N posts; a post id never seen = FB Post
//   "Recent activity" sort top N posts; a comment id never seen on a post = FB Comment
// First run seeds silently (records everything, emits nothing).
// Any sign of a logged-out / checkpoint page = exit 1 with no retry and no
// state change, so Facebook never sees a run hammering a blocked session.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const cfg = require('./config');

const DRY = process.argv.includes('--dry');
const STATE = path.join(__dirname, 'state.json');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function writeAtomic(file, obj) {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 1));
  fs.renameSync(tmp, file);
}

// Runs in the page. Reads every rendered feed row; FB virtualises the feed, so
// the caller scrolls and merges. Comment ids come from each comment article's
// own link, its author from the article's "Comment by NAME 3 days ago" label.
const EXTRACT = () => [...document.querySelectorAll('div[role="feed"] > div')].map((r) => {
  const hrefs = [...r.querySelectorAll('a[href*="/posts/"]')].map((a) => a.getAttribute('href'));
  const post = hrefs.map((h) => (h.match(/\/posts\/(\d+)/) || [])[1]).find(Boolean);
  if (!post) return null;
  const comments = [];
  for (const art of r.querySelectorAll('[role="article"][aria-label]')) {
    const m = art.getAttribute('aria-label').match(/^(?:Comment|Reply) by (.+?) (?:\d+ \w+ ago|a \w+ ago|an \w+ ago|just now|Yesterday)/i);
    const link = art.querySelector('a[href*="comment_id="]');
    const id = link && (link.getAttribute('href').match(/comment_id=(\d+)/) || [])[1];
    const reply = link && (link.getAttribute('href').match(/reply_comment_id=(\d+)/) || [])[1];
    if (id) comments.push({ id: reply || id, author: m ? m[1] : '' });
  }
  const msg = r.querySelector('[data-ad-preview="message"],[data-ad-comet-preview="message"]');
  const text = (msg ? msg.innerText : '').replace(/\s+/g, ' ').replace(/…?\s*See more$/i, '').trim();
  const author = (r.querySelector('h2,h3,h4')?.innerText || '').split('\n')[0].trim();
  return { post, author, text, comments };
}).filter(Boolean);

async function scan(page, sort) {
  await page.goto(`${cfg.groupURL}?sorting_setting=${sort}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  const blocked = /\/login|checkpoint|two_step/.test(page.url());
  const feed = !blocked && await page.waitForSelector('div[role="feed"]', { timeout: 30000 }).then(() => true).catch(() => false);
  if (!feed) throw new Error(`Facebook did not show the group feed (${page.url().split('?')[0]}). Session expired or checkpoint: run "node login.js" and log in.`);
  await sleep(3000);
  const posts = new Map();
  for (let i = 0; i < 12 && posts.size < cfg.maxPosts; i++) {
    for (const p of await page.evaluate(EXTRACT)) {
      const prev = posts.get(p.post);
      if (prev) {
        const ids = new Set(prev.comments.map((c) => c.id));
        prev.comments.push(...p.comments.filter((c) => !ids.has(c.id)));
        prev.text = prev.text || p.text;
      } else if (posts.size < cfg.maxPosts) posts.set(p.post, p);
    }
    await page.mouse.wheel(0, 1000 + Math.random() * 600);
    await sleep(1200 + Math.random() * 800);
  }
  return [...posts.values()];
}

(async () => {
  if (process.argv.includes('--jitter')) await sleep(Math.random() * 300000);
  const ctx = await chromium.launchPersistentContext(path.join(__dirname, 'profile'), {
    executablePath: cfg.brave, headless: true, viewport: { width: 1280, height: 1800 },
  });
  let newest, active;
  try {
    if (!(await ctx.cookies('https://www.facebook.com')).some((c) => c.name === 'c_user')) {
      throw new Error('Not logged in to Facebook: run "node login.js" and log in.');
    }
    const page = ctx.pages()[0] || await ctx.newPage();
    newest = await scan(page, 'CHRONOLOGICAL');
    active = await scan(page, 'RECENT_ACTIVITY');
  } finally {
    await ctx.close();
  }
  // Thin-result guard: a logged-in group always has posts. Zero means the page
  // changed shape or FB served something else; never seed or diff on that.
  if (!newest.length && !active.length) throw new Error('Feed returned no posts; Facebook layout may have changed. State left untouched.');

  const state = readJSON(STATE, null);
  const seeding = !state;
  const st = state || { posts: {} };
  const events = [];
  const now = new Date().toISOString();
  const link = (id, cid) => `${cfg.groupURL}/posts/${id}/${cid ? `?comment_id=${cid}` : ''}`;
  const title = (p) => (p.text || `Post by ${p.author || 'someone'}`).slice(0, 140);

  // The newest-posts list shifts a little between loads, so an older post can
  // drift into it. FB post ids grow over time: only an id above every post
  // already known is a genuinely new post; anything else is recorded silently.
  const maxKnown = Object.keys(st.posts).reduce((m, id) => (BigInt(id) > m ? BigInt(id) : m), 0n);
  for (const p of newest) {
    if (st.posts[p.post]) continue;
    st.posts[p.post] = { comments: p.comments.map((c) => c.id), firstSeen: now };
    if (!seeding && BigInt(p.post) > maxKnown) events.push({ key: `post:${p.post}`, kind: 'post', title: title(p), author: p.author, link: link(p.post), at: now });
  }
  for (const p of active) {
    const rec = st.posts[p.post] || (st.posts[p.post] = { comments: [], firstSeen: now });
    const known = new Set(rec.comments);
    const fresh = p.comments.filter((c) => !known.has(c.id));
    rec.comments.push(...fresh.map((c) => c.id));
    const others = fresh.filter((c) => c.author !== cfg.selfName);
    if (seeding || !others.length) continue;
    const names = [...new Set(others.map((c) => c.author).filter(Boolean))];
    const last = others[others.length - 1];
    events.push({ key: `comment:${p.post}:${last.id}`, kind: 'comment', title: title(p),
      author: names.slice(0, 2).join(', ') + (names.length > 2 ? ` +${names.length - 2}` : ''),
      link: link(p.post, last.id), count: others.length, at: now });
  }
  // Keep state bounded: the newest 300 posts by first sighting.
  const ids = Object.keys(st.posts).sort((a, b) => (st.posts[b].firstSeen || '').localeCompare(st.posts[a].firstSeen || ''));
  for (const id of ids.slice(300)) delete st.posts[id];

  const out = readJSON(cfg.outFile, { events: [] });
  out.group = cfg.groupName;
  out.updated = now;
  out.events = [...events, ...(out.events || [])].slice(0, cfg.keepEvents);

  const summary = `${seeding ? 'Seeded' : 'Checked'}: ${newest.length} newest + ${active.length} active posts, ${events.length} new event(s)`;
  if (DRY) { console.log(summary + ' (dry run)'); console.log(JSON.stringify(events, null, 1)); return; }
  writeAtomic(STATE, st);
  writeAtomic(cfg.outFile, out);
  console.log(summary);
  for (const e of events) console.log(`  ${e.kind}: ${e.title.slice(0, 70)} (${e.author})`);
})().catch((e) => { console.error(e.message); process.exit(1); });
