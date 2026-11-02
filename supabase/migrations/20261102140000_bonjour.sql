-- Rappel quotidien : "Bonjour <prénom>" + gros bouton vers l'app
insert into public.config(key, value) values ('prenom', 'Sarah') on conflict do nothing;

create or replace function public.rappel_quotidien(force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  p timestamp := now() at time zone 'Europe/Paris';
  d date := p::date;
  dow int := extract(isodow from p);
  rate numeric := coalesce(nullif(cfg('rate'),'')::numeric, 12);
  mk text := to_char(d, 'YYYY-MM');
  prenom text := coalesce(nullif(cfg('prenom'),''), '');
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

revoke all on function public.rappel_quotidien(boolean) from public, anon, authenticated;
