-- Migration: add the mandatory WhatsApp number to the Find My Flat questionnaire.
-- Safe to run on an existing database (no-op if the column already exists).
-- Run once in the Supabase SQL editor.

alter table public.user_requirements
  add column if not exists whatsapp text default '';
