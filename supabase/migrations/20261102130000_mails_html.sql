-- Mails HTML (compatibles clients mail : tables + styles inline) et dates en français

create or replace function public.fr_jour(d date) returns text language sql immutable as $$
  select (array['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'])[extract(isodow from d)::int] $$;

create or replace function public.fr_mois(d date) returns text language sql immutable as $$
  select (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from d)::int] $$;

create or replace function public.eur(v numeric) returns text language sql immutable as $$
  select replace(to_char(v, 'FM999990D00'), '.', ',') || ' €' $$;

-- Gabarit HTML : en-tête violet, carte blanche, bouton rose
create or replace function public.mail_shell(titre text, corps text, bouton text, preheader text default '')
returns text language sql stable security definer set search_path = public as $$
select
'<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
|| '<title>' || titre || '</title></head>'
|| '<body style="margin:0;padding:0;background:#F4F1FB;">'
|| '<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#F4F1FB;">' || preheader || '</div>'
|| '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#F4F1FB"><tr><td align="center" style="padding:24px 12px;">'
|| '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;">'
-- en-tête
|| '<tr><td bgcolor="#231942" style="background:#231942;border-radius:24px 24px 0 0;padding:26px 28px;font-family:Arial,Helvetica,sans-serif;">'
|| '<div style="font-size:13px;letter-spacing:2px;color:#FFC93C;font-weight:bold;">HDS</div>'
|| '<div style="font-size:26px;line-height:1.25;color:#ffffff;font-weight:bold;margin-top:6px;">' || titre || '</div>'
|| '</td></tr>'
-- corps
|| '<tr><td bgcolor="#ffffff" style="background:#ffffff;padding:26px 28px;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.55;color:#231942;border-left:2px solid #E4DEF3;border-right:2px solid #E4DEF3;">'
|| corps
|| case when coalesce(cfg('app_url'),'') <> '' then
     '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:22px;"><tr>'
     || '<td bgcolor="#FF5C8A" style="background:#FF5C8A;border-radius:14px;">'
     || '<a href="' || cfg('app_url') || '" style="display:inline-block;padding:15px 26px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;color:#ffffff;text-decoration:none;">' || bouton || '</a>'
     || '</td></tr></table>'
   else '' end
|| '</td></tr>'
-- pied
|| '<tr><td bgcolor="#EFEAFB" style="background:#EFEAFB;border-radius:0 0 24px 24px;padding:16px 28px;font-family:Arial,Helvetica,sans-serif;font-size:12px;color:#6B6385;text-align:center;">'
|| 'Mail automatique · Mes heures'
|| '</td></tr>'
|| '</table></td></tr></table></body></html>' $$;

