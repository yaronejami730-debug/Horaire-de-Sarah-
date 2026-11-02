-- Envoi à 21h30 (Paris) : rappel tous les jours, clôture le dernier jour du mois
-- Détail des horaires jour par jour dans le mail de clôture

insert into public.config(key, value) values ('send_hour','21'), ('send_minute','30')
on conflict (key) do update set value = excluded.value;

-- true quand il est l'heure d'envoi à Paris (21h30 → 21h59, l'été comme l'hiver)
create or replace function public.est_heure_envoi() returns boolean
language sql stable security definer set search_path = public as $$
  select extract(hour   from now() at time zone 'Europe/Paris')::int = coalesce(nullif(cfg('send_hour'),'')::int, 21)
     and extract(minute from now() at time zone 'Europe/Paris')::int >= coalesce(nullif(cfg('send_minute'),'')::int, 30) $$;
revoke all on function public.est_heure_envoi() from public, anon, authenticated;

-- ───────────── Rappel : tous les jours, si rien de saisi ─────────────
create or replace function public.rappel_quotidien(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  mk text := to_char(d, 'YYYY-MM');
  prenom text := coalesce(nullif(cfg('prenom'),''), '');
  m_min int; m_eur numeric; m_days int;
  jour text := fr_jour(d) || ' ' || extract(day from d)::int || ' ' || fr_mois(d);
begin
  if not force then
    if not est_heure_envoi() then return; end if;
    if exists (select 1 from entries where date = d) then return; end if;
  end if;

  select coalesce(sum(minutes),0), coalesce(sum(montant),0), count(*)
    into m_min, m_eur, m_days from entries where to_char(date,'YYYY-MM') = mk;

  perform send_mail('quotidien', 'Bonjour ' || prenom || ', tes horaires d''aujourd''hui ?',
    mail_shell('Bonjour ' || prenom || ' 👋',
      '<p style="margin:0 0 14px;">Quels sont tes horaires <b>aujourd''hui</b> (' || jour || ') ?</p>'
      || '<p style="margin:0 0 18px;color:#6B6385;">Ça prend 10 secondes : clique sur le bouton, puis note ton début et ta fin.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>'
      || '<td bgcolor="#FFF4D6" style="background:#FFF4D6;border-radius:16px;padding:14px 16px;font-family:Arial,Helvetica,sans-serif;">'
      || '<div style="font-size:13px;color:#6B6385;">Ta tirelire ce mois-ci 🐷</div>'
      || '<div style="font-size:24px;font-weight:bold;color:#231942;">' || eur(m_eur) || '</div>'
      || '<div style="font-size:13px;color:#6B6385;">' || fmt_h(m_min) || ' · ' || m_days || ' jour' || case when m_days > 1 then 's' else '' end || ' (' || rate::int || ' €/h)</div>'
      || '</td></tr></table>',
      'Noter mes heures',
      'Bonjour ' || prenom || ', quels sont tes horaires aujourd''hui ?'));
end $$;

-- ───────────── Clôture : dernier jour du mois (calendrier), avec le détail ─────────────
create or replace function public.cloture_mois(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  k text := to_char(d, 'YYYY-MM');
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  prenom text := coalesce(nullif(cfg('prenom'),''), '');
  tot_m int; tot_e numeric; n int;
  mois text := fr_mois(d) || ' ' || extract(year from d)::int;
  rows_html text := '';
  r record;
  last_w date := null;
begin
  if not force then
    if not est_heure_envoi() then return; end if;
    -- dernier jour du mois : demain est le 1er (28, 29, 30 ou 31 selon le calendrier)
    if (d + 1) <> date_trunc('month', d + 1)::date then return; end if;
    if exists (select 1 from months where month = k and statut = 'paye') then return; end if;
  end if;

  select coalesce(sum(minutes),0), coalesce(sum(montant),0), count(*)
    into tot_m, tot_e, n from entries where to_char(date,'YYYY-MM') = k;

  for r in
    select e.date, e.minutes, e.montant, e.debut, e.fin,
           date_trunc('week', e.date)::date as w,
           sum(e.minutes) over (partition by date_trunc('week', e.date)) as wm,
           sum(e.montant) over (partition by date_trunc('week', e.date)) as we,
           count(*)       over (partition by date_trunc('week', e.date)) as wn
    from entries e where to_char(e.date,'YYYY-MM') = k order by e.date
  loop
    if last_w is distinct from r.w then
      last_w := r.w;
      rows_html := rows_html
        || '<tr><td colspan="3" bgcolor="#EFEAFB" style="background:#EFEAFB;padding:8px 12px;font-size:13px;font-weight:bold;color:#6B6385;border-radius:10px;">'
        || 'Semaine du ' || extract(day from r.w)::int || ' ' || fr_mois(r.w)
        || ' · ' || r.wn || ' j · ' || fmt_h(r.wm::int) || ' · ' || eur(r.we) || '</td></tr>';
    end if;
    rows_html := rows_html
      || '<tr>'
      || '<td style="padding:9px 0;border-bottom:1px dashed #E4DEF3;font-size:15px;">' || fr_jour(r.date) || ' ' || extract(day from r.date)::int
      || '<div style="font-size:12px;color:#6B6385;">'
      || case when r.debut is not null then replace(r.debut,':','h') || ' – ' || replace(r.fin,':','h') else 'Durée choisie' end
      || '</div></td>'
      || '<td align="right" style="padding:9px 0;border-bottom:1px dashed #E4DEF3;font-size:15px;white-space:nowrap;">' || fmt_h(r.minutes) || '</td>'
      || '<td align="right" style="padding:9px 0 9px 12px;border-bottom:1px dashed #E4DEF3;font-size:15px;font-weight:bold;white-space:nowrap;">' || eur(r.montant) || '</td>'
      || '</tr>';
  end loop;

  if n = 0 then rows_html := '<tr><td style="padding:12px 0;color:#6B6385;">Aucune heure saisie ce mois-ci.</td></tr>'; end if;

  perform send_mail('cloture', 'Clôture ton mois : ' || mois,
    mail_shell('C''est la fin du mois 🐷',
      '<p style="margin:0 0 16px;">Bonjour ' || prenom || ', voici tes horaires de <b>' || mois || '</b>. Vérifie-les puis clôture ton dossier.</p>'
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

-- ───────────── Planification : 21h30 Paris = 19h30 UTC (été) ou 20h30 UTC (hiver) ─────────────
select cron.schedule('rappel-quotidien', '30 19,20 * * *',      $$select public.rappel_quotidien()$$);
select cron.schedule('cloture-mois',     '30 19,20 28-31 * *',  $$select public.cloture_mois()$$);
