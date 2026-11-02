-- Horaire de Sarah : heures, clôture mensuelle, rappels mail (Brevo)

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ───────────── Tables ─────────────
create table public.entries (
  date    date primary key,
  minutes integer not null check (minutes > 0 and minutes <= 840),
  montant numeric(8,2) not null,
  taux    numeric(6,2) not null default 12,
  debut   text check (debut ~ '^\d{2}:\d{2}$'),
  fin     text check (fin   ~ '^\d{2}:\d{2}$'),
  updated_at timestamptz not null default now()
);

create table public.months (
  month   text primary key check (month ~ '^\d{4}-\d{2}$'),
  statut  text not null default 'ouvert' check (statut in ('ouvert','paye')),
  paye_le timestamptz
);

-- Réglages + secrets : aucun accès anon (RLS sans policy)
create table public.config (
  key   text primary key,
  value text not null
);

create table public.mail_log (
  id bigserial primary key,
  sent_at timestamptz not null default now(),
  kind text not null,
  to_email text,
  subject text,
  status text,
  request_id bigint
);

alter table public.entries  enable row level security;
alter table public.months   enable row level security;
alter table public.config   enable row level security;
alter table public.mail_log enable row level security;

-- App sans login (comme l'original) : le lien fait office d'accès.
create policy entries_select on public.entries for select to anon using (true);
create policy entries_insert on public.entries for insert to anon with check (true);
create policy entries_update on public.entries for update to anon using (true) with check (true);
create policy entries_delete on public.entries for delete to anon using (true);
create policy months_select  on public.months  for select to anon using (true);
create policy months_insert  on public.months  for insert to anon with check (statut = 'paye');
create policy months_update  on public.months  for update to anon using (true) with check (statut = 'paye');

-- Mois payé = verrouillé
create or replace function public.guard_paid_month() returns trigger
language plpgsql set search_path = public as $$
declare k text;
begin
  if tg_op = 'DELETE' then k := to_char(old.date, 'YYYY-MM'); else k := to_char(new.date, 'YYYY-MM'); end if;
  if exists (select 1 from months where month = k and statut = 'paye') then
    raise exception 'Ce mois est déjà clôturé et payé.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger entries_guard before insert or update or delete on public.entries
for each row execute function public.guard_paid_month();

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger entries_touch before update on public.entries
for each row execute function public.touch_updated_at();

-- ───────────── Réglages par défaut ─────────────
insert into public.config(key, value) values
  ('rate',          '12'),
  ('app_url',       ''),
  ('to_email',      ''),
  ('cc_email',      ''),
  ('sender_email',  ''),
  ('sender_name',   'Mes heures'),
  ('brevo_api_key', ''),
  ('send_hour',     '18')          -- heure de Paris
on conflict do nothing;

-- ───────────── Outils mail ─────────────
create or replace function public.fmt_h(m integer) returns text
language sql immutable as $$ select (m / 60)::text || 'h' || lpad((m % 60)::text, 2, '0') $$;

create or replace function public.cfg(k text) returns text
language sql stable security definer set search_path = public as
$$ select value from config where key = k $$;

create or replace function public.send_mail(kind text, subject text, html text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  key text := cfg('brevo_api_key');
  to_e text := cfg('to_email');
  cc_e text := cfg('cc_email');
  snd text := cfg('sender_email');
  rid bigint;
  payload jsonb;
begin
  if coalesce(key,'') = '' or coalesce(to_e,'') = '' or coalesce(snd,'') = '' then
    insert into mail_log(kind, to_email, subject, status) values (kind, to_e, subject, 'ignoré : config Brevo incomplète');
    return;
  end if;
  payload := jsonb_build_object(
    'sender',      jsonb_build_object('name', cfg('sender_name'), 'email', snd),
    'to',          jsonb_build_array(jsonb_build_object('email', to_e)),
    'subject',     subject,
    'htmlContent', html);
  if coalesce(cc_e,'') <> '' then
    payload := payload || jsonb_build_object('cc', jsonb_build_array(jsonb_build_object('email', cc_e)));
  end if;
  select net.http_post(
    url     := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', key, 'content-type', 'application/json', 'accept', 'application/json'),
    body    := payload) into rid;
  insert into mail_log(kind, to_email, subject, status, request_id) values (kind, to_e, subject, 'envoyé', rid);
end $$;

revoke all on function public.send_mail(text,text,text) from public, anon, authenticated;
revoke all on function public.cfg(text) from public, anon, authenticated;

-- Gabarit commun
create or replace function public.mail_shell(titre text, corps text, bouton text)
returns text language sql stable security definer set search_path = public as $$
select '<div style="font-family:Arial,sans-serif;background:#F4F1FB;padding:24px"><div style="max-width:520px;margin:0 auto;background:#fff;border-radius:20px;padding:24px;color:#231942">'
  || '<h2 style="margin:0 0 12px">' || titre || '</h2>' || corps
  || case when coalesce(cfg('app_url'),'') <> ''
       then '<p style="margin-top:20px"><a href="' || cfg('app_url') || '" style="background:#FF5C8A;color:#fff;text-decoration:none;padding:14px 22px;border-radius:14px;font-weight:bold;display:inline-block">' || bouton || '</a></p>'
       else '' end
  || '</div></div>' $$;

-- ───────────── Rappel quotidien (lun-jeu, si rien saisi) ─────────────
create or replace function public.rappel_quotidien(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  dow int := extract(isodow from p);   -- 1 = lundi
begin
  if not force then
    if extract(hour from p)::int <> coalesce(nullif(cfg('send_hour'),'')::int, 18) then return; end if;
    if dow > 4 then return; end if;
    if exists (select 1 from entries where date = d) then return; end if;
  end if;
  perform send_mail('quotidien', 'Tes horaires d''aujourd''hui ?',
    mail_shell('Salut 👋',
      '<p>Quels sont tes horaires aujourd''hui (' || to_char(d, 'DD/MM/YYYY') || ') ?</p><p>Ça prend 10 secondes.</p>',
      'Noter mes heures'));
end $$;

-- ───────────── Clôture de fin de mois (dernier jour, 30 ou 31) ─────────────
create or replace function public.cloture_mois(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  k text := to_char(d, 'YYYY-MM');
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  tot_m int; tot_e numeric; n int; rows_html text;
begin
  if not force then
    if extract(hour from p)::int <> coalesce(nullif(cfg('send_hour'),'')::int, 18) then return; end if;
    if (d + 1) <> date_trunc('month', d + 1)::date then return; end if;   -- pas le dernier jour
    if exists (select 1 from months where month = k and statut = 'paye') then return; end if;
  end if;

  select coalesce(sum(minutes),0), coalesce(sum(montant),0), count(*)
    into tot_m, tot_e, n from entries where to_char(date,'YYYY-MM') = k;

  select coalesce(string_agg(
      '<tr><td style="padding:6px 0">Semaine du ' || to_char(w, 'DD/MM') || '</td>'
      || '<td style="text-align:right">' || j || ' j</td>'
      || '<td style="text-align:right">' || fmt_h(m) || '</td>'
      || '<td style="text-align:right"><b>' || to_char(e, 'FM999990D00') || ' €</b></td></tr>', '' order by w), '')
    into rows_html
  from (select date_trunc('week', date)::date w, count(*) j, sum(minutes)::int m, sum(montant) e
        from entries where to_char(date,'YYYY-MM') = k group by 1) s;

  perform send_mail('cloture', 'Clôture ton mois : ' || to_char(d, 'TMmonth YYYY'),
    mail_shell('C''est la fin du mois 🐷',
      '<p>Vérifie tes heures puis clôture ton dossier.</p>'
      || '<table style="width:100%;border-collapse:collapse;font-size:15px">' || rows_html || '</table>'
      || '<p style="font-size:18px;margin-top:14px"><b>Total : ' || fmt_h(tot_m) || ' × ' || rate || ' €/h = '
      || to_char(tot_e, 'FM999990D00') || ' €</b> (' || n || ' jours)</p>',
      'Clôturer mon mois'));
end $$;

revoke all on function public.rappel_quotidien(boolean) from public, anon, authenticated;
revoke all on function public.cloture_mois(boolean) from public, anon, authenticated;

-- ───────────── Planification (UTC ; la fonction vérifie l'heure de Paris) ─────────────
select cron.schedule('rappel-quotidien', '0 16,17 * * 1-4', $$select public.rappel_quotidien()$$);
select cron.schedule('cloture-mois',     '0 16,17 28-31 * *', $$select public.cloture_mois()$$);
