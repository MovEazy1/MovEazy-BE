-- Migration: track whether a user has already been shown the one-time
-- "top 5 matches" swipe screen, so a returning visitor goes straight to the
-- map instead of seeing it again.
-- Safe to run on an existing database (no-op if the column already exists).
-- Run once in the Supabase SQL editor.

alter table public.user_requirements
  add column if not exists matches_seen boolean not null default false;