-- ───────────── Rappel quotidien ─────────────
create or replace function public.rappel_quotidien(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  dow int := extract(isodow from p);
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  mk text := to_char(d, 'YYYY-MM');
  m_min int; m_eur numeric; m_days int;
  jour text := fr_jour(d) || ' ' || extract(day from d)::int || ' ' || fr_mois(d);
begin
  if not force then
    if extract(hour from p)::int <> coalesce(nullif(cfg('send_hour'),'')::int, 18) then return; end if;
    if dow > 4 then return; end if;
    if exists (select 1 from entries where date = d) then return; end if;
  end if;

  select coalesce(sum(minutes),0), coalesce(sum(montant),0), count(*)
    into m_min, m_eur, m_days from entries where to_char(date,'YYYY-MM') = mk;

  perform send_mail('quotidien', 'Tes horaires d''aujourd''hui ?',
    mail_shell('Salut 👋 tes horaires ?',
      '<p style="margin:0 0 14px;">Quels sont tes horaires <b>aujourd''hui</b> (' || jour || ') ?</p>'
      || '<p style="margin:0 0 18px;color:#6B6385;">Ça prend 10 secondes : choisis ton début et ta fin.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>'
      || '<td bgcolor="#FFF4D6" style="background:#FFF4D6;border-radius:16px;padding:14px 16px;font-family:Arial,Helvetica,sans-serif;">'
      || '<div style="font-size:13px;color:#6B6385;">Ta tirelire ce mois-ci 🐷</div>'
      || '<div style="font-size:24px;font-weight:bold;color:#231942;">' || eur(m_eur) || '</div>'
      || '<div style="font-size:13px;color:#6B6385;">' || fmt_h(m_min) || ' · ' || m_days || ' jour' || case when m_days > 1 then 's' else '' end || ' (' || rate::int || ' €/h)</div>'
      || '</td></tr></table>',
      'Noter mes heures',
      'Quels sont tes horaires aujourd''hui ?'));
end $$;

-- ───────────── Clôture de fin de mois ─────────────
create or replace function public.cloture_mois(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  k text := to_char(d, 'YYYY-MM');
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  tot_m int; tot_e numeric; n int; rows_html text;
  mois text := fr_mois(d) || ' ' || extract(year from d)::int;
begin
  if not force then
    if extract(hour from p)::int <> coalesce(nullif(cfg('send_hour'),'')::int, 18) then return; end if;
    if (d + 1) <> date_trunc('month', d + 1)::date then return; end if;
    if exists (select 1 from months where month = k and statut = 'paye') then return; end if;
  end if;

  select coalesce(sum(minutes),0), coalesce(sum(montant),0), count(*)
    into tot_m, tot_e, n from entries where to_char(date,'YYYY-MM') = k;

  select coalesce(string_agg(
      '<tr>'
      || '<td style="padding:10px 0;border-bottom:1px dashed #E4DEF3;font-size:15px;">Semaine du ' || extract(day from w)::int || ' ' || fr_mois(w)
      || '<div style="font-size:12px;color:#6B6385;">' || j || ' jour' || case when j > 1 then 's' else '' end || '</div></td>'
      || '<td align="right" style="padding:10px 0;border-bottom:1px dashed #E4DEF3;font-size:15px;white-space:nowrap;">' || fmt_h(m) || '</td>'
      || '<td align="right" style="padding:10px 0 10px 12px;border-bottom:1px dashed #E4DEF3;font-size:15px;font-weight:bold;white-space:nowrap;">' || eur(e) || '</td>'
      || '</tr>', '' order by w), '')
    into rows_html
  from (select date_trunc('week', date)::date w, count(*) j, sum(minutes)::int m, sum(montant) e
        from entries where to_char(date,'YYYY-MM') = k group by 1) s;

  if n = 0 then rows_html := '<tr><td style="padding:12px 0;color:#6B6385;">Aucune heure saisie ce mois-ci.</td></tr>'; end if;

  perform send_mail('cloture', 'Clôture ton mois : ' || mois,
    mail_shell('C''est la fin du mois 🐷',
      '<p style="margin:0 0 16px;">Vérifie tes heures de <b>' || mois || '</b>, puis clôture ton dossier.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">' || rows_html || '</table>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:16px;"><tr>'
      || '<td bgcolor="#231942" style="background:#231942;border-radius:16px;padding:16px 18px;font-family:Arial,Helvetica,sans-serif;">'
      || '<div style="font-size:13px;color:#B3AACB;">Total · ' || n || ' jour' || case when n > 1 then 's' else '' end || ' · ' || fmt_h(tot_m) || ' × ' || rate::int || ' €/h</div>'
      || '<div style="font-size:28px;font-weight:bold;color:#FFC93C;">' || eur(tot_e) || '</div>'
      || '</td></tr></table>',
      'Clôturer mon mois',
      'Ton total du mois : ' || eur(tot_e)));
end $$;

revoke all on function public.rappel_quotidien(boolean) from public, anon, authenticated;
revoke all on function public.cloture_mois(boolean) from public, anon, authenticated;
revoke all on function public.mail_shell(text,text,text,text) from public, anon, authenticated;
drop function if exists public.mail_shell(text,text,text);
