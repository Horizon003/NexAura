-- ============================================================================
-- NEXAURA — PATCH WAVE-8   (run this ONCE in the Supabase SQL Editor)
-- ============================================================================
-- Safe to re-run. It only replaces functions and adds two config keys.
-- Nothing is dropped, no data is deleted.
--
-- ---------------------------------------------------------------------------
-- WHY: the real cause of "balance wapis aa jata hai"
-- ---------------------------------------------------------------------------
-- `nx_guard_profile` is a BEFORE UPDATE trigger on `profiles`. For anyone who
-- is not an admin it forces the protected columns back to their old values:
--
--     new.balance := old.balance;   new.total_spent := old.total_spent;  ...
--
-- That is correct for a player editing their own profile. The problem is that
-- the trigger fires for EVERY update — including the ones made by our own
-- trusted SECURITY DEFINER functions. Inside a SECURITY DEFINER function
-- `auth.uid()` still returns the CALLING player, so `nx_is_admin()` is false
-- and the trigger silently reverted the very debit `nx_ledger` had just made.
--
-- Result, exactly as reported:
--   * card buy      -> card IS created, txn row IS written, balance NOT debited
--   * sell ticket   -> ticket IS created, txn row IS written, balance NOT held
--   * the UI showed the optimistic debit, then `pull()` re-read the untouched
--     `profiles.balance` and the money "came back".
--
-- The same silent revert also broke:
--   * `total_spent`  (nx_purchase_card)
--   * `total_earned` (nx_claim_card)
--   * `referral_code` / `ref_code_locked` (nx_set_ref_code)
--
-- FIX: trusted functions mark the transaction with a session flag. The trigger
-- honours that flag and otherwise behaves exactly as before, so a player still
-- cannot edit their own balance, role, status or email.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The guard trigger — now aware of trusted server functions
-- ---------------------------------------------------------------------------
create or replace function public.nx_guard_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Set only inside our own SECURITY DEFINER money functions, and only for the
  -- duration of that transaction. A client can never set this: PostgREST does
  -- not expose set_config, and `nx_ledger` itself is REVOKEd from authenticated.
  if coalesce(current_setting('nx.trusted', true), '') = 'on' then
    return new;
  end if;

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

-- ---------------------------------------------------------------------------
-- 2. THE LEDGER — marks the transaction trusted around its own update
-- ---------------------------------------------------------------------------
create or replace function public.nx_ledger(
  p_user uuid, p_type text, p_dir text, p_amount numeric,
  p_desc text, p_ref text, p_idem text
) returns numeric language plpgsql security definer set search_path = public as $$
declare new_bal numeric;
begin
  if p_amount is null or p_amount < 0 then
    raise exception 'Amount must be zero or more.';
  end if;

  if exists (select 1 from public.txns where idem_key = p_idem) then
    select balance into new_bal from public.profiles where id = p_user;
    return new_bal;
  end if;

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

  -- >>> the actual fix <<<
  perform set_config('nx.trusted', 'on', true);
  update public.profiles set balance = new_bal where id = p_user;
  perform set_config('nx.trusted', 'off', true);

  insert into public.txns (user_id, type, direction, amount, balance_after,
                           description, reference_id, idem_key)
  values (p_user, p_type, p_dir, p_amount, new_bal, coalesce(p_desc,''), p_ref, p_idem);

  return new_bal;
end; $$;

-- ---------------------------------------------------------------------------
-- 3. Card purchase — total_spent was also being reverted
-- ---------------------------------------------------------------------------
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

  perform pg_advisory_xact_lock(hashtext('nx_purchase:' || me::text));

  perform public.nx_ledger(me, 'CARD_PURCHASE', 'out', l.cost,
    'Activated the $' || l.usd || ' card', l.id,
    'card:' || me::text || ':' || l.id || ':' || floor(extract(epoch from now()) / 10)::text);

  insert into public.cards (user_id, level_id, purchase_cost, completion_value,
                            bonus, days, started_at, ends_at, paid_via)
  values (me, l.id, l.cost, l.completion, l.bonus, l.days,
          now(), now() + (l.days || ' days')::interval, 'WALLET')
  returning * into c;

  perform set_config('nx.trusted', 'on', true);
  update public.profiles set total_spent = total_spent + l.cost where id = me;
  perform set_config('nx.trusted', 'off', true);

  perform public.nx_qualify_referral(me);
  perform public.nx_qualify_downline();
  return c;
end; $$;

-- ---------------------------------------------------------------------------
-- 4. Claim a finished card — total_earned was also being reverted
-- ---------------------------------------------------------------------------
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

  perform set_config('nx.trusted', 'on', true);
  update public.profiles set total_earned = total_earned + v_total where id = c.user_id;
  perform set_config('nx.trusted', 'off', true);

  return v_total;
