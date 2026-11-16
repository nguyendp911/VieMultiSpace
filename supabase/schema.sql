-- =====================================================================
-- Trao đổi reaction (Reaction Exchange) - Supabase schema  (v2)
-- Mô hình: MỘT yêu cầu có thể được NHIỀU người nhận. Mỗi lượt nhận tạo
-- một "cặp" riêng giữa chủ yêu cầu và người nhận, không giới hạn số cặp.
--
-- Cách dùng: Supabase Dashboard > SQL Editor > dán toàn bộ file này > Run.
-- (An toàn khi chạy lại: file xóa bản v1 cũ và dữ liệu thử nghiệm của nó.)
-- Bật thêm: Authentication > Sign In / Providers > "Allow anonymous sign-ins".
--
-- Máy chủ CHỈ lưu và ghép. Không bao giờ nhận cookie / token Facebook.
-- Việc thả reaction do app trên máy mỗi người làm.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---- dọn bản v1 -----------------------------------------------------
drop function if exists public.create_exchange_request(text,text,text,text);
drop function if exists public.list_waiting_requests();
drop function if exists public.accept_exchange_request(uuid,text,text,text,text);
drop function if exists public.get_my_exchanges();
drop function if exists public.report_exchange_task(uuid,boolean,text);
drop function if exists public.cancel_exchange_request(uuid);
drop function if exists public.list_open_requests();
drop function if exists public.get_my_requests();
drop table if exists public.exchange_pairs cascade;
drop table if exists public.exchange_requests cascade;

