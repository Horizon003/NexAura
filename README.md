# NEXAURA — Virtual Game Economy (Single-File App)

A futuristic mobile-first web app for a **virtual game economy**: NXC virtual coins,
digital game cards with 30-day progression, a percentage-based referral system,
an operator-verified deposit desk, operator-verified withdrawals, and a full
**operator console** with authority over every number in the economy.

**The entire application is one file: `index.html`.** All CSS and all JavaScript are
inlined. There is no build step, no bundler, no backend and no other project file
(besides this README). The only external request is the Lucide icon CDN.

> ⚠️ **NXC is virtual game currency.** It has no real-world monetary value and is not
> an investment. All balances, cards and rewards are game state.

---

## 1. Currently completed features

### App shell & navigation
- **Fixed 9:16 portrait app frame** — `--frame-w: min(100vw, max(340px, calc(100dvh * 0.5625)))`
  applied as a `max-width` to the main column, auth wrap, splash, flow overlay, bottom nav
  and modals. On a wider screen the app centres; it never becomes a wide desktop layout.
- **Zero horizontal scrolling anywhere** — verified `OVERWIDE = 0` on every screen,
  including all nine operator tabs, the deposit desk and the referrals page.
- **No document scroll** — `html{overflow:hidden}`, `body{position:fixed;inset:0}`; only
  `.page` scrolls, so the frame behaves like a native app.
- **Horizontal-pan lock**, **zoom blocked**, full-width bottom nav, sidebar + drawer.
- **Splash → welcome → onboarding/intro deck → app** first-run flow.
- **Lucide** open-source icons — **76** icons swapped into the inline SVG sprite.

### Authentication
- **Login is a plain email + password form only.** There are no quick-login buttons and
  no credentials printed on screen.
- **Owner account:** `harisaslam003@gmail.com` / `150906`. Existing browsers are migrated
  to these credentials automatically by `migrateOwner()` on load.
- **Signup accepts a referral code** — a dedicated field with the placeholder **`MEMO`**,
  `maxlength=7`, live uppercase + live validation against real codes, and a *From link*
  badge when the visitor arrived via `?ref=`. An unknown code is now **rejected loudly**
  instead of being silently dropped.

### Referral system (wave-5 rules)
- Reward is **20 % of the referred player's card completion value** (configurable
  `referralPct`), not a flat amount.
- The referred player must have activated a **$5 card or higher** (configurable
  `referralMinUsd`).
- **Both cards must be active** — the referrer's own card *and* the referred player's card.
  The referrals page shows a per-row blocker explaining exactly what is missing.
- **Custom one-time code** — each player can claim their own **5–7 letter** code once
  (`setRefCode`), entered through 7 letter slots with a live availability check. Once
  claimed it locks.
- Because the code also works on the signup form, a referral still counts **even if the
  invite link did not open correctly**.
- Rewards are idempotent (`referral:{userId}`); `qualifyDownline()` re-checks all pending
  referrals whenever anyone activates a card.

### Deposit desk (`#/deposit`)
- Three steps: **choose amount** (chips + custom input, live NXC preview) → **send payment**
  to the operator-published address (with copy button) → **upload the payment screenshot**.
- **Cloudinary unsigned upload** with a **real upload progress bar** driven by
  `XMLHttpRequest.upload.onprogress` (`fetch()` cannot report upload progress), a 120 s
  timeout, and client-side downscale to ≤1280 px / 8 MB.
- **Automatic fallback:** if Cloudinary is not configured, a compressed copy is stored in
  the browser so the operator inbox still works.
- Submitting creates a `PENDING` deposit, notifies the player, and **pings every operator**.
  Max 3 pending deposits per player.
- Reachable from the sidebar (**Deposit**), the Wallet quick actions and the Buy NXC screen.

### Withdrawals — operator-verified, never automatic
- `processTickets()` **no longer pays anything.** It only flags a ticket as review-overdue.
  A withdrawal becomes `PAID` **only** when the operator marks it paid.