end; $$;

-- ---------------------------------------------------------------------------
-- 5. Referral code — the code was never actually saved
-- ---------------------------------------------------------------------------
create or replace function public.nx_set_ref_code(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v text := upper(trim(coalesce(p_code,''))); me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null then raise exception 'Please log in again.'; end if;
  if me.ref_code_locked then raise exception 'Your code is already set and cannot be changed.'; end if;
  if v !~ '^[A-Z]{5,7}$' then raise exception 'Your code must be 5 to 7 letters (A-Z).'; end if;
  if exists (select 1 from public.profiles where referral_code = v and id <> me.id) then
    raise exception 'That code is already taken. Please try another one.';
  end if;

  perform set_config('nx.trusted', 'on', true);
  update public.profiles set referral_code = v, ref_code_locked = true where id = me.id;
  perform set_config('nx.trusted', 'off', true);

  return v;
end; $$;

-- ---------------------------------------------------------------------------
-- 6. NEW REFERRAL RULE — 2 slots, flat 250 NXC each, friend needs a $5+ card
-- ---------------------------------------------------------------------------
-- Replaces the old "20% of their completion value" rule.
insert into public.config (id, data) values (1, '{}'::jsonb)
  on conflict (id) do nothing;

update public.config
   set data = data || '{"referralFlat":250,"referralSlots":2,"referralMinUsd":5}'::jsonb
 where id = 1;

create or replace function public.nx_qualify_referral(p_referred uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.referrals; v_flat numeric; v_min numeric; v_slots int; v_used int;
  their_card public.cards;
begin
  select * into r from public.referrals where referred_id = p_referred;
  if r.id is null or r.reward_granted then return; end if;

  v_flat  := public.nx_cfg_num('referralFlat', 250);
  v_min   := public.nx_cfg_num('referralMinUsd', 5);
  v_slots := public.nx_cfg_num('referralSlots', 2)::int;

  -- only the first N successful referrals are rewarded
  select count(*) into v_used from public.referrals
   where referrer_id = r.referrer_id and reward_granted = true;
  if v_used >= v_slots then return; end if;

  -- the friend must hold a card at or above the minimum tier
  select c.* into their_card from public.cards c
    join public.card_levels l on l.id = c.level_id
   where c.user_id = p_referred and c.status in ('ACTIVE','COMPLETED','CLAIMED')
     and l.usd >= v_min
   order by c.started_at asc limit 1;

  if their_card.id is null then return; end if;

  perform public.nx_ledger(r.referrer_id, 'REFERRAL_REWARD', 'in', v_flat,
    'Referral reward — friend activated a $' || v_min || '+ card', r.id::text,
    'referral:' || r.referred_id::text);

  update public.referrals
     set qualified = true, reward_granted = true,
         reward_amount = v_flat, rewarded_at = now()
   where id = r.id;

  perform public.nx_notify(r.referrer_id,
    'Referral reward unlocked: ' || v_flat || ' NXC.', 'gift');
end; $$;

-- re-check my pending referrals (kept, but no longer needs my own card)
create or replace function public.nx_qualify_downline()
returns void language plpgsql security definer set search_path = public as $$
declare x uuid;
begin
  for x in select referred_id from public.referrals
            where referrer_id = auth.uid() and reward_granted = false loop
    perform public.nx_qualify_referral(x);
  end loop;
end; $$;

-- ---------------------------------------------------------------------------
-- 7. Re-apply the grants (function bodies were replaced above)
-- ---------------------------------------------------------------------------
revoke execute on function public.nx_ledger(uuid, text, text, numeric, text, text, text) from authenticated;
revoke execute on function public.nx_qualify_referral(uuid) from authenticated;

grant execute on function public.nx_purchase_card(text)        to authenticated;
grant execute on function public.nx_claim_card(uuid)           to authenticated;
grant execute on function public.nx_set_ref_code(text)         to authenticated;
grant execute on function public.nx_qualify_downline()         to authenticated;

-- ---------------------------------------------------------------------------
-- 8. VERIFY — run these after the patch
-- ---------------------------------------------------------------------------
-- a) balance now really moves. Replace the email with a test player's:
--
--    select balance from public.profiles where email = 'test@example.com';
--    -- buy a card from the app, then run it again: it MUST be lower.
--
-- b) a player still cannot edit protected columns (should change nothing):
--
--    update public.profiles set balance = 999999 where id = auth.uid();
--
-- c) referral config is in place:
--
--    select data ->> 'referralFlat'  as flat,
--           data ->> 'referralSlots' as slots,
--           data ->> 'referralMinUsd' as min_usd
--      from public.config where id = 1;
