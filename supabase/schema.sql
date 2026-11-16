-- =====================================================================
-- Trao đổi reaction (Reaction Exchange) - Supabase schema
-- Cách dùng: Supabase Dashboard > SQL Editor > dán toàn bộ file này > Run.
-- Bật thêm: Authentication > Sign In / Providers > "Allow anonymous sign-ins".
--
-- Nguyên tắc: máy chủ CHỈ lưu yêu cầu và ghép cặp. Không bao giờ nhận
-- cookie / token Facebook. Việc thả reaction do app trên máy mỗi người làm.
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists public.exchange_requests (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'Ẩn danh',
  post_url     text not null,
  post_id      text not null,
  -- reaction mà CHỦ yêu cầu muốn NHẬN trên bài của mình
  reaction     text not null check (reaction in ('LIKE','LOVE','CARE','HAHA','WOW','SAD','ANGER')),
  status       text not null default 'waiting'
               check (status in ('waiting','matched','done','cancelled','expired')),
  partner_id   uuid references public.exchange_requests(id),
  -- việc của chủ yêu cầu: thả reaction của đối tác lên bài của đối tác
  task_status  text not null default 'pending' check (task_status in ('pending','done','failed')),
  task_message text,
  task_done_at timestamptz,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '24 hours',
  matched_at   timestamptz,
  constraint exchange_post_id_format check (post_id ~ '^[A-Za-z0-9_.\-]{5,200}$'),
  constraint exchange_post_url_format check (post_url ~* '^https://([a-z0-9-]+\.)?(facebook\.com|fb\.com|fb\.watch)/')
);

create index if not exists exchange_requests_waiting_idx
  on public.exchange_requests (status, expires_at, created_at);
create index if not exists exchange_requests_owner_idx
  on public.exchange_requests (owner_id, created_at desc);

alter table public.exchange_requests enable row level security;

-- Chỉ chủ sở hữu đọc được hàng của mình. Mọi ghi/đọc khác đi qua hàm RPC bên dưới.
drop policy if exists "owner can read own requests" on public.exchange_requests;
create policy "owner can read own requests"
  on public.exchange_requests for select
  to authenticated
  using (owner_id = auth.uid());

revoke all on public.exchange_requests from anon, authenticated;
grant select on public.exchange_requests to authenticated;

