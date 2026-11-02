-- Ferme l'accès direct aux tables : tout passe par les fonctions app_* (code obligatoire).
drop policy if exists entries_select on public.entries;
drop policy if exists entries_insert on public.entries;
drop policy if exists entries_update on public.entries;
drop policy if exists entries_delete on public.entries;
drop policy if exists months_select  on public.months;
drop policy if exists months_insert  on public.months;
drop policy if exists months_update  on public.months;
revoke all on public.entries from anon;
revoke all on public.months  from anon;
