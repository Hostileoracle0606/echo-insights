-- How a user turn reached Lumen (LM-12): spoken and transcribed, or typed in
-- the composer mid-conversation. Every existing turn was spoken, so the
-- default backfills them as voice. Assistant turns are always voice.
--
-- Turns stay immutable: update is still revoked from authenticated, and the
-- existing insert policy covers the new column.
alter table public.conversation_turns
  add column input text not null default 'voice'
    check (input in ('voice', 'typed'));
