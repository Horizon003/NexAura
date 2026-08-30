-- ============================================================================
-- NEXAURA — Supabase schema, Row Level Security and money functions
-- ============================================================================
-- HOW TO RUN
--   Supabase dashboard -> SQL Editor -> New query -> paste this ENTIRE file
--   -> Run. It is safe to run more than once (everything is IF NOT EXISTS /
--   CREATE OR REPLACE).
--
-- DESIGN RULES (why it is built this way)
--   1. Every table has RLS enabled. The anon key is public, so RLS is the
--      ONLY thing stopping a visitor from reading other players' data.
--   2. No client may ever UPDATE a balance directly. There is no policy that
--      allows it. Balances move only inside SECURITY DEFINER functions below,
--      which re-check who the caller is with auth.uid() / nx_is_admin().
--   3. Admin authority is decided by profiles.role in the DATABASE, not by
--      the browser. Anyone can open the operator page; the database will
--      still refuse their writes.
--   4. Every balance change writes one txns row with a unique idem_key, so a
--      double-click or a retried request can never pay twice.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- ---------- profiles (one row per auth user) ----------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text not null,
  name           text not null default 'Player',
  role           text not null default 'player' check (role in ('player','admin')),
  status         text not null default 'active' check (status in ('active','suspended')),
  balance        numeric(20,4) not null default 0 check (balance >= 0),
  referral_code  text unique,
  ref_code_locked boolean not null default false,
  referred_by    uuid references public.profiles(id) on delete set null,
  total_earned   numeric(20,4) not null default 0,
  total_spent    numeric(20,4) not null default 0,
  created_at     timestamptz not null default now()
);

-- ---------- config (single row: every operator-editable number) ----------
create table if not exists public.config (
  id   int primary key default 1 check (id = 1),
  data jsonb not null
);

insert into public.config (id, data)
values (1, '{
  "depositAddress": "",
  "depositNetwork": "BEP20 (BNB Smart Chain)",
  "depositCoin": "USDT",
  "depositNote": "Send the exact amount. Wrong-network transfers cannot be recovered.",
  "supportContact": "",
  "usdToNxc": 100,
  "welcomeBonus": 2000,
  "sellFeePct": 2,
  "sellMin": 500,
  "withdrawHours": 24,
  "referralPct": 20,
  "referralMinUsd": 5,
  "maxPendingDeposits": 3
}'::jsonb)
on conflict (id) do nothing;

-- ---------- card_levels (operator creates / edits these) ----------
create table if not exists public.card_levels (
  id         text primary key,
  usd        numeric(12,2) not null check (usd > 0),
  cost       numeric(20,4) not null check (cost > 0),
  completion numeric(20,4) not null,
  bonus      numeric(20,4) not null default 0 check (bonus >= 0),
  rarity     text not null default 'common' check (rarity in ('common','rare','epic','legendary')),
  perk       text not null default '',
  skin       text not null default 'cyan',
  days       int  not null default 30 check (days > 0),
  enabled    boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  constraint card_levels_profitable check (completion > cost)
);