- Operator actions per ticket: **Processing** · **Mark paid** (with TX hash) ·
  **Reject & refund** (returns the held NXC via `SELL_REFUND`, with a reason shown to the
  player).
- The player's sell page shows the review window, TX hash and rejection reason.

### Operator console (`#/admin`, labelled **Operator**)
Nine tabs, built as an operations console — **not** a normal-user layout:

| Tab | What the operator can do |
|---|---|
| **Overview** | "Needs your attention" tiles with live pending counts, economy stat grid, jump tiles |
| **Inbox** | Verify deposits: view the screenshot, **edit the NXC amount to credit**, approve or reject with a reason |
| **Payouts** | Withdrawal tickets: mark processing, mark paid with TX hash, reject & refund |
| **Players** | Search, create, edit (name/email/code/password/role/status), **adjust balance ±** with live before/after, grant or remove a card, suspend, delete |
| **Levels** | Full card-level CRUD — USD, NXC cost, completion, collection bonus, rarity, perk, **skin picker**, live profit + "referral pays" preview; disable/delete (blocked while owned); restore defaults |
| **Offers** | Create / edit / expire offers that drive the player ticker and popup |
| **Settings** | **Deposit address** (BEP20-validated), network label, coin, player note, NXC per USD, welcome grant, sell fee %, minimum sell, withdrawal window, referral %, minimum card tier, card verification window (min/max minutes) |
| **Services** | Live Firebase / Supabase / Cloudinary health checks **plus step-by-step setup guides** |
| **Audit** | Trail of every operator action |

**Nothing is hard-coded any more.** The deposit address, verification window, sell fee,
minimum sell and withdrawal window all read live from `NX.config`, so changing them in
Settings immediately changes the card purchase modal, the sell page and every summary.
Operator-created card levels also resolve their own bonus/rarity/perk, so a new level
never shows a 0 NXC collection reward.

### Services tab — setup guides
- **How to connect Supabase** — 7 ordered steps: create the project → copy the Project URL
  and **anon** key (never `service_role`) → create the tables → **enable Row Level Security
  with real policies** → enable Auth and set the Site/Redirect URLs → whitelist the domain →
  wire it in through the CDN client, replacing one `NX` function at a time. Ends with the
  honest limit: balance crediting, deposit approval and payouts must run in an **Edge
  Function**, not the browser.
- **How to connect Cloudinary** — 5 steps: create the account → create an **unsigned**
  upload preset → lock it down (folder, allowed formats, max size) → how the deposit screen
  posts to it with XHR progress → what happens when it is not configured.
- **Live health checks** with four verdicts: **Connected** (2xx) · **Responding** (401/403 —
  the service is definitely live, your rules refused the anonymous request) ·
  **Not working** (404 / CORS / timeout / bad key) · **Not set up**, each with latency in ms.

---

## 2. Functional entry URIs

Single page, hash router. Open `index.html` and append any route.

| Route | Auth | Description |
|---|---|---|
| `#/` | — | Splash → welcome → onboarding flow |
| `#/login` | — | Log in (plain email + password form) |
| `#/signup` | — | Create account. Accepts `?ref=CODE`, and a manual code field |
| `#/forgot` | — | Password reset placeholder |
| `#/welcome`, `#/onboarding`, `#/intro` | — | Re-viewable flow screens |
| `#/dashboard` | player | Balance, active cards, accrual, notifications |
| `#/cards` | player | Card levels and purchase entry |
| `#/collection` | player | Collection gallery, rewards, pending orders, order history |
| `#/wallet` | player | Balance, quick actions, ledger summary |
| `#/deposit` | player | **Deposit desk** — amount, address, screenshot upload + progress |
| `#/buy` | player | Coin packages (routes into the deposit desk) |
| `#/sell` | player | Create a withdrawal ticket, ticket history |
| `#/referrals` | player | Claim your code, referral link, unlock checklist, referral table |
| `#/offers` | player | Active operator offers |
| `#/transactions` | player | Full transaction ledger |
| `#/notifications` | player | Notification feed |
| `#/profile` | player | Account details, session controls |
| `#/admin` | admin | **Operator console** (tab state is in-memory) |

