# Upload karne ka tareeqa

## ⚠️ ZIP kyun nahi de saka

Main sirf **text files** likh sakta hoon — `.zip` binary hota hai, wo main bana
nahi sakta. Is liye main ne is se **behtar** kaam kar diya:

**Dono JS files wapas `index.html` ke andar daal di hain.**

Yani ab aapko **sirf EK file** upload karni hai. `js/` folder khatam. ZIP ki
zaroorat hi nahi rahi.

---

## 1. Ab file structure yeh hai

```
nexaura/
│
├── index.html                    ← 👈 SIRF YEH UPLOAD KARNI HAI (app + Supabase, sab andar)
│
├── netlify.toml                  ← optional (redirects + security headers)
├── .gitignore                    ← optional
├── README.md                     ← optional (documentation)
├── SETUP.md                      ← optional (Supabase steps)
├── GITHUB.md                     ← optional (yeh file)
│
└── supabase/
    └── nexaura-schema.sql        ← optional (aap ne already SQL Editor mein chala diya)
```

**Website chalane ke liye zaroori:** sirf `index.html`
**Behtar:** `index.html` + `netlify.toml`
**Baaki files:** sirf documentation aur record ke liye — website unke bagair bhi
poori chalti hai.

---

## 2. Netlify par upload (sabse asaan tareeqa)

### Drag & drop

1. [app.netlify.com](https://app.netlify.com) → sign in
2. Apni site **newnexaura** kholein
3. **Deploys** tab par jayein
4. Neeche **"Drag and drop your site output folder here"** wala box milega
5. Us box mein **`index.html`** aur **`netlify.toml`** drop kar dein
6. 10–20 second → live

Bas. Koi ZIP nahi, koi folder nahi.

> Agar Netlify folder maange (sirf file na le), to apne computer par ek nayi
> folder banayein (naam `nexaura`), us mein dono files daalein, aur **poori
> folder** drag karein.

---

## 3. GitHub par upload

### Tareeqa A — website se (asaan)

1. [github.com](https://github.com) → sign in → upar right **+** → **New repository**
2. Name: `nexaura` → **Private** chunein → **Create repository**
3. **uploading an existing file** link par click karein
4. **`index.html`** (aur jo baaki files chahein) drag karein
5. **Commit changes**

Ab koi `js/` folder banane ki zaroorat nahi — sab kuch `index.html` ke andar hai.

### Tareeqa B — Git command line

```bash
cd nexaura

git init
git add .
git commit -m "NEXAURA — Supabase backend inlined, sticky operator tabs"
git branch -M main

git remote add origin https://github.com/AAPKA_USERNAME/nexaura.git
git push -u origin main
```

Aage tabdeeli par:
```bash
git add .
git commit -m "kya badla, ek line"
git push
```

---

## 4. Netlify ko GitHub se jorein (recommended)

Ek baar jor dein, phir har `git push` par site khud update hogi:

1. Netlify → site **newnexaura** → **Site configuration**
2. **Build & deploy → Continuous deployment → Link repository**
3. GitHub → `nexaura` repo chunein
4. Settings:

| Field | Value |
|---|---|
| Branch to deploy | `main` |
| Build command | *(khaali chhor dein)* |
| Publish directory | `.` (ek dot) |

5. **Deploy site**

Build command khaali kyun? Kyunki koi build step nahi — plain HTML/CSS/JS hai.

---

## 5. Upload ke baad ZAROOR check karein

Site kholein → **F12** dabayein → **Console** tab:

| Console mein kya dikhe | Matlab |
|---|---|
| `[nexaura] Supabase adapter loaded — project https://fgvyhecwxjqevpprgnra.supabase.co` | ✅ |
| `[nexaura] Supabase bridge active` | ✅ |
| `[nexaura] server data loaded; session = ...` | ✅ sab theek |
| `Supabase JS library did not load` | CDN block hua — adblock/internet check karein |
| Koi `[nexaura]` line nahi | ❌ purani file upload hui hai — dobara karein |

Teen lines aa gayin = backend live hai.

---

## 6. Repo mein kya rakhna theek hai

### ✅ Yeh public values hain, rakhna theek hai

| Value | Kyun theek |
|---|---|
| Supabase **anon key** | Public hi hai. RLS policies ke bagair akele bekaar |
| Cloudinary **cloud name** `dgrdcp1uw` | Public — har image URL mein nazar aata hai |
| Cloudinary **unsigned preset** `nexaura_deposits` | Unsigned ka matlab hi browser use kare |

### ❌ Yeh KABHI kisi file mein na aayein

- Supabase **`service_role`** key
- Supabase **database password** / JWT secret
- Cloudinary **API Secret**
- Wallet ki **private key / seed phrase**

`.gitignore` mein `.env` block kar di hai, lekin **asli hifazat yeh hai ke yeh
cheezein kisi file mein likhi hi na jayein.**

> Repo private rakhein to behtar — lekin yaad rahe, website ka source code har
> visitor parh sakta hai. Repo private hone se `index.html` ki koi cheez chhupti
> nahi. Isi liye secret waise bhi client mein kabhi nahi aa sakta.

---

## 7. Ek file hone ka faida aur nuqsan

**Faida:** upload asaan, `js/` bhoolne ka masla khatam, ek hi file sambhalni hai.

**Nuqsan:** `index.html` ab ~430 KB hai. Yeh Netlify par bilkul theek hai (gzip
ke baad ~90 KB), lekin har visit par poori file dobara load hoti hai — is liye
`netlify.toml` mein `Cache-Control: must-revalidate` rakha hai taake players ko
hamesha naya build mile.
