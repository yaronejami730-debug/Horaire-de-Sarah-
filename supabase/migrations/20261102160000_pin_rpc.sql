-- Accès protégé par code : l'app appelle des fonctions qui vérifient le code (haché en base).
-- Le code n'est PAS dans ce fichier : il est réglé directement dans la table config (pin_hash).

create extension if not exists pgcrypto with schema extensions;

-- Tentatives ratées (verrou : 10 échecs / 15 min)
create table if not exists public.pin_fails (
  id bigserial primary key,
  at timestamptz not null default now()
);
alter table public.pin_fails enable row level security;

-- Retourne null si le code est bon, sinon un objet d'erreur.
-- (On ne lève pas d'exception : elle annulerait l'enregistrement de l'échec.)
create or replace function public.pin_ok(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare h text := cfg('pin_hash');
begin
  delete from pin_fails where at < now() - interval '1 day';
  if (select count(*) from pin_fails where at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'code', 'locked', 'error', 'Trop d''essais. Réessaie dans 15 minutes.');
  end if;
  if coalesce(h,'') = '' or p is null or crypt(p, h) <> h then
    insert into pin_fails default values;
    return jsonb_build_object('ok', false, 'code', 'pin', 'error', 'Code incorrect');
  end if;
  return null;
end $$;
revoke all on function public.pin_ok(text) from public, anon, authenticated;

create or replace function public.app_load(p text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := pin_ok(p);
begin
  if v is not null then return v; end if;
  return jsonb_build_object('ok', true,
    'entries', coalesce((select jsonb_agg((to_jsonb(e) - 'updated_at') order by e.date) from entries e), '[]'::jsonb),
    'months',  coalesce((select jsonb_agg(to_jsonb(m)) from months m), '[]'::jsonb));
end $$;

create or replace function public.app_save(p text, d date, m int, mt numeric, t numeric, db text, f text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := pin_ok(p);
begin
  if v is not null then return v; end if;
  insert into entries(date, minutes, montant, taux, debut, fin) values (d, m, mt, t, db, f)
  on conflict (date) do update set minutes = excluded.minutes, montant = excluded.montant,
    taux = excluded.taux, debut = excluded.debut, fin = excluded.fin;
  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

create or replace function public.app_delete(p text, d date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := pin_ok(p);
begin
  if v is not null then return v; end if;
  delete from entries where date = d;
  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

create or replace function public.app_paid(p text, k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb := pin_ok(p);
begin
  if v is not null then return v; end if;
  insert into months(month, statut, paye_le) values (k, 'paye', now())
  on conflict (month) do update set statut = 'paye', paye_le = now();
  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

revoke all on function public.app_load(text) from public;
revoke all on function public.app_save(text,date,int,numeric,numeric,text,text) from public;
revoke all on function public.app_delete(text,date) from public;
revoke all on function public.app_paid(text,text) from public;
grant execute on function public.app_load(text) to anon;
grant execute on function public.app_save(text,date,int,numeric,numeric,text,text) to anon;
grant execute on function public.app_delete(text,date) to anon;
grant execute on function public.app_paid(text,text) to anon;
