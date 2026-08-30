# NEXAURA — Supabase Setup (Step by Step)

Web app hi rahegi. Yeh guide sirf **Supabase** ke baare mein hai — kya karna hai,
SQL Editor mein kaise karna hai, aur kaise check karna hai ke sahi hua.

Aapki details jo already `index.html` mein daal di gayi hain:

| Cheez | Value |
|---|---|
| Supabase URL | `https://fgvyhecwxjqevpprgnra.supabase.co` |
| anon key | ✅ daal di (public key hai, page source mein hona normal hai) |
| Website | `https://newnexaura.netlify.app/` |
| Cloudinary cloud name | ✅ `dgrdcp1uw` |
| Cloudinary preset | ✅ `nexaura_deposits` |

---

# 🅐 STEP 1 — SQL chalayein (5 minute)

Yeh sabse ahem step hai. Ghor se parhein.

### 1.1 — SQL Editor kholein

1. Browser mein [supabase.com](https://supabase.com) → **Sign in**
2. Apna project **`fgvyhecwxjqevpprgnra`** par click karein
3. Left side ke menu mein neeche dekhein → **SQL Editor** icon (`< >` jaisa nishan)
4. Us par click karein
5. Upar **+ New query** button par click karein (ya *"New SQL snippet"*)
6. Ek khaali kaala/safed box khul jayega — yahan SQL likha jata hai

### 1.2 — File copy karein

1. Is project mein file kholein: **`supabase/nexaura-schema.sql`**
2. **Poori file** select karein — `Ctrl + A` (Mac par `Cmd + A`)
3. Copy — `Ctrl + C`

> ⚠️ **Poori file** chahiye — pehli line `create extension...` se aakhri line tak.
> Aadhi file chalane se error aayega.

### 1.3 — Paste aur Run

1. Supabase ke khaali box mein click karein
2. Paste — `Ctrl + V`
3. Neeche daayein **RUN** ka green button hoga → us par click karein
   *(ya keyboard se `Ctrl + Enter`)*
4. **10–20 second** intezaar karein

### 1.4 — Kaise pata chalay ke sahi hua?

Neeche result box mein yeh aana chahiye:

```
Success. No rows returned
```

✅ Yeh aa gaya = **kaam ho gaya.**

❌ Agar **red error** aaye to poora error message mujhay bhej dein, main theek kar
doonga. Ghabrayein nahi — kuch kharab nahi hota, aap dobara chala sakte hain.

> Yeh SQL **dobara chalana bilkul safe hai.** Sab kuch `IF NOT EXISTS` /
> `CREATE OR REPLACE` hai, is liye purana data delete nahi hota.

### 1.5 — Verify karein (optional lekin behtar)

Naya query kholein, yeh paste karke Run karein:

```sql
select table_name from information_schema.tables
 where table_schema = 'public' order by table_name;
```

**11 tables** aani chahiye: `audit, card_levels, cards, config, deposits, notifications,
offers, profiles, referrals, txns, withdrawals`

Aur yeh check karein ke 6 card levels seed hue:

```sql
select id, usd, cost, completion, bonus from public.card_levels order by sort;
```

$5 se $500 tak **6 rows** aani chahiye.

### 1.6 — 🔴 Sabse ahem verify (yeh zaroor karein)

Yeh check karta hai ke koi player khud ko coins **nahi** de sakta. Naya query
kholein, paste karein, Run karein:

```sql
select p.proname
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('nx_ledger','nx_notify','nx_audit','nx_qualify_referral')
   and has_function_privilege('authenticated', p.oid, 'execute');
```

✅ **Zero rows** aana chahiye — `No rows returned`. Yeh matlab money functions
locked hain.

❌ Agar koi row aaye = SQL ka section 5b nahi chala. Poori file dobara chalayein
aur mujhay batayein.

> **Yeh kyun ahem hai?** Postgres by default har function ko *sab* ke liye
> callable bana deta hai. Us ke bina koi player browser console se seedha
> `nx_ledger` call kar ke khud ko lakhon NXC de sakta tha. SQL ka section 5b
> yeh raasta band karta hai.

Aur RLS check:

```sql
select relname as table_name, relrowsecurity as rls_enabled
  from pg_class where relnamespace = 'public'::regnamespace
   and relkind = 'r' order by relname;
```

Saari 11 tables mein `rls_enabled = true` hona chahiye.

---

# 🅑 STEP 2 — Email login on karein (1 minute)

1. Left menu → **Authentication**
2. Upar tabs mein → **Providers** (ya *Sign In / Providers*)
3. List mein **Email** dhoondein → us par click karein
4. **Enable Email provider** toggle **ON** karein
5. Neeche **"Confirm email"** ka toggle **OFF** karein
6. **Save** dabayein

> **Confirm email OFF kyun?** Testing ke dauran har naye account ke liye inbox
> khol kar link click karna parega — bohot waqt zaya hoga.
>
> ⚠️ **Launch se pehle isay ON kar dena.** Warna koi bhi jhoothi email
> (`abc@abc.com`) se account bana sakta hai.

---

# 🅒 STEP 3 — Website ka URL batayein (1 minute)

1. Left menu → **Authentication**
2. → **URL Configuration**
3. Do fields bharein:

| Field | Kya likhein |
|---|---|
| **Site URL** | `https://newnexaura.netlify.app` |
| **Redirect URLs** | `https://newnexaura.netlify.app/**` |

4. **Save**

> Yeh step chhoot jaye to login ke baad user wapas login screen par phenk diya
> jayega. `/**` ke do stars zaroori hain.

---

# 🅓 STEP 4 — Cloudinary (5 minute)

1. [cloudinary.com](https://cloudinary.com) → free sign up
2. Dashboard par **Cloud name** likha hoga (jaise `dxy12ab3c`) → note karein
3. **Settings** (gear icon) → **Upload** → neeche scroll → **Upload presets**
4. **+ Add upload preset** par click karein
5. Yeh settings karein:

| Setting | Value |
|---|---|
| **Signing mode** | **Unsigned** ← yeh sabse zaroori |
| Preset name | `nexaura_deposits` |
| Folder | `nexaura/deposits` |
| Allowed formats | `jpg, png, webp` |
| Max file size | `8` MB (ya `8000000` bytes) |
| Unique filename | ON |

6. **Save**
7. **Mujhay do naam bhej dein**: cloud name + preset name

> **Folder / formats / size limits zaroori hain.** Unsigned preset ko koi bhi
> istemal kar sakta hai jo aapka page kholay — yeh limits hi aapka bachao hain.
> Bina limits ke koi aapke account mein hazaron files bhar sakta hai.

---

# 🅔 STEP 5 — Khud ko admin banayein

Yeh **Step 1, 2, 3 ke baad** karna hai.

### 5.1 — Pehle account banayein

1. App kholein: `https://newnexaura.netlify.app`
2. **Sign up** karein apni email se: `harisaslam003@gmail.com`
3. Password wahi rakhein jo yaad rahe

### 5.2 — Phir SQL se admin banayein

Supabase → SQL Editor → New query → yeh **ek line** paste karke Run:

```sql
update public.profiles set role = 'admin' where email = 'harisaslam003@gmail.com';
```

Neeche `Success. 1 row affected` aana chahiye.

❌ Agar `0 rows` aaye = signup nahi hua tha. Pehle 5.1 karein.

### 5.3 — Check karein

```sql
select email, name, role, balance, referral_code from public.profiles;
```

Aapki row mein `role = admin` hona chahiye.

### 5.4 — Asli deposit address set karein

`0xAAPKA_ASLI_ADDRESS` ki jagah apna **asli BEP20 USDT address** likhein:

```sql
select public.nx_update_config('{"depositAddress":"0xAAPKA_ASLI_ADDRESS"}'::jsonb);
```

> **Yaad rahe:** yeh sirf **public address** hai. Private key ya seed phrase
> kabhi kahin na likhein — na SQL mein, na mujhay.

Check:
```sql
select data ->> 'depositAddress' as address from public.config;
```

---

# 🔒 Security kaise kaam karti hai

Aapka sawaal tha ke Netlify par admin panel safe hai ya nahi. Jawab: **haan** —
kyunki security **database** mein hai, page chhupane mein nahi.

| Kya | Kaise |
|---|---|
| Balance badalna | Client ke paas **koi tareeqa nahi**. Balance sirf functions ke andar hilta hai |
| Admin kaun hai | Database mein `profiles.role` se decide hota hai — browser par bharosa nahi |
| Koi operator page khol le? | Khol sakta hai, lekin har admin function pehle `nx_is_admin()` check karta hai → **database uske writes refuse kar dega** |
| Double-click se do payment? | Nahi — har transaction ek unique `idem_key` likhta hai |
| Withdrawal auto-paid? | **Kabhi nahi.** Sirf `nx_pay_withdrawal` se, aur wo admin-only hai |
| Player dusre ka data dekh sakta? | Nahi — RLS har table par on hai, policies sirf `auth.uid()` match karti hain |
| Player khud ko coins de sakta? | Nahi — SQL ka **section 5b** har internal function se permission cheen leta hai |

**Section 5b sabse ahem hai.** Postgres by default har function ko *sab* ke liye
callable bana deta hai. Us ke bina koi player seedha `nx_ledger` call kar ke khud
ko unlimited NXC de sakta tha. SQL us ko band karta hai aur sirf wo functions
khologta hai jo browser ko call karne ki ijazat hai.

---

# ❌ Mujhay yeh KABHI na bhejein

- Supabase **`service_role`** key
- Supabase **database password**
- Supabase **JWT secret**
- Cloudinary **API Secret**
- Wallet ki **private key / seed phrase**

Yeh cheezein page source mein aa jayein to jo bhi page kholay, aapka poora
database aur paisa uska ho jayega. **anon key theek hai** — wo public hi hai.

---

# Jo technically mumkin nahi

| Cheez | Kyun nahi |
|---|---|
| Blockchain payment **automatic** verify | Na browser, na Postgres chain parh sakta. Admin inbox (insaan screenshot dekhe) hi tareeqa hai. Automatic ke liye alag server chahiye jo 24/7 BscScan watch kare |
| Asli USDT **automatic** bhejna | Private key kabhi app mein nahi aa sakti. Withdrawal aap manually bhejenge, app sirf ticket track karegi |
| Images generate | Credits khatam, aur main jhoothe placeholder nahi banaunga |

---

# ✅ Checklist

- [ ] **Step 1** — SQL chalaya, `Success. No rows returned` aaya, 11 tables verify kiye
- [ ] **Step 2** — Email provider ON, Confirm email OFF
- [ ] **Step 3** — Site URL + Redirect URLs save kiye
- [ ] **Step 4** — Cloudinary unsigned preset banaya, do naam mujhay bheje
- [ ] **Step 5** — signup kiya, `role = 'admin'` chalaya, deposit address set kiya

---

# ✅ STEP 6 — Client migration (MAIN ne kar diya)

Aapka SQL chalne ke baad main ne app ko Supabase par shift kar diya:

- `js/nexaura-supabase.js` — server se data laata hai (`NXDB.pull()`)
- `js/nexaura-bridge.js` — har paisa-wala action `supabase.rpc('nx_...')` par bhejta hai
- login / signup → **Supabase Auth**
- deposit / withdrawal / card purchase / referral → **Postgres functions**

Live database se test kar liya, yeh result aaya:

```
LEVELS: 6 rows (C5 se C500, sab sahi)
CONFIG: refPct=20 minUsd=5 welcome=2000
ANON profiles read:        BLOCKED ✅
ANON rpc nx_ledger:        BLOCKED ✅  ← sabse ahem
ANON rpc nx_update_config: BLOCKED ✅
```

`nx_ledger` blocked hona sabse ahem hai — is ke bina koi bhi khud ko unlimited
NXC de sakta tha.

---

# ⚠️ Ab aapko yeh 3 kaam karne hain

### 1. Netlify par nayi `index.html` upload karein

**Sirf ek file** — Supabase ka poora code us ke andar hai:

```
index.html        ← 👈 bas yeh
netlify.toml      ← (optional, behtar hai)
```

Pehle main ne `js/` folder banaya tha, lekin us mein ek khatarnaak masla tha:
agar `js/` chhoot jaye to app **chup-chaap** localStorage mode mein chali jati
thi — koi error nahi, bas data share nahi hota. Is liye sab kuch `index.html`
mein inline kar diya. Ab wo masla mumkin hi nahi.

Upload ke baad **F12 → Console** check karein, yeh 3 lines aani chahiye:
```
[nexaura] Supabase adapter loaded — project https://fgvyhecwxjqevpprgnra.supabase.co
[nexaura] Supabase bridge active
[nexaura] server data loaded; session = ...
```

### 2. Signup karke admin banein (STEP 5)

Ab jab backend live hai, `https://newnexaura.netlify.app` par signup karein,
phir SQL Editor mein:

```sql
update public.profiles set role = 'admin' where email = 'harisaslam003@gmail.com';
```

### 3. Deposit address set karein

Abhi khaali hai (probe ne `addr="(empty)"` dikhaya). Do tareeqay:

- **App se:** admin login → Operator → Settings → BEP20 address → Save
- **Ya SQL se:**
```sql
select public.nx_update_config('{"depositAddress":"0xAAPKA_ASLI_ADDRESS"}'::jsonb);
```

Address khaali rahe to card purchase modal saaf error dikhata hai (paisa galat
jagah nahi jata).

---

# Kuch operator features jaan bujh kar band kiye

Yeh pehle `localStorage` seedha edit karte the. Server par yeh safe tareeqay se
mumkin nahi, is liye ab saaf error dete hain (jhooth nahi bolte):

| Feature | Kyun band |
|---|---|
| Admin naya account banaye | `service_role` key chahiye, jo browser mein nahi aa sakti |
| Admin account delete kare | Wahi wajah — **suspend** karein, login foran block ho jata hai |
| Admin card grant/remove kare | Ledger toot jata. Balance adjust karein reason ke saath |
| Buy NXC se instant coins | Ab sirf deposit desk se, operator verify karta hai |
| Player khud ticket cancel kare | Player khud refund nahi le sakta; operator reject karke refund deta hai |

---

# Baaki kaam

- [x] **Cloudinary** — `dgrdcp1uw` / `nexaura_deposits` daal diye ✅
- [ ] `js/` folder ke saath naye files upload karein (dekhein `GITHUB.md`)
- [ ] Aap signup + admin promotion karein
- [ ] Deposit address set karein
- [ ] 2 phones se end-to-end test: ek se deposit, dusre (admin) se verify

---

# 🐛 Fix kiya gaya bug (aapki shikayat)

**Shikayat:** *"settings ka option login karte waqt dikhta hai, lekin koi section
kholo to gayab ho jata hai"*

**Asli wajah:** app mein document scroll nahi karta (`body` fixed hai) — asli
scroller `.page` element hai. `render()` sirf `window.scrollTo(0,0)` chala raha
tha, jo is app mein kuch nahi karta. Yani jab aap Overview mein neeche scroll
kar ke koi tile dabate the, naya section render ho jata tha **lekin scroll
position wahin neeche reh jati thi** — is liye upar wale tabs (Inbox, Settings
waghera) nazar nahi aate the. Section khula hua tha, bas aap us se neeche khare
the.

**Do fix kiye:**

1. `root.scrollTop = 0` — har render par asli scroller upar aa jata hai
2. Tab strip ab **sticky** hai (`.op-tabbar`) — chahe aap kitna hi neeche scroll
   karein, 9 tabs hamesha upar pinned nazar aayenge, aur active tab gradient
   se highlight hota hai

Test kar liya: Settings panel ko 700px neeche scroll karne ke baad bhi saare 9
tabs pinned nazar aa rahe the.
