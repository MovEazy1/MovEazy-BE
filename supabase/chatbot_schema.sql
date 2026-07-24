-- Flat-search chatbot persistence (fe/src/components/FlatSearchAgentChat.jsx via
-- fe/src/lib/chatbotSessionStore.js). Already exists in the live project this repo
-- points at (VITE_SUPABASE_URL) — this file just tracks the schema in git so a
-- fresh project can be brought up to parity.

create extension if not exists "uuid-ossp";

do $$
begin
  if not exists (select 1 from pg_type where typname = 'chat_role') then
    create type public.chat_role as enum ('user', 'assistant');
  end if;
end $$;

create table if not exists public.chatbot_sessions (
  id uuid primary key default extensions.uuid_generate_v4(),
  user_id uuid references public.profiles(id),
  preferences jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.chatbot_messages (
  id uuid primary key default extensions.uuid_generate_v4(),
  session_id uuid not null references public.chatbot_sessions(id) on delete cascade,
  role public.chat_role not null,
  content text not null,
  created_at timestamptz not null default now()
);

create index if not exists chatbot_messages_session_id_idx
  on public.chatbot_messages (session_id);

alter table public.chatbot_sessions enable row level security;
alter table public.chatbot_messages enable row level security;

-- Anonymous (guest) and signed-in visitors can all start/continue a chat —
-- the widget has no separate auth of its own, so access mirrors that: anyone
-- can create a session and post messages to it.
drop policy if exists "anyone can manage chatbot sessions" on public.chatbot_sessions;
create policy "anyone can manage chatbot sessions"
  on public.chatbot_sessions for all
  using (true)
  with check (true);

drop policy if exists "anyone can manage chatbot messages" on public.chatbot_messages;
create policy "anyone can manage chatbot messages"
  on public.chatbot_messages for all
  using (true)
  with check (true);