-- ---- bảng yêu cầu (bài viết cần nhận reaction) ------------------------
create table public.exchange_requests (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'Ẩn danh',
  post_url     text not null,
  post_id      text not null,
  -- reaction mà chủ yêu cầu muốn NHẬN trên bài của mình
  reaction     text not null check (reaction in ('LIKE','LOVE','CARE','HAHA','WOW','SAD','ANGER')),
  status       text not null default 'open' check (status in ('open','cancelled','expired')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '24 hours',
  constraint exchange_post_id_format check (post_id ~ '^[A-Za-z0-9_.\-]{5,200}$'),
  constraint exchange_post_url_format check (post_url ~* '^https://([a-z0-9-]+\.)?(facebook\.com|fb\.com|fb\.watch)/')
);

create index exchange_requests_open_idx on public.exchange_requests (status, expires_at, created_at);
create index exchange_requests_owner_idx on public.exchange_requests (owner_id, created_at desc);

-- ---- bảng cặp (mỗi lượt nhận = 1 cặp) -------------------------------
create table public.exchange_pairs (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references public.exchange_requests(id) on delete cascade,
  a_owner       uuid not null references auth.users(id) on delete cascade, -- chủ yêu cầu
  b_owner       uuid not null references auth.users(id) on delete cascade, -- người nhận
  b_display_name text not null default 'Ẩn danh',
  b_post_url    text not null,
  b_post_id     text not null,
  b_reaction    text not null check (b_reaction in ('LIKE','LOVE','CARE','HAHA','WOW','SAD','ANGER')),
  -- A thả b_reaction lên bài của B
  a_task_status  text not null default 'pending' check (a_task_status in ('pending','done','failed')),
  a_task_message text,
  -- B thả reaction của yêu cầu lên bài của A
  b_task_status  text not null default 'pending' check (b_task_status in ('pending','done','failed')),
  b_task_message text,
  status        text not null default 'matched' check (status in ('matched','done')),
  created_at    timestamptz not null default now(),
  unique (request_id, b_owner),
  constraint exchange_b_post_id_format check (b_post_id ~ '^[A-Za-z0-9_.\-]{5,200}$'),
  constraint exchange_b_post_url_format check (b_post_url ~* '^https://([a-z0-9-]+\.)?(facebook\.com|fb\.com|fb\.watch)/')
);

create index exchange_pairs_a_idx on public.exchange_pairs (a_owner, created_at desc);
create index exchange_pairs_b_idx on public.exchange_pairs (b_owner, created_at desc);

-- Khóa toàn bộ truy cập trực tiếp; mọi thao tác đi qua các hàm RPC bên dưới.
alter table public.exchange_requests enable row level security;
alter table public.exchange_pairs enable row level security;
revoke all on public.exchange_requests from anon, authenticated;
revoke all on public.exchange_pairs from anon, authenticated;

-- ---------------------------------------------------------------------
-- Tạo yêu cầu (mở cho nhiều người nhận)
-- ---------------------------------------------------------------------
create function public.create_exchange_request(
  p_post_url text, p_post_id text, p_reaction text, p_display_name text
) returns public.exchange_requests
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  result_row public.exchange_requests;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  update public.exchange_requests set status = 'expired'
   where status = 'open' and expires_at < now();

  -- Không đăng trùng cùng một bài khi yêu cầu cũ còn mở
  if exists (select 1 from public.exchange_requests
              where owner_id = uid and post_id = p_post_id and status = 'open') then
    raise exception 'DUPLICATE_POST';
  end if;

  insert into public.exchange_requests (owner_id, display_name, post_url, post_id, reaction)
  values (uid,
          left(coalesce(nullif(trim(p_display_name), ''), 'Ẩn danh'), 40),
          p_post_url, p_post_id, upper(p_reaction))
  returning * into result_row;
  return result_row;
end $$;

-- ---------------------------------------------------------------------
-- Các yêu cầu đang mở của người khác (bạn chưa nhận, không lộ owner_id)
-- ---------------------------------------------------------------------
create function public.list_open_requests()
returns table (
  id uuid, display_name text, post_url text, reaction text,
  created_at timestamptz, expires_at timestamptz, accepted_count bigint
)
language sql security definer set search_path = public stable
as $$
  select r.id, r.display_name, r.post_url, r.reaction, r.created_at, r.expires_at,
         (select count(*) from public.exchange_pairs p where p.request_id = r.id)
    from public.exchange_requests r
   where r.status = 'open'
     and r.expires_at > now()
     and r.owner_id <> auth.uid()
     and not exists (select 1 from public.exchange_pairs p
                      where p.request_id = r.id and p.b_owner = auth.uid())
   order by r.created_at desc
   limit 100;
$$;

-- ---------------------------------------------------------------------
-- Nhận một yêu cầu + gửi bài của mình => tạo cặp ngay, không giới hạn số người nhận
-- ---------------------------------------------------------------------
create function public.accept_exchange_request(
  p_target_id uuid, p_post_url text, p_post_id text, p_reaction text, p_display_name text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target public.exchange_requests;
  new_pair uuid;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into target from public.exchange_requests where id = p_target_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if target.status <> 'open' then raise exception 'CLOSED'; end if;
  if target.expires_at < now() then raise exception 'EXPIRED'; end if;
  if target.owner_id = uid then raise exception 'OWN_REQUEST'; end if;
  if target.post_id = p_post_id then raise exception 'SAME_POST'; end if;

  begin
    insert into public.exchange_pairs
      (request_id, a_owner, b_owner, b_display_name, b_post_url, b_post_id, b_reaction)
    values (target.id, target.owner_id, uid,
            left(coalesce(nullif(trim(p_display_name), ''), 'Ẩn danh'), 40),
            p_post_url, p_post_id, upper(p_reaction))
    returning id into new_pair;
  exception when unique_violation then
    raise exception 'ALREADY_ACCEPTED';
  end;

  return new_pair;
end $$;

-- ---------------------------------------------------------------------
-- Yêu cầu của tôi (kèm số người đã nhận)
-- ---------------------------------------------------------------------
create function public.get_my_requests()
returns table (
  id uuid, status text, post_url text, reaction text,
  created_at timestamptz, expires_at timestamptz, accepted_count bigint
)
language sql security definer set search_path = public stable
as $$
  select r.id,
         case when r.status = 'open' and r.expires_at < now() then 'expired' else r.status end,
         r.post_url, r.reaction, r.created_at, r.expires_at,
         (select count(*) from public.exchange_pairs p where p.request_id = r.id)
    from public.exchange_requests r
   where r.owner_id = auth.uid()
   order by r.created_at desc
   limit 50;
$$;

-- ---------------------------------------------------------------------
-- Các lượt trao đổi của tôi (cả khi tôi là chủ yêu cầu lẫn người nhận)
-- Tất cả đều nhìn từ phía "tôi": my_* là của tôi, partner_* là của đối tác.
-- ---------------------------------------------------------------------
create function public.get_my_pairs()
returns table (
  id uuid, role text, status text, created_at timestamptz,
  my_post_url text, my_reaction text,
  partner_display_name text, partner_post_url text, partner_post_id text, partner_reaction text,
  my_task_status text, my_task_message text, partner_task_status text
)
language sql security definer set search_path = public stable
as $$
  (select p.id, 'requester', p.status, p.created_at,
          r.post_url, r.reaction,
          p.b_display_name, p.b_post_url, p.b_post_id, p.b_reaction,
          p.a_task_status, p.a_task_message, p.b_task_status
     from public.exchange_pairs p
     join public.exchange_requests r on r.id = p.request_id
    where p.a_owner = auth.uid())
  union all
  (select p.id, 'accepter', p.status, p.created_at,
          p.b_post_url, p.b_reaction,
          r.display_name, r.post_url, r.post_id, r.reaction,
          p.b_task_status, p.b_task_message, p.a_task_status
     from public.exchange_pairs p
     join public.exchange_requests r on r.id = p.request_id
    where p.b_owner = auth.uid())
  order by created_at desc
  limit 100;
$$;

-- ---------------------------------------------------------------------
-- Báo kết quả thả reaction của tôi trong một cặp
-- ---------------------------------------------------------------------
create function public.report_exchange_task(
  p_pair_id uuid, p_success boolean, p_message text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pr public.exchange_pairs;
  new_status text := case when p_success then 'done' else 'failed' end;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into pr from public.exchange_pairs
   where id = p_pair_id and (a_owner = uid or b_owner = uid) for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if pr.a_owner = uid then
    if pr.a_task_status <> 'pending' then return; end if;
    update public.exchange_pairs
       set a_task_status = new_status, a_task_message = left(p_message, 300)
     where id = pr.id;
    pr.a_task_status := new_status;
  else
    if pr.b_task_status <> 'pending' then return; end if;
    update public.exchange_pairs
       set b_task_status = new_status, b_task_message = left(p_message, 300)
     where id = pr.id;
    pr.b_task_status := new_status;
  end if;

  if pr.a_task_status <> 'pending' and pr.b_task_status <> 'pending' then
    update public.exchange_pairs set status = 'done' where id = pr.id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Đóng yêu cầu (các cặp đã tạo vẫn tiếp tục)
-- ---------------------------------------------------------------------
create function public.cancel_exchange_request(p_request_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update public.exchange_requests set status = 'cancelled'
   where id = p_request_id and owner_id = auth.uid() and status = 'open';
$$;

revoke all on function public.create_exchange_request(text,text,text,text) from public, anon;
revoke all on function public.list_open_requests() from public, anon;
revoke all on function public.accept_exchange_request(uuid,text,text,text,text) from public, anon;
revoke all on function public.get_my_requests() from public, anon;
revoke all on function public.get_my_pairs() from public, anon;
revoke all on function public.report_exchange_task(uuid,boolean,text) from public, anon;
revoke all on function public.cancel_exchange_request(uuid) from public, anon;

grant execute on function public.create_exchange_request(text,text,text,text) to authenticated;
grant execute on function public.list_open_requests() to authenticated;
grant execute on function public.accept_exchange_request(uuid,text,text,text,text) to authenticated;
grant execute on function public.get_my_requests() to authenticated;
grant execute on function public.get_my_pairs() to authenticated;
grant execute on function public.report_exchange_task(uuid,boolean,text) to authenticated;
grant execute on function public.cancel_exchange_request(uuid) to authenticated;