-- ---------- cards (a player's activated card) ----------
create table if not exists public.cards (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles(id) on delete cascade,
  level_id         text not null references public.card_levels(id),
  purchase_cost    numeric(20,4) not null,
  completion_value numeric(20,4) not null,
  bonus            numeric(20,4) not null default 0,
  days             int not null default 30,
  started_at       timestamptz not null default now(),
  ends_at          timestamptz not null,
  status           text not null default 'ACTIVE'
                   check (status in ('ACTIVE','COMPLETED','CLAIMED')),
  claimed_at       timestamptz,
  paid_via         text not null default 'WALLET',
  created_at       timestamptz not null default now()
);
create index if not exists cards_user_idx on public.cards(user_id);

-- ---------- txns (the ledger — append only) ----------
create table if not exists public.txns (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  type          text not null,
  direction     text not null check (direction in ('in','out')),
  amount        numeric(20,4) not null check (amount >= 0),
  balance_after numeric(20,4) not null,
  description   text not null default '',
  reference_id  text,
  idem_key      text not null unique,
  created_at    timestamptz not null default now()
);
create index if not exists txns_user_idx on public.txns(user_id, created_at desc);

-- ---------- deposits (player uploads proof, operator verifies) ----------
create table if not exists public.deposits (
  id             uuid primary key default gen_random_uuid(),
  ref            text not null unique default 'DP' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  user_id        uuid not null references public.profiles(id) on delete cascade,
  usd            numeric(12,2) not null check (usd > 0),
  nxc            numeric(20,4) not null check (nxc > 0),
  address        text,
  network        text,
  coin           text,
  shot_url       text not null,
  shot_public_id text,
  txid           text,
  note           text,
  status         text not null default 'PENDING'
                 check (status in ('PENDING','APPROVED','REJECTED')),
  credited_nxc   numeric(20,4),
  reason         text,
  reviewed_at    timestamptz,
  reviewed_by    uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists deposits_status_idx on public.deposits(status, created_at desc);

-- ---------- withdrawals (operator verifies every payout) ----------
create table if not exists public.withdrawals (
  id          uuid primary key default gen_random_uuid(),
  ref         text not null unique default 'WD' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  nxc         numeric(20,4) not null check (nxc > 0),
  fee         numeric(20,4) not null default 0,
  fee_pct     numeric(8,4) not null default 0,
  net_nxc     numeric(20,4) not null,
  usd         numeric(12,2) not null,
  address     text not null,
  network     text not null default 'BEP20 (BSC)',
  status      text not null default 'PENDING'
              check (status in ('PENDING','PROCESSING','PAID','REJECTED','CANCELLED')),
  txid        text,
  reason      text,
  eta_at      timestamptz,
  paid_at     timestamptz,
  rejected_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists withdrawals_status_idx on public.withdrawals(status, created_at desc);

-- ---------- referrals ----------
create table if not exists public.referrals (
  id             uuid primary key default gen_random_uuid(),
  referrer_id    uuid not null references public.profiles(id) on delete cascade,
  referred_id    uuid not null unique references public.profiles(id) on delete cascade,
  code           text,
  qualified      boolean not null default false,
  reward_granted boolean not null default false,
  reward_amount  numeric(20,4) not null default 0,
  rewarded_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint referrals_no_self check (referrer_id <> referred_id)
);
create index if not exists referrals_referrer_idx on public.referrals(referrer_id);

-- ---------- offers ----------
create table if not exists public.offers (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  body       text not null default '',
  kind       text not null default 'bonus',
  cta        text,
  cta_href   text,
  starts_at  timestamptz not null default now(),
  ends_at    timestamptz,
  active     boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- notifications ----------
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  body       text not null,
  icon       text not null default 'info',
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);

-- ---------- audit (every operator action) ----------
create table if not exists public.audit (
  id         uuid primary key default gen_random_uuid(),
  actor_id   uuid references public.profiles(id) on delete set null,
  action     text not null,
  target     text,
  detail     text,
  created_at timestamptz not null default now()
);
create index if not exists audit_created_idx on public.audit(created_at desc);


-- ============================================================================
-- 2. HELPERS
-- ============================================================================

create or replace function public.nx_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'active'
  );
$$;

create or replace function public.nx_cfg()
returns jsonb language sql stable security definer set search_path = public as $$
  select data from public.config where id = 1;
$$;

create or replace function public.nx_cfg_num(k text, fallback numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select (data ->> k)::numeric from public.config where id = 1), fallback);
$$;

-- random 7-letter code
create or replace function public.nx_random_code()
returns text language plpgsql as $$
declare c text := ''; i int;
begin
  for i in 1..7 loop
    c := c || chr(65 + floor(random() * 26)::int);
  end loop;
  return c;
end; $$;

-- how much a card has accrued right now (decimal-safe, capped at completion)
create or replace function public.nx_card_earned(c public.cards)
returns numeric language sql stable as $$
  select round(least(
    c.completion_value,
    c.completion_value * (extract(epoch from (least(now(), c.ends_at) - c.started_at))
                          / extract(epoch from (c.ends_at - c.started_at)))
  ), 4);
$$;

-- THE LEDGER. Every balance change on the whole platform goes through here.
create or replace function public.nx_ledger(
  p_user uuid, p_type text, p_dir text, p_amount numeric,
  p_desc text, p_ref text, p_idem text
) returns numeric language plpgsql security definer set search_path = public as $$
declare new_bal numeric;
begin
  if p_amount is null or p_amount < 0 then
    raise exception 'Amount must be zero or more.';
  end if;

  -- idempotency: if this key was already used, do nothing and return balance
  if exists (select 1 from public.txns where idem_key = p_idem) then
    select balance into new_bal from public.profiles where id = p_user;
    return new_bal;
  end if;

  -- lock the row so two concurrent requests cannot both spend the same coins
  select balance into new_bal from public.profiles where id = p_user for update;
  if new_bal is null then raise exception 'Player not found.'; end if;

  if p_dir = 'out' then
    if new_bal < p_amount then
      raise exception 'Not enough NXC. Balance is %, needed %.', new_bal, p_amount;
    end if;
    new_bal := new_bal - p_amount;
  else
    new_bal := new_bal + p_amount;
  end if;

  update public.profiles set balance = new_bal where id = p_user;

  insert into public.txns (user_id, type, direction, amount, balance_after, description, reference_id, idem_key)
  values (p_user, p_type, p_dir, p_amount, new_bal, coalesce(p_desc,''), p_ref, p_idem);

  return new_bal;
end; $$;

create or replace function public.nx_notify(p_user uuid, p_body text, p_icon text default 'info')
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, body, icon) values (p_user, p_body, p_icon);
$$;