**Owner login:** `harisaslam003@gmail.com` / `150906`

### Standalone utility page

| Path | Auth | Description |
|---|---|---|
| `downloads.html` | — | **Download Center** — lists every project file with its live size, downloads any single file, all files one-by-one, or the whole project as a single ZIP (built in-browser with JSZip). Useful for exporting the project to AI Drive or a local disk. |

---

## 3. Data models & storage

**No server.** All app state is client-side.

### `localStorage['nexaura_state_v1']`
```
users[]         id, email, name, role, status, balance, referralCode, refCodeLocked,
                refCodeSetAt, totalSpentOnCards, totalEarned, collected[]
cards[]         id, userId, denomination, purchaseCost, completionValue,
                startTime, endTime, status, earned, claimed, paidVia
orders[]        id, userId, denomination, usd, cost, address, network, coin,
                shot(dataURL), status(VERIFYING|VERIFIED|CANCELLED),
                createdAt, verifyAt, verifyWindowMs
deposits[]      id, userId, usd, nxc, address, network, coin, shotUrl, shotPublicId,
                txid, note, status(PENDING|APPROVED|REJECTED), createdAt,
                reviewedAt, reviewedBy, creditedNxc, reason
withdrawals[]   id, userId, nxc, fee, feePct, netNxc, usd, address, network,
                status(PENDING|PROCESSING|PAID|REJECTED|CANCELLED),
                createdAt, etaAt, overdue, paidAt, rejectedAt, txid, reason, reviewedBy
transactions[]  id, userId, type, amount, balanceAfter, description, createdAt
referrals[]     id, referrerId, referredUserId, code, qualified, rewardGranted, rewardedAt
offers[]        id, title, body, kind, startsAt, endsAt, active
audit[]         id, actorId, action, target, detail, createdAt
notifications[]
config          depositAddress, depositNetwork, depositCoin, depositNote,
                usdToNxc, welcomeBonus, sellFeePct, sellMin, withdrawHours,
                referralPct, referralMinUsd, verifyMinMin, verifyMaxMin,
                autoVerify, disabled[], cardDefs[]
idem            idempotency keys for the ledger
session         current user id
```

Key invariants:
- **Idempotent ledger** — `NX.ledger(userId, type, amount, {idemKey})` refuses duplicates
  and always records `balanceAfter`.
- **Decimal-safe accrual** — `earned = completionValue × elapsed / (30 days)`.
- **Referral reward** — one reward per referred user, keyed `referral:{userId}`.
- **Collection reward** — one claim per level, keyed `collect:{userId}:{cardId}`.
- **Deposit credit** — keyed `deposit:{id}`; **withdrawal refund** keyed `sellrefund:{id}`.
- **Card definitions** are validated (`completion > cost`) and a level cannot be deleted
  while a player owns it.

### `localStorage['nexaura_integrations_v1']`
```
backend        'firebase' | 'supabase'
firebase       projectId, apiKey, databaseURL, authDomain, storageBucket
supabase       url, anonKey
cloudinary     cloudName, uploadPreset
results        last health-check results per service
checkedAt      timestamp
```

---

## 4. Not yet implemented

- **Real backend.** Firebase/Supabase are health-checked and documented, not yet wired as
  the data source. Everything lives in `localStorage`, so state is per-browser and a player
  can edit it with dev tools.
- **Real payment verification.** A browser cannot confirm an on-chain BEP20 transfer. The
  operator inbox is a genuine human review queue, but the deposit itself is verified by eye
  from the screenshot, not on-chain.
