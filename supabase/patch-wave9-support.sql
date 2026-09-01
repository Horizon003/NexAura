-- ============================================================================
-- NEXAURA — PATCH WAVE-9: CUSTOMER SUPPORT
-- ============================================================================
-- Run ONCE in the Supabase SQL Editor, AFTER patch-wave8.sql.
-- Safe to re-run. Creates two tables + the functions the chat widget uses.
--
-- Model:
--   support_tickets   one row per conversation (the ticket the operator sees)
--   support_messages  every message in that conversation, both directions
--
-- The chat widget collects details with a scripted flow, then calls
-- nx_support_open() ONCE with a transcript. The operator answers from the
-- Support tab; the player sees the reply in the same chat window.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.support_tickets (
  id          uuid primary key default gen_random_uuid(),
  ref         text unique,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  topic       text not null,
  subject     text not null,
  status      text not null default 'OPEN'
              check (status in ('OPEN','ANSWERED','RESOLVED','CLOSED')),
  priority    text not null default 'NORMAL'
              check (priority in ('LOW','NORMAL','HIGH')),
  unread_admin  boolean not null default true,   -- operator has not read it
  unread_user   boolean not null default false,  -- player has an unread reply
  assigned_to uuid references public.profiles(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);

create table if not exists public.support_messages (
  id         uuid primary key default gen_random_uuid(),
  ticket_id  uuid not null references public.support_tickets(id) on delete cascade,
  author_id  uuid references public.profiles(id),
  sender     text not null check (sender in ('USER','OPERATOR','BOT')),
  body       text not null,
  created_at timestamptz not null default now()
);

create index if not exists support_tickets_user_idx
  on public.support_tickets(user_id, created_at desc);
create index if not exists support_tickets_status_idx
  on public.support_tickets(status, created_at desc);
create index if not exists support_messages_ticket_idx
  on public.support_messages(ticket_id, created_at asc);

-- ---------------------------------------------------------------------------
-- 2. Row Level Security
-- ---------------------------------------------------------------------------
alter table public.support_tickets  enable row level security;
alter table public.support_messages enable row level security;

drop policy if exists st_read on public.support_tickets;
create policy st_read on public.support_tickets for select
  using (user_id = auth.uid() or public.nx_is_admin());

drop policy if exists sm_read on public.support_messages;
create policy sm_read on public.support_messages for select
  using (
    public.nx_is_admin()
    or exists (select 1 from public.support_tickets t
                where t.id = ticket_id and t.user_id = auth.uid())
  );

-- No direct INSERT/UPDATE policies: everything goes through the functions
-- below, so a player can never forge a sender or reopen a closed ticket.

-- ---------------------------------------------------------------------------
-- 3. Player opens a ticket (called once, at the end of the chat flow)
-- ---------------------------------------------------------------------------
create or replace function public.nx_support_open(
  p_topic text, p_subject text, p_transcript jsonb
) returns public.support_tickets
language plpgsql security definer set search_path = public as $$
declare t public.support_tickets; me uuid := auth.uid();
        v_open int; m jsonb; v_ref text;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if coalesce(trim(p_topic),'')   = '' then raise exception 'Choose what your question is about.'; end if;
  if coalesce(trim(p_subject),'') = '' then raise exception 'Please describe your issue.'; end if;

  -- stop ticket spam
  select count(*) into v_open from public.support_tickets
   where user_id = me and status in ('OPEN','ANSWERED');
  if v_open >= 3 then
    raise exception 'You already have % open tickets. Please wait for a reply.', v_open;
  end if;

  v_ref := 'SUP' || to_char(now(),'YYMMDD') || lpad(floor(random()*9999)::text, 4, '0');

  insert into public.support_tickets (ref, user_id, topic, subject)
  values (v_ref, me, left(p_topic,60), left(p_subject,500))
  returning * into t;

  -- store the scripted conversation so the operator sees the full context
  if p_transcript is not null and jsonb_typeof(p_transcript) = 'array' then
    for m in select * from jsonb_array_elements(p_transcript) loop
      insert into public.support_messages (ticket_id, author_id, sender, body)
      values (
        t.id,
        case when coalesce(m ->> 'sender','USER') = 'USER' then me else null end,
        case when coalesce(m ->> 'sender','USER') in ('USER','BOT','OPERATOR')
             then m ->> 'sender' else 'USER' end,
        left(coalesce(m ->> 'body',''), 2000)
      );
    end loop;
  end if;

  -- tell every operator
  insert into public.notifications (user_id, body, icon)
  select p.id, 'New support ticket ' || t.ref || ' — ' || left(p_subject, 60), 'info'
    from public.profiles p where p.role = 'admin';

  return t;
end; $$;

-- ---------------------------------------------------------------------------
-- 4. Either side adds a message
-- ---------------------------------------------------------------------------
create or replace function public.nx_support_reply(p_ticket uuid, p_body text)
returns public.support_messages
language plpgsql security definer set search_path = public as $$
declare t public.support_tickets; m public.support_messages;
        me uuid := auth.uid(); v_admin boolean := public.nx_is_admin();
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if coalesce(trim(p_body),'') = '' then raise exception 'Type a message first.'; end if;

  select * into t from public.support_tickets where id = p_ticket;
  if t.id is null then raise exception 'Ticket not found.'; end if;
  if not v_admin and t.user_id <> me then raise exception 'This ticket is not yours.'; end if;
  if t.status = 'CLOSED' then raise exception 'This ticket is closed. Please open a new one.'; end if;

  insert into public.support_messages (ticket_id, author_id, sender, body)
  values (p_ticket, me, case when v_admin then 'OPERATOR' else 'USER' end,
          left(p_body, 2000))
  returning * into m;

  if v_admin then
    update public.support_tickets
       set status = 'ANSWERED', unread_user = true, unread_admin = false,
           assigned_to = me, updated_at = now()
     where id = p_ticket;
    perform public.nx_notify(t.user_id,
      'Support replied to ticket ' || t.ref || '.', 'info');
  else
    update public.support_tickets
       set status = 'OPEN', unread_admin = true, unread_user = false,
           updated_at = now()
     where id = p_ticket;
  end if;

  return m;
end; $$;

-- ---------------------------------------------------------------------------
-- 5. Operator changes the status / player marks their replies read
-- ---------------------------------------------------------------------------
create or replace function public.nx_support_set_status(p_ticket uuid, p_status text)
returns public.support_tickets
language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  if not public.nx_is_admin() then raise exception 'Operator access required.'; end if;
  if p_status not in ('OPEN','ANSWERED','RESOLVED','CLOSED') then
    raise exception 'Unknown status.';
  end if;

  update public.support_tickets
     set status = p_status, updated_at = now(), unread_admin = false,
         closed_at = case when p_status in ('RESOLVED','CLOSED') then now() else null end
   where id = p_ticket returning * into t;
  if t.id is null then raise exception 'Ticket not found.'; end if;

  perform public.nx_notify(t.user_id,
    'Support ticket ' || t.ref || ' is now ' || lower(p_status) || '.', 'info');
  perform public.nx_audit('SUPPORT_' || p_status, t.ref);
  return t;
end; $$;

create or replace function public.nx_support_mark_read(p_ticket uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.support_tickets;
begin
  select * into t from public.support_tickets where id = p_ticket;
  if t.id is null then return; end if;
  if public.nx_is_admin() then
    update public.support_tickets set unread_admin = false where id = p_ticket;
  elsif t.user_id = auth.uid() then
    update public.support_tickets set unread_user = false where id = p_ticket;
  end if;
end; $$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.nx_support_open(text, text, jsonb)  to authenticated;
grant execute on function public.nx_support_reply(uuid, text)        to authenticated;
grant execute on function public.nx_support_set_status(uuid, text)   to authenticated;
grant execute on function public.nx_support_mark_read(uuid)          to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Enable realtime so replies appear without a reload
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.support_tickets;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.support_messages;
  exception when duplicate_object then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 8. VERIFY
-- ---------------------------------------------------------------------------
--   select ref, topic, status, unread_admin from public.support_tickets
--    order by created_at desc limit 10;
--
--   select sender, body from public.support_messages
--    where ticket_id = 'PASTE-ID' order by created_at;