create or replace function public.nx_audit(p_action text, p_target text, p_detail text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.audit (actor_id, action, target, detail)
  values (auth.uid(), p_action, p_target, p_detail);
$$;


-- ============================================================================
-- 3. NEW USER TRIGGER — profile + welcome grant + referral link
-- ============================================================================
-- The browser calls supabase.auth.signUp({ email, password,
--   options: { data: { name: 'Ali', ref_code: 'MEMO' } } })
-- and this trigger turns that into a profile.

create or replace function public.nx_on_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_name  text := coalesce(nullif(new.raw_user_meta_data ->> 'name',''), split_part(new.email,'@',1));
  v_code  text := upper(trim(coalesce(new.raw_user_meta_data ->> 'ref_code','')));
  v_ref   uuid;
  v_bonus numeric := public.nx_cfg_num('welcomeBonus', 0);
  v_own   text;
begin
  -- unique own code
  loop
    v_own := public.nx_random_code();
    exit when not exists (select 1 from public.profiles where referral_code = v_own);
  end loop;

  -- who referred this player (code is checked, unknown codes are ignored here
  -- because the browser validates the code BEFORE signup and shows an error)
  if v_code <> '' then
    select id into v_ref from public.profiles where referral_code = v_code;
  end if;

  insert into public.profiles (id, email, name, referral_code, referred_by)
  values (new.id, new.email, v_name, v_own, v_ref);

  if v_ref is not null then
    insert into public.referrals (referrer_id, referred_id, code)
    values (v_ref, new.id, v_code)
    on conflict (referred_id) do nothing;
    perform public.nx_notify(v_ref, v_name || ' joined with your referral code.', 'users');
  end if;

  if v_bonus > 0 then
    perform public.nx_ledger(new.id, 'WELCOME_BONUS', 'in', v_bonus,
      'Welcome grant', null, 'welcome:' || new.id::text);
  end if;

  return new;
end; $$;

drop trigger if exists nx_on_new_user on auth.users;
create trigger nx_on_new_user
  after insert on auth.users
  for each row execute function public.nx_on_new_user();


-- ============================================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================================

alter table public.profiles      enable row level security;
alter table public.config        enable row level security;
alter table public.card_levels   enable row level security;
alter table public.cards         enable row level security;
alter table public.txns          enable row level security;
alter table public.deposits      enable row level security;
alter table public.withdrawals   enable row level security;
alter table public.referrals     enable row level security;
alter table public.offers        enable row level security;
alter table public.notifications enable row level security;
alter table public.audit         enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select
  using (id = auth.uid() or public.nx_is_admin()
         or id in (select referred_id from public.referrals where referrer_id = auth.uid()));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
-- NOTE: a player can reach this policy, so the columns they must NOT change
-- are protected by the trigger below.

create or replace function public.nx_guard_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.nx_is_admin() then return new; end if;
  -- a normal player may only change their display name
  new.balance         := old.balance;
  new.role            := old.role;
  new.status          := old.status;
  new.total_earned    := old.total_earned;
  new.total_spent     := old.total_spent;
  new.referral_code   := old.referral_code;
  new.ref_code_locked := old.ref_code_locked;
  new.referred_by     := old.referred_by;
  new.email           := old.email;
  return new;
end; $$;

drop trigger if exists nx_guard_profile on public.profiles;
create trigger nx_guard_profile before update on public.profiles
  for each row execute function public.nx_guard_profile();

-- ---------- config: everyone reads, only admin writes ----------
drop policy if exists config_read on public.config;
create policy config_read on public.config for select using (true);
drop policy if exists config_write on public.config;
create policy config_write on public.config for update
  using (public.nx_is_admin()) with check (public.nx_is_admin());

-- ---------- card levels: everyone reads, only admin writes ----------
drop policy if exists levels_read on public.card_levels;
create policy levels_read on public.card_levels for select using (true);
drop policy if exists levels_write on public.card_levels;
create policy levels_write on public.card_levels for all
  using (public.nx_is_admin()) with check (public.nx_is_admin());

-- ---------- cards / txns / deposits / withdrawals: own rows only ----------
drop policy if exists cards_read on public.cards;
create policy cards_read on public.cards for select
  using (user_id = auth.uid() or public.nx_is_admin());

drop policy if exists txns_read on public.txns;
create policy txns_read on public.txns for select
  using (user_id = auth.uid() or public.nx_is_admin());

drop policy if exists deposits_read on public.deposits;
create policy deposits_read on public.deposits for select
  using (user_id = auth.uid() or public.nx_is_admin());

drop policy if exists withdrawals_read on public.withdrawals;
create policy withdrawals_read on public.withdrawals for select
  using (user_id = auth.uid() or public.nx_is_admin());

-- No INSERT / UPDATE / DELETE policies on those four tables on purpose.
-- They are written ONLY by the SECURITY DEFINER functions in section 5.

-- ---------- referrals ----------
drop policy if exists referrals_read on public.referrals;
create policy referrals_read on public.referrals for select
  using (referrer_id = auth.uid() or referred_id = auth.uid() or public.nx_is_admin());

-- ---------- offers: everyone reads live ones, only admin writes ----------
drop policy if exists offers_read on public.offers;
create policy offers_read on public.offers for select using (true);
drop policy if exists offers_write on public.offers;
create policy offers_write on public.offers for all
  using (public.nx_is_admin()) with check (public.nx_is_admin());

-- ---------- notifications: own only, may mark read ----------
drop policy if exists noti_read on public.notifications;
create policy noti_read on public.notifications for select
  using (user_id = auth.uid() or public.nx_is_admin());
drop policy if exists noti_update on public.notifications;
create policy noti_update on public.notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- audit: admin only ----------
drop policy if exists audit_read on public.audit;
create policy audit_read on public.audit for select using (public.nx_is_admin());


-- ============================================================================
-- 5. MONEY FUNCTIONS  (the only way a balance can ever move)
-- ============================================================================

-- ---------- claim a custom one-time referral code ----------
create or replace function public.nx_set_ref_code(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v text := upper(trim(coalesce(p_code,''))); me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null then raise exception 'Please log in again.'; end if;
  if me.ref_code_locked then raise exception 'Your code is already set and cannot be changed.'; end if;
  if v !~ '^[A-Z]{5,7}$' then raise exception 'Your code must be 5 to 7 letters (A-Z), for example MEMO.'; end if;
  if exists (select 1 from public.profiles where referral_code = v and id <> me.id) then
    raise exception 'That code is already taken. Please try another one.';
  end if;
  update public.profiles set referral_code = v, ref_code_locked = true where id = me.id;
  return v;
end; $$;

-- ---------- referral qualification: 20% of the referred player's card ----------
-- Rules: BOTH cards must be active, and the referred player's card must be at
-- least the minimum USD tier. Reward = pct% of their card completion value.
create or replace function public.nx_qualify_referral(p_referred uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.referrals; v_pct numeric; v_min numeric;
  their_card public.cards; my_card public.cards; v_reward numeric;
begin
  select * into r from public.referrals where referred_id = p_referred;
  if r.id is null or r.reward_granted then return; end if;

  v_pct := public.nx_cfg_num('referralPct', 20);
  v_min := public.nx_cfg_num('referralMinUsd', 5);

  -- referred player's earliest card at or above the minimum tier
  select c.* into their_card from public.cards c
    join public.card_levels l on l.id = c.level_id
   where c.user_id = p_referred and c.status in ('ACTIVE','COMPLETED','CLAIMED')
     and l.usd >= v_min
   order by c.started_at asc limit 1;

  -- the referrer must ALSO hold an active card
  select c.* into my_card from public.cards c
   where c.user_id = r.referrer_id and c.status in ('ACTIVE','COMPLETED','CLAIMED')
   order by c.started_at asc limit 1;

  if their_card.id is null or my_card.id is null then return; end if;

  v_reward := round(their_card.completion_value * v_pct / 100, 4);

  perform public.nx_ledger(r.referrer_id, 'REFERRAL_REWARD', 'in', v_reward,
    'Referral reward: ' || v_pct || '% of a completed card', r.id::text,
    'referral:' || r.referred_id::text);

  update public.referrals
     set qualified = true, reward_granted = true,
         reward_amount = v_reward, rewarded_at = now()
   where id = r.id;

  perform public.nx_notify(r.referrer_id,
    'Referral reward unlocked: ' || v_reward || ' NXC.', 'gift');
end; $$;

-- re-check every pending referral I own (called after I activate a card)
create or replace function public.nx_qualify_downline()
returns void language plpgsql security definer set search_path = public as $$
declare x uuid;
begin
  for x in select referred_id from public.referrals
            where referrer_id = auth.uid() and reward_granted = false loop
    perform public.nx_qualify_referral(x);
  end loop;
end; $$;

-- ---------- buy a card with the NXC wallet ----------
create or replace function public.nx_purchase_card(p_level text)
returns public.cards language plpgsql security definer set search_path = public as $$
declare l public.card_levels; c public.cards; me uuid := auth.uid();
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if (select status from public.profiles where id = me) <> 'active' then
    raise exception 'Your account is suspended.';
  end if;
  select * into l from public.card_levels where id = p_level;
  if l.id is null then raise exception 'Unknown card level.'; end if;
  if not l.enabled then raise exception 'This card level is currently unavailable.'; end if;

  -- serialise this player's purchases so a double-click cannot buy twice
  perform pg_advisory_xact_lock(hashtext('nx_purchase:' || me::text));

  perform public.nx_ledger(me, 'CARD_PURCHASE', 'out', l.cost,
    'Activated the $' || l.usd || ' card', l.id,
    'card:' || me::text || ':' || l.id || ':' || floor(extract(epoch from now()) / 10)::text);

  insert into public.cards (user_id, level_id, purchase_cost, completion_value,
                            bonus, days, started_at, ends_at, paid_via)
  values (me, l.id, l.cost, l.completion, l.bonus, l.days,
          now(), now() + (l.days || ' days')::interval, 'WALLET')
  returning * into c;

  update public.profiles set total_spent = total_spent + l.cost where id = me;

  perform public.nx_qualify_referral(me);   -- my referrer may now be eligible
  perform public.nx_qualify_downline();      -- and so may my own referrals
  return c;
end; $$;

-- ---------- claim a finished card ----------
create or replace function public.nx_claim_card(p_card uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare c public.cards; v_total numeric;
begin
  select * into c from public.cards where id = p_card and user_id = auth.uid();
  if c.id is null then raise exception 'Card not found.'; end if;
  if c.status = 'CLAIMED' then raise exception 'This card was already collected.'; end if;
  if now() < c.ends_at then raise exception 'This card is still progressing.'; end if;

  v_total := c.completion_value + c.bonus;

  perform public.nx_ledger(c.user_id, 'CARD_COMPLETION', 'in', v_total,
    'Collected the $' || (select usd from public.card_levels where id = c.level_id) || ' card',
    c.id::text, 'collect:' || c.id::text);

  update public.cards set status = 'CLAIMED', claimed_at = now() where id = c.id;
  update public.profiles set total_earned = total_earned + v_total where id = c.user_id;
  return v_total;
end; $$;

-- ---------- deposits: player submits ----------
create or replace function public.nx_create_deposit(
  p_usd numeric, p_shot_url text, p_shot_public_id text default null,
  p_txid text default null, p_note text default null
) returns public.deposits language plpgsql security definer set search_path = public as $$
declare d public.deposits; me uuid := auth.uid(); cfg jsonb := public.nx_cfg();
        v_open int; v_max int;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if p_usd is null or p_usd <= 0 then raise exception 'Choose or enter the amount you paid.'; end if;
  if coalesce(p_shot_url,'') = '' then raise exception 'Upload your payment screenshot first.'; end if;

  v_max := public.nx_cfg_num('maxPendingDeposits', 3)::int;
  select count(*) into v_open from public.deposits where user_id = me and status = 'PENDING';
  if v_open >= v_max then
    raise exception 'You already have % deposits waiting for review.', v_open;
  end if;

  insert into public.deposits (user_id, usd, nxc, address, network, coin,
                               shot_url, shot_public_id, txid, note)
  values (me, p_usd, round(p_usd * public.nx_cfg_num('usdToNxc',100), 4),
          cfg ->> 'depositAddress', cfg ->> 'depositNetwork', cfg ->> 'depositCoin',
          p_shot_url, p_shot_public_id, nullif(trim(coalesce(p_txid,'')),''),
          nullif(trim(coalesce(p_note,'')),''))
  returning * into d;

  perform public.nx_notify(me,
    'Deposit ' || d.ref || ' submitted for $' || d.usd || '. An operator will verify it shortly.', 'clock');

  -- ping every operator's inbox
  insert into public.notifications (user_id, body, icon)
  select p.id, 'New deposit ' || d.ref || ' — $' || d.usd || ' awaiting verification.', 'info'
    from public.profiles p where p.role = 'admin';

  return d;
end; $$;

-- ---------- deposits: operator verifies ----------
create or replace function public.nx_approve_deposit(
  p_id uuid, p_credit numeric default null, p_reason text default null
) returns public.deposits language plpgsql security definer set search_path = public as $$
declare d public.deposits; v_credit numeric;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  select * into d from public.deposits where id = p_id for update;
  if d.id is null then raise exception 'Deposit not found.'; end if;
  if d.status <> 'PENDING' then raise exception 'This deposit was already reviewed.'; end if;

  v_credit := coalesce(p_credit, d.nxc);
  if v_credit <= 0 then raise exception 'The credit amount must be more than zero.'; end if;

  perform public.nx_ledger(d.user_id, 'DEPOSIT_CREDIT', 'in', v_credit,
    'Deposit ' || d.ref || ' verified ($' || d.usd || ')', d.ref, 'deposit:' || d.id::text);

  update public.deposits
     set status = 'APPROVED', credited_nxc = v_credit, reason = p_reason,
         reviewed_at = now(), reviewed_by = auth.uid()
   where id = d.id returning * into d;

  perform public.nx_notify(d.user_id,
    'Deposit ' || d.ref || ' verified — ' || v_credit || ' NXC added to your wallet.', 'check');
  perform public.nx_audit('DEPOSIT_APPROVE', d.ref, v_credit::text);
  return d;
end; $$;

create or replace function public.nx_reject_deposit(p_id uuid, p_reason text)
returns public.deposits language plpgsql security definer set search_path = public as $$
declare d public.deposits;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if length(trim(coalesce(p_reason,''))) < 4 then
    raise exception 'Give the player a short reason for the rejection.';
  end if;
  select * into d from public.deposits where id = p_id for update;
  if d.id is null then raise exception 'Deposit not found.'; end if;
  if d.status <> 'PENDING' then raise exception 'This deposit was already reviewed.'; end if;

  update public.deposits
     set status = 'REJECTED', reason = p_reason, reviewed_at = now(), reviewed_by = auth.uid()
   where id = d.id returning * into d;

  perform public.nx_notify(d.user_id, 'Deposit ' || d.ref || ' was rejected: ' || p_reason, 'info');
  perform public.nx_audit('DEPOSIT_REJECT', d.ref, p_reason);
  return d;
end; $$;

-- ---------- withdrawals: player creates a ticket ----------
create or replace function public.nx_create_withdrawal(p_nxc numeric, p_address text)
returns public.withdrawals language plpgsql security definer set search_path = public as $$
declare w public.withdrawals; me uuid := auth.uid();
        v_min numeric; v_fee_pct numeric; v_hours numeric; v_fee numeric; v_rate numeric;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  v_min     := public.nx_cfg_num('sellMin', 500);
  v_fee_pct := public.nx_cfg_num('sellFeePct', 2);
  v_hours   := public.nx_cfg_num('withdrawHours', 24);
  v_rate    := public.nx_cfg_num('usdToNxc', 100);

  if p_nxc is null or p_nxc <= 0 then raise exception 'Enter the amount of NXC you want to sell.'; end if;
  if p_nxc < v_min then raise exception 'Minimum sell amount is % NXC.', v_min; end if;
  if coalesce(p_address,'') !~ '^0x[a-fA-F0-9]{40}$' then
    raise exception 'Enter a valid BEP20 (BSC) address — 0x followed by 40 characters.';
  end if;

  v_fee := round(p_nxc * v_fee_pct / 100, 4);

  insert into public.withdrawals (user_id, nxc, fee, fee_pct, net_nxc, usd, address, eta_at)
  values (me, p_nxc, v_fee, v_fee_pct, p_nxc - v_fee,
          round((p_nxc - v_fee) / v_rate, 2), p_address,
          now() + (v_hours || ' hours')::interval)
  returning * into w;

  -- hold the coins against the ticket
  perform public.nx_ledger(me, 'COIN_SELL', 'out', p_nxc,
    'Sell ' || p_nxc || ' NXC to ' || left(p_address,6) || '...' || right(p_address,4),
    w.ref, 'sell:' || w.id::text);

  perform public.nx_notify(me,
    'Sell ticket ' || w.ref || ' created. It is now waiting for operator verification.', 'info');

  insert into public.notifications (user_id, body, icon)
  select p.id, 'New withdrawal ' || w.ref || ' — ' || p_nxc || ' NXC to verify.', 'info'
    from public.profiles p where p.role = 'admin';

  return w;
end; $$;

-- ---------- withdrawals: operator verifies. NOTHING is ever auto-paid. ----------
create or replace function public.nx_mark_withdrawal_processing(p_id uuid)
returns public.withdrawals language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  update public.withdrawals set status = 'PROCESSING', reviewed_by = auth.uid()
   where id = p_id and status = 'PENDING' returning * into w;
  if w.id is null then raise exception 'Only a PENDING ticket can move to processing.'; end if;
  perform public.nx_notify(w.user_id, 'Withdrawal ' || w.ref || ' is being processed.', 'info');
  perform public.nx_audit('WITHDRAWAL_PROCESSING', w.ref);
  return w;
end; $$;

create or replace function public.nx_pay_withdrawal(p_id uuid, p_txid text default null)
returns public.withdrawals language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  select * into w from public.withdrawals where id = p_id for update;
  if w.id is null then raise exception 'Ticket not found.'; end if;
  if w.status = 'PAID' then raise exception 'This ticket is already marked paid.'; end if;
  if w.status in ('REJECTED','CANCELLED') then
    raise exception 'This ticket is closed and cannot be paid.';
  end if;

  update public.withdrawals
     set status = 'PAID', paid_at = now(), reviewed_by = auth.uid(),
         txid = nullif(trim(coalesce(p_txid,'')),'')
   where id = w.id returning * into w;

  perform public.nx_notify(w.user_id,
    'Withdrawal ' || w.ref || ' completed — ' || w.net_nxc || ' NXC sent' ||
    coalesce(' (tx ' || w.txid || ')', '') || '.', 'check');
  perform public.nx_audit('WITHDRAWAL_PAID', w.ref, w.txid);
  return w;
end; $$;

create or replace function public.nx_reject_withdrawal(p_id uuid, p_reason text)
returns public.withdrawals language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if length(trim(coalesce(p_reason,''))) < 4 then
    raise exception 'Give the player a short reason for the rejection.';
  end if;
  select * into w from public.withdrawals where id = p_id for update;
  if w.id is null then raise exception 'Ticket not found.'; end if;
  if w.status = 'PAID' then raise exception 'A paid ticket cannot be rejected.'; end if;
  if w.status in ('REJECTED','CANCELLED') then raise exception 'This ticket is already closed.'; end if;

  -- give the held coins back
  perform public.nx_ledger(w.user_id, 'SELL_REFUND', 'in', w.nxc,
    'Withdrawal ' || w.ref || ' rejected — NXC returned', w.ref, 'sellrefund:' || w.id::text);

  update public.withdrawals
     set status = 'REJECTED', rejected_at = now(), reason = p_reason, reviewed_by = auth.uid()
   where id = w.id returning * into w;

  perform public.nx_notify(w.user_id,
    'Withdrawal ' || w.ref || ' was rejected: ' || p_reason || ' — NXC returned to your wallet.', 'info');
  perform public.nx_audit('WITHDRAWAL_REJECT', w.ref, p_reason);
  return w;
end; $$;

-- ---------- operator: adjust a balance by hand ----------
create or replace function public.nx_admin_adjust_balance(
  p_user uuid, p_amount numeric, p_reason text
) returns numeric language plpgsql security definer set search_path = public as $$
declare v_bal numeric;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if p_amount is null or p_amount = 0 then raise exception 'Enter an amount to add or remove.'; end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'Give a reason for this adjustment.'; end if;

  v_bal := public.nx_ledger(p_user,
    case when p_amount > 0 then 'ADMIN_CREDIT' else 'ADMIN_DEBIT' end,
    case when p_amount > 0 then 'in' else 'out' end,
    abs(p_amount), p_reason, null, 'adjust:' || gen_random_uuid()::text);

  perform public.nx_notify(p_user,
    case when p_amount > 0 then 'An operator added ' else 'An operator removed ' end
    || abs(p_amount) || ' NXC: ' || p_reason, 'info');
  perform public.nx_audit('BALANCE_ADJUST', p_user::text, p_amount || ' — ' || p_reason);
  return v_bal;
end; $$;

-- ---------- operator: update any config value ----------
create or replace function public.nx_update_config(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_new jsonb; v_addr text;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;

  v_addr := p_patch ->> 'depositAddress';
  if v_addr is not null and v_addr <> '' and v_addr !~ '^0x[a-fA-F0-9]{40}$' then
    raise exception 'The deposit address must be a valid BEP20 address (0x + 40 characters).';
  end if;

  update public.config set data = data || p_patch where id = 1 returning data into v_new;
  perform public.nx_audit('CONFIG_UPDATE', 'config', p_patch::text);
  return v_new;
end; $$;

-- ---------- operator: create / edit a card level ----------
create or replace function public.nx_upsert_card_level(p_level jsonb)
returns public.card_levels language plpgsql security definer set search_path = public as $$
declare l public.card_levels; v_id text := p_level ->> 'id';
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if coalesce(v_id,'') = '' then raise exception 'The level needs an id, for example C25.'; end if;
  if (p_level ->> 'completion')::numeric <= (p_level ->> 'cost')::numeric then
    raise exception 'Completion value must be higher than the cost.';
  end if;

  insert into public.card_levels (id, usd, cost, completion, bonus, rarity, perk, skin, days, enabled, sort)
  values (v_id,
    (p_level ->> 'usd')::numeric, (p_level ->> 'cost')::numeric, (p_level ->> 'completion')::numeric,
    coalesce((p_level ->> 'bonus')::numeric, 0), coalesce(p_level ->> 'rarity','common'),
    coalesce(p_level ->> 'perk',''), coalesce(p_level ->> 'skin','cyan'),
    coalesce((p_level ->> 'days')::int, 30), coalesce((p_level ->> 'enabled')::boolean, true),
    coalesce((p_level ->> 'sort')::int, 0))
  on conflict (id) do update set
    usd = excluded.usd, cost = excluded.cost, completion = excluded.completion,
    bonus = excluded.bonus, rarity = excluded.rarity, perk = excluded.perk,
    skin = excluded.skin, days = excluded.days, enabled = excluded.enabled, sort = excluded.sort
  returning * into l;

  perform public.nx_audit('LEVEL_UPSERT', v_id, p_level::text);
  return l;
end; $$;

create or replace function public.nx_delete_card_level(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if exists (select 1 from public.cards where level_id = p_id) then
    raise exception 'Players own this level, so it cannot be deleted. Disable it instead.';
  end if;
  delete from public.card_levels where id = p_id;
  perform public.nx_audit('LEVEL_DELETE', p_id);
end; $$;

-- ---------- check whether a referral code exists (used on the signup form) ----------
-- Returns only the owner's display name, never their email or id.
create or replace function public.nx_check_ref_code(p_code text)
returns text language sql stable security definer set search_path = public as $$
  select name from public.profiles
   where referral_code = upper(trim(p_code)) and status = 'active' limit 1;
$$;


-- ============================================================================
-- 5b. FUNCTION PERMISSIONS  ***  THE MOST IMPORTANT SECTION  ***
-- ============================================================================
-- Postgres grants EXECUTE on every new function to PUBLIC by default. Without
-- this section a logged-in player could simply call
--     supabase.rpc('nx_ledger', { p_user: <own id>, p_dir: 'in', p_amount: 999999 })
-- and mint themselves unlimited NXC, because nx_ledger is SECURITY DEFINER and
-- does not check who the caller is (by design — it is an internal primitive).
--
-- So: revoke EXECUTE on everything, then grant back ONLY the functions a
-- browser is allowed to call. The internal ones (nx_ledger, nx_notify,
-- nx_audit, nx_qualify_referral) stay callable only from inside other
-- functions, never from the client.
-- ============================================================================

revoke all on all functions in schema public from public, anon, authenticated;

-- ---------- internal primitives: NOBODY may call these from a client ----------
-- (nx_ledger, nx_notify, nx_audit, nx_qualify_referral, nx_on_new_user,
--  nx_guard_profile, nx_random_code — deliberately not granted to anyone)

-- ---------- read-only helpers: safe for any logged-in player ----------
grant execute on function public.nx_is_admin()                     to authenticated;
grant execute on function public.nx_cfg()                          to authenticated, anon;
grant execute on function public.nx_cfg_num(text, numeric)          to authenticated, anon;
grant execute on function public.nx_card_earned(public.cards)       to authenticated;
grant execute on function public.nx_check_ref_code(text)            to authenticated, anon;

-- ---------- player actions (each one re-checks auth.uid() internally) ----------
grant execute on function public.nx_set_ref_code(text)                        to authenticated;
grant execute on function public.nx_purchase_card(text)                       to authenticated;
grant execute on function public.nx_claim_card(uuid)                          to authenticated;
grant execute on function public.nx_create_deposit(numeric, text, text, text, text) to authenticated;
grant execute on function public.nx_create_withdrawal(numeric, text)          to authenticated;
grant execute on function public.nx_qualify_downline()                        to authenticated;

-- ---------- operator actions (each one re-checks nx_is_admin() internally) ----------
grant execute on function public.nx_approve_deposit(uuid, numeric, text)      to authenticated;
grant execute on function public.nx_reject_deposit(uuid, text)                to authenticated;
grant execute on function public.nx_mark_withdrawal_processing(uuid)          to authenticated;
grant execute on function public.nx_pay_withdrawal(uuid, text)                to authenticated;
grant execute on function public.nx_reject_withdrawal(uuid, text)             to authenticated;
grant execute on function public.nx_admin_adjust_balance(uuid, numeric, text) to authenticated;
grant execute on function public.nx_update_config(jsonb)                      to authenticated;
grant execute on function public.nx_upsert_card_level(jsonb)                  to authenticated;
grant execute on function public.nx_delete_card_level(text)                   to authenticated;

-- ---------- table privileges ----------
-- RLS decides WHICH rows; these grants decide WHICH VERBS are possible at all.
-- Note there is no INSERT/UPDATE/DELETE on the money tables for anyone.
revoke all on all tables in schema public from anon, authenticated;

grant select on public.profiles, public.cards, public.txns, public.deposits,
                public.withdrawals, public.referrals, public.notifications,
                public.audit, public.config, public.card_levels, public.offers
             to authenticated;
grant select on public.config, public.card_levels, public.offers to anon;
grant update on public.profiles      to authenticated;   -- guarded by nx_guard_profile
grant update on public.notifications to authenticated;   -- mark-as-read only
grant insert, update, delete on public.offers      to authenticated;  -- RLS: admin only
grant insert, update, delete on public.card_levels to authenticated;  -- RLS: admin only
grant update on public.config to authenticated;                       -- RLS: admin only


-- ============================================================================
-- 6. SEED THE SIX CARD LEVELS
-- ============================================================================
insert into public.card_levels (id, usd, cost, completion, bonus, rarity, perk, skin, sort) values
  ('C5',     5,    500,   1000,    120, 'common',    'Starter badge + collection slot 01',        'cyan',   1),
  ('C10',   10,   1000,   2000,    300, 'common',    '+1 daily streak multiplier slot',           'violet', 2),
  ('C20',   20,   2000,   4000,    700, 'rare',      'Rare frame + priority verification queue',  'indigo', 3),
  ('C50',   50,   5000,  10000,   2000, 'rare',      'Rare frame + 1 free withdrawal ticket',     'blue',   4),
  ('C100', 100,  10000,  20000,   4500, 'epic',      'Epic aura + 2x referral reward for 7 days', 'aurora', 5),
  ('C500', 500,  50000, 100000,  26000, 'legendary', 'Legendary aura + permanent VIP offers',     'royal',  6)
on conflict (id) do nothing;


-- ============================================================================
-- 7. AFTER YOU SIGN UP: MAKE YOURSELF THE OPERATOR
-- ============================================================================
-- 1. Open the app and sign up with harisaslam003@gmail.com
-- 2. Come back here and run this single line:
--
--      update public.profiles set role = 'admin' where email = 'harisaslam003@gmail.com';
--
-- 3. Then set your deposit address (replace with your real BEP20 address):
--
--      select public.nx_update_config('{"depositAddress":"0xYOUR_REAL_ADDRESS_HERE"}'::jsonb);
--
-- Until step 2 is done, NOBODY is an admin and every operator function will
-- refuse to run. That is intentional.
-- ============================================================================


-- ============================================================================
-- 8. VERIFY  — run these separately after the file above has finished
-- ============================================================================
-- Paste each one into a NEW query if you want to confirm the setup.
--
-- a) all 11 tables exist:
--      select table_name from information_schema.tables
--       where table_schema = 'public' order by table_name;
--
-- b) every table has RLS turned on (rls_enabled must be true for all 11):
--      select relname as table_name, relrowsecurity as rls_enabled
--        from pg_class where relnamespace = 'public'::regnamespace
--         and relkind = 'r' order by relname;
--
-- c) the six card levels seeded:
--      select id, usd, cost, completion, bonus, rarity from public.card_levels
--       order by sort;
--
-- d) THE IMPORTANT ONE — prove the internal money primitives are NOT callable
--    by a logged-in player. This must return ZERO rows:
--
--      select p.proname
--        from pg_proc p
--       where p.pronamespace = 'public'::regnamespace
--         and p.proname in ('nx_ledger','nx_notify','nx_audit','nx_qualify_referral')
--         and has_function_privilege('authenticated', p.oid, 'execute');
--
--    If that returns any row, section 5b did not run — re-run this whole file.
-- ============================================================================