-- ---------------------------------------------------------------------
-- Tạo yêu cầu mới (trạng thái chờ)
-- ---------------------------------------------------------------------
create or replace function public.create_exchange_request(
  p_post_url text,
  p_post_id text,
  p_reaction text,
  p_display_name text
) returns public.exchange_requests
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  result_row public.exchange_requests;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  update public.exchange_requests
     set status = 'expired'
   where status = 'waiting' and expires_at < now();

  if exists (select 1 from public.exchange_requests
              where owner_id = uid and status = 'waiting') then
    raise exception 'ALREADY_WAITING';
  end if;

  if (select count(*) from public.exchange_requests
       where owner_id = uid and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'DAILY_LIMIT';
  end if;

  insert into public.exchange_requests (owner_id, display_name, post_url, post_id, reaction)
  values (uid,
          left(coalesce(nullif(trim(p_display_name), ''), 'Ẩn danh'), 40),
          p_post_url, p_post_id, upper(p_reaction))
  returning * into result_row;

  return result_row;
end $$;

-- ---------------------------------------------------------------------
-- Danh sách yêu cầu đang chờ của người khác (không lộ owner_id)
-- ---------------------------------------------------------------------
create or replace function public.list_waiting_requests()
returns table (
  id uuid, display_name text, post_url text, reaction text, created_at timestamptz
)
language sql security definer set search_path = public stable
as $$
  select r.id, r.display_name, r.post_url, r.reaction, r.created_at
    from public.exchange_requests r
   where r.status = 'waiting'
     and r.expires_at > now()
     and r.owner_id <> auth.uid()
   order by r.created_at asc
   limit 50;
$$;

-- ---------------------------------------------------------------------
-- Nhận một yêu cầu đang chờ + gửi yêu cầu của mình => ghép cặp ngay
-- ---------------------------------------------------------------------
create or replace function public.accept_exchange_request(
  p_target_id uuid,
  p_post_url text,
  p_post_id text,
  p_reaction text,
  p_display_name text
) returns public.exchange_requests
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target public.exchange_requests;
  mine public.exchange_requests;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  -- Khóa hàng đích để hai người không nhận trùng một yêu cầu
  select * into target from public.exchange_requests
   where id = p_target_id for update;

  if not found then raise exception 'NOT_FOUND'; end if;
  if target.status <> 'waiting' then raise exception 'ALREADY_TAKEN'; end if;
  if target.expires_at < now() then
    update public.exchange_requests set status = 'expired' where id = target.id;
    raise exception 'EXPIRED';
  end if;
  if target.owner_id = uid then raise exception 'OWN_REQUEST'; end if;
  if target.post_id = p_post_id then raise exception 'SAME_POST'; end if;

  if (select count(*) from public.exchange_requests
       where owner_id = uid and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'DAILY_LIMIT';
  end if;
  if (select count(*) from public.exchange_requests
       where owner_id = uid and status in ('waiting','matched')) >= 3 then
    raise exception 'TOO_MANY_ACTIVE';
  end if;

  insert into public.exchange_requests
    (owner_id, display_name, post_url, post_id, reaction, status, partner_id, matched_at)
  values (uid,
          left(coalesce(nullif(trim(p_display_name), ''), 'Ẩn danh'), 40),
          p_post_url, p_post_id, upper(p_reaction), 'matched', target.id, now())
  returning * into mine;

  update public.exchange_requests
     set status = 'matched', partner_id = mine.id, matched_at = now()
   where id = target.id;

  return mine;
end $$;

-- ---------------------------------------------------------------------
-- Các yêu cầu của tôi (kèm thông tin đối tác cần để thực thi)
-- ---------------------------------------------------------------------
create or replace function public.get_my_exchanges()
returns table (
  id uuid, status text, post_url text, post_id text, reaction text,
  display_name text, created_at timestamptz, expires_at timestamptz,
  task_status text, task_message text,
  partner_display_name text, partner_post_url text, partner_post_id text,
  partner_reaction text, partner_task_status text
)
language sql security definer set search_path = public stable
as $$
  select r.id, r.status, r.post_url, r.post_id, r.reaction,
         r.display_name, r.created_at, r.expires_at,
         r.task_status, r.task_message,
         p.display_name, p.post_url, p.post_id,
         p.reaction, p.task_status
    from public.exchange_requests r
    left join public.exchange_requests p on p.id = r.partner_id
   where r.owner_id = auth.uid()
   order by r.created_at desc
   limit 50;
$$;

-- ---------------------------------------------------------------------
-- Báo kết quả thả reaction của tôi
-- ---------------------------------------------------------------------
create or replace function public.report_exchange_task(
  p_request_id uuid,
  p_success boolean,
  p_message text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  mine public.exchange_requests;
  theirs public.exchange_requests;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into mine from public.exchange_requests
   where id = p_request_id and owner_id = uid for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if mine.status <> 'matched' or mine.task_status <> 'pending' then return; end if;

  update public.exchange_requests
     set task_status = case when p_success then 'done' else 'failed' end,
         task_message = left(p_message, 300),
         task_done_at = now()
   where id = mine.id;

  select * into theirs from public.exchange_requests where id = mine.partner_id;
  if found and theirs.task_status <> 'pending' then
    update public.exchange_requests set status = 'done'
     where id in (mine.id, theirs.id);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Hủy yêu cầu đang chờ
-- ---------------------------------------------------------------------
create or replace function public.cancel_exchange_request(p_request_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update public.exchange_requests
     set status = 'cancelled'
   where id = p_request_id and owner_id = auth.uid() and status = 'waiting';
$$;

revoke all on function public.create_exchange_request(text,text,text,text) from public, anon;
revoke all on function public.list_waiting_requests() from public, anon;
revoke all on function public.accept_exchange_request(uuid,text,text,text,text) from public, anon;
revoke all on function public.get_my_exchanges() from public, anon;
revoke all on function public.report_exchange_task(uuid,boolean,text) from public, anon;
revoke all on function public.cancel_exchange_request(uuid) from public, anon;

grant execute on function public.create_exchange_request(text,text,text,text) to authenticated;
grant execute on function public.list_waiting_requests() to authenticated;
grant execute on function public.accept_exchange_request(uuid,text,text,text,text) to authenticated;
grant execute on function public.get_my_exchanges() to authenticated;
grant execute on function public.report_exchange_task(uuid,boolean,text) to authenticated;
grant execute on function public.cancel_exchange_request(uuid) to authenticated;