- **Server-side authority.** The operator console runs in the browser, so its authority is
  only as real as the browser it runs in. Balance crediting, deposit approval and payouts
  must move to a server/Edge Function before real money is involved.
- **Secure authentication.** Login is a client-side credential comparison — it is *not*
  security and must not be presented as such.
- **Custom artwork.** No generated card art, logos or illustrations. Image generation is
  blocked (credits exhausted) and **no placeholder stand-ins were fabricated**; the UI uses
  gradients, typography and Lucide icons only.
- Push notifications, email, KYC, multi-language UI.

---

## 5. Recommended next steps

1. **Wire Supabase** following the in-app guide: tables mirroring the models above, RLS
   policies (`auth.uid() = user_id`), and Edge Functions for the ledger, deposit approval,
   withdrawal payout, referral and collection rewards so idempotency and authority are
   enforced server-side.
2. **Move every money-touching operation server-side.** Right now `approveDeposit`,
   `adminAdjustBalance` and `approveWithdrawal` run in the operator's browser.
3. **Verify BEP20 payments** with a BscScan/RPC watcher on the deposit address, matching
   amount + timestamp, and auto-populate the operator inbox with an on-chain match.
4. **Point Cloudinary at a locked-down folder** and store only the `secure_url` plus
   `public_id`, so screenshots do not bloat `localStorage`.
5. **Replace the client-side login** with Supabase Auth (email + OTP).
6. **Commission the artwork** — card faces by rarity, brand mark, splash art.
7. Add rate limiting and export/backup for the audit trail.

---

## 6. Public URLs

- **Production:** not deployed yet. Publish from the **Publish tab**, or ask for a
  Hosted Deploy.
- **API endpoints:** none. The app has no backend of its own. Outbound requests are only
  the Cloudinary upload, the health checks the operator configures (Firebase / Supabase /
  Cloudinary) and the Lucide icon CDN.

---

## 7. Project files

```
index.html                    THE WHOLE APP — HTML + all CSS + all JS + the
                              Supabase adapter and bridge, everything inlined
supabase/nexaura-schema.sql   Supabase schema, RLS policies and money functions
netlify.toml                  Netlify redirects + security headers
.gitignore                    keeps probe files and any secret out of the repo
README.md                     this document
SETUP.md                      step-by-step backend setup (Roman Urdu)
GITHUB.md                     upload instructions (Roman Urdu)
downloads.html                Download Center page (export all project files)
js/downloads.js               Download Center logic (fetch + JSZip bundling)
```

`downloads.html` + `js/downloads.js` are **not part of the app** — they are a
standalone export utility. Deleting them does not affect `index.html` in any way.

**Deployment is one file.** The Supabase adapter and bridge were originally
separate files under `js/`, but that created a silent failure mode: uploading
`index.html` without `js/` dropped the app back to `localStorage` with no error
at all. They are now inlined, so `index.html` alone is a complete, working
deployment. Verify after upload: the console must print three `[nexaura] …` lines.

Trade-off: `index.html` is ~430 KB (~90 KB gzipped), and `netlify.toml` sets
`Cache-Control: must-revalidate` on it so players always get the newest build.

---

## 8. Backend migration status (in progress)

| Piece | State |
|---|---|
| Supabase project | ✅ created — `https://fgvyhecwxjqevpprgnra.supabase.co` |
| anon key wired into `window.NEXAURA_BACKEND` | ✅ done (public key, safe in source **because RLS is on**) |
| `supabase/nexaura-schema.sql` | ✅ written — **must be pasted into the SQL Editor by the owner** |
| ↳ section 5b: `REVOKE` all functions, grant back only client-callable ones | ✅ critical — without it a player could call `nx_ledger` and mint NXC |
| Email auth provider | ⏳ owner action (SETUP.md step 2) |
| Site / Redirect URLs | ⏳ owner action (SETUP.md step 3) |
| Cloudinary cloud name + unsigned preset | ✅ `dgrdcp1uw` / `nexaura_deposits` |
| First admin promotion | ⏳ owner action (SETUP.md step 5) |
| SQL run in the SQL Editor | ✅ done by owner — no errors |
| Client code moved from `localStorage` to Supabase | ✅ **done** — inlined in `index.html` |
| Live database verified from the browser | ✅ 6 levels + config read; anon writes blocked |

### Verified against the live database

A probe run from the browser against the real project returned:

```
LEVELS: 6 rows  (C5 … C500, costs and completions correct)
CONFIG: refPct=20 minUsd=5 welcome=2000
ANON READ profiles:          BLOCKED — permission denied for table profiles
ANON rpc nx_ledger:          BLOCKED — permission denied for function nx_ledger
ANON rpc nx_update_config:   BLOCKED — permission denied for function nx_update_config
ANON rpc nx_check_ref_code:  ok (public by design, returns only a display name)
```

`nx_ledger` being blocked is the important line: without section 5b of the SQL a
visitor could have minted themselves unlimited NXC with one call.

### How the adapter works

The UI reads state synchronously (`NX.me().balance`, `NX.state.cards`), so rather
than rewriting ~300 call sites the backend is attached as an adapter:

- **adapter** (`NXDB`) — one in-memory mirror of the player's server data.
  `NXDB.pull()` fills `NX.state` from Supabase; RLS decides what comes back, so the
  *same* query returns one player's rows or everything for an operator.
- **bridge** — repoints every `NX` write function at `supabase.rpc('nx_…')`, then
  re-pulls and re-renders. It is the last script in the document so it overrides
  every earlier local implementation.

Reads stay instant; every write is a server call. The browser is never the source
of truth for a balance.

### Fixed: operator tabs appeared to vanish

Reported symptom: the operator tab strip (Inbox, Settings, …) was visible right
after login but "disappeared" as soon as a section was opened.

Root cause: the document does not scroll — `body` is `position:fixed` and `.page`
is the only scroller. `render()` called `window.scrollTo(0,0)`, which is a no-op
in that layout. So tapping a *Jump to* tile near the bottom of Overview rendered
the new section correctly but **left the scroll position where it was**, below the
tab strip. The section was open; the operator was simply parked underneath it.

Two fixes:
1. `root.scrollTop = 0` on every render (and `#view-auth` for auth screens), so
   the real scroller returns to the top.
2. The tab strip is now `position:sticky` (`.op-tabbar`), so all nine tabs stay
   pinned however far down the panel is scrolled, with the active tab highlighted.

Verified by scrolling the Settings panel 700 px inside its scroller and
confirming all nine chips were still pinned at the top.

### Operations that are deliberately refused now

These edited `localStorage` directly and have no safe browser equivalent. They now
throw an explanatory error instead of pretending to work:

| Was | Why it is refused |
|---|---|
| `adminCreateUser` | Creating someone else's account needs the `service_role` key |
| `adminDeleteUser` | Same — suspend the player instead, which blocks login instantly |
| `adminGrantCard` / `adminRemoveCard` | Would break the ledger; adjust the balance with a reason |
| `buyCoins` | Coins now arrive only through the operator-verified deposit desk |
| `cancelTicket` | A player cannot self-refund; the operator rejects and refunds |
| `shiftClock` / `resetAll` | Demo-only clock tricks; meaningless against a real database |

### Why the anon key is safe in the page

The anon key is designed to be public. It grants nothing on its own: every table
has RLS enabled, and the policies only ever match `auth.uid()`. Balances have **no**
client-writable policy at all — they move only inside `SECURITY DEFINER` functions
that re-check `nx_is_admin()`. So anyone can open the operator page; the database
will still refuse their writes.

The keys that must **never** appear here: `service_role`, the database password,
the JWT secret, and the Cloudinary API secret.
