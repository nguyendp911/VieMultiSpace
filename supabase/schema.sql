-- =====================================================================
-- Trao đổi reaction (Reaction Exchange) - Supabase schema  (v3)
--
-- v3 thêm: điểm uy tín, xác minh reaction thật, báo cáo/chặn, nhóm riêng (mã mời).
-- Chạy được trên cả DB trống lẫn DB đã chạy v2: GIỮ NGUYÊN dữ liệu cũ,
-- chỉ thêm cột/bảng mới và tạo lại các hàm RPC.
--
-- Cách dùng: Supabase Dashboard > SQL Editor > dán toàn bộ file này > Run.
-- Bật thêm: Authentication > Sign In / Providers > "Allow anonymous sign-ins".
--
-- Máy chủ CHỈ lưu và ghép. Không bao giờ nhận cookie / token Facebook.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---- dọn các hàm cũ (tạo lại ở cuối file) ---------------------------
drop function if exists public.create_exchange_request(text,text,text,text);
drop function if exists public.create_exchange_request(text,text,text,text,uuid);
drop function if exists public.list_waiting_requests();
drop function if exists public.list_open_requests();
drop function if exists public.list_open_requests(uuid);
drop function if exists public.accept_exchange_request(uuid,text,text,text,text);
drop function if exists public.get_my_exchanges();
drop function if exists public.get_my_requests();
drop function if exists public.get_my_pairs();
drop function if exists public.report_exchange_task(uuid,boolean,text);
drop function if exists public.report_exchange_task(uuid,boolean,text,text);
drop function if exists public.cancel_exchange_request(uuid);
drop function if exists public.report_verification(uuid,boolean);
drop function if exists public.report_request(uuid,text);
drop function if exists public.block_request_owner(uuid);
drop function if exists public.clear_my_blocks();
drop function if exists public.create_exchange_group(text);
drop function if exists public.join_exchange_group(text);
drop function if exists public.get_my_groups();
drop function if exists public.leave_exchange_group(uuid);
drop function if exists public.get_my_reputation();

-- ---- bảng nhóm riêng ------------------------------------------------
create table if not exists public.exchange_groups (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  code       text not null unique,
  owner_id   uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.exchange_group_members (
  group_id  uuid not null references public.exchange_groups(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- ---- bảng yêu cầu ---------------------------------------------------
create table if not exists public.exchange_requests (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'Ẩn danh',
  post_url     text not null,
  post_id      text not null,
  reaction     text not null check (reaction in ('LIKE','LOVE','CARE','HAHA','WOW','SAD','ANGER')),
  status       text not null default 'open' check (status in ('open','cancelled','expired')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '24 hours',
  constraint exchange_post_id_format check (post_id ~ '^[A-Za-z0-9_.\-]{5,200}$'),
  constraint exchange_post_url_format check (post_url ~* '^https://([a-z0-9-]+\.)?(facebook\.com|fb\.com|fb\.watch)/')
);
alter table public.exchange_requests add column if not exists group_id uuid references public.exchange_groups(id) on delete cascade;
alter table public.exchange_requests add column if not exists report_count int not null default 0;

create index if not exists exchange_requests_open_idx on public.exchange_requests (status, expires_at, created_at);
create index if not exists exchange_requests_owner_idx on public.exchange_requests (owner_id, created_at desc);

-- ---- bảng cặp -------------------------------------------------------
create table if not exists public.exchange_pairs (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references public.exchange_requests(id) on delete cascade,
  a_owner       uuid not null references auth.users(id) on delete cascade, -- chủ yêu cầu
  b_owner       uuid not null references auth.users(id) on delete cascade, -- người nhận
  b_display_name text not null default 'Ẩn danh',
  b_post_url    text not null,
  b_post_id     text not null,
  b_reaction    text not null check (b_reaction in ('LIKE','LOVE','CARE','HAHA','WOW','SAD','ANGER')),
  a_task_status  text not null default 'pending' check (a_task_status in ('pending','done','failed')),
  a_task_message text,
  b_task_status  text not null default 'pending' check (b_task_status in ('pending','done','failed')),
  b_task_message text,
  status        text not null default 'matched' check (status in ('matched','done')),
  created_at    timestamptz not null default now(),
  unique (request_id, b_owner),
  constraint exchange_b_post_id_format check (b_post_id ~ '^[A-Za-z0-9_.\-]{5,200}$'),
  constraint exchange_b_post_url_format check (b_post_url ~* '^https://([a-z0-9-]+\.)?(facebook\.com|fb\.com|fb\.watch)/')
);
-- uid Facebook của người thả (để bên kia kiểm tra reaction thật) + kết quả kiểm tra
alter table public.exchange_pairs add column if not exists a_actor_uid text;
alter table public.exchange_pairs add column if not exists b_actor_uid text;
alter table public.exchange_pairs add column if not exists a_task_verify text not null default 'unknown'
  check (a_task_verify in ('unknown','ok','missing'));
alter table public.exchange_pairs add column if not exists b_task_verify text not null default 'unknown'
  check (b_task_verify in ('unknown','ok','missing'));

create index if not exists exchange_pairs_a_idx on public.exchange_pairs (a_owner, created_at desc);
create index if not exists exchange_pairs_b_idx on public.exchange_pairs (b_owner, created_at desc);

-- ---- uy tín, chặn, báo cáo -----------------------------------------
create table if not exists public.exchange_reputation (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  score         int not null default 100,
  done_count    int not null default 0,
  failed_count  int not null default 0,
  missing_count int not null default 0,
  updated_at    timestamptz not null default now()
);

create table if not exists public.exchange_blocks (
  user_id    uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, blocked_id)
);

create table if not exists public.exchange_reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  request_id  uuid not null references public.exchange_requests(id) on delete cascade,
  reason      text,
  created_at  timestamptz not null default now(),
  unique (reporter_id, request_id)
);

-- Khóa truy cập trực tiếp; mọi thao tác đi qua RPC (security definer).
alter table public.exchange_groups enable row level security;
alter table public.exchange_group_members enable row level security;
alter table public.exchange_requests enable row level security;
alter table public.exchange_pairs enable row level security;
alter table public.exchange_reputation enable row level security;
alter table public.exchange_blocks enable row level security;
alter table public.exchange_reports enable row level security;
revoke all on public.exchange_groups, public.exchange_group_members, public.exchange_requests,
  public.exchange_pairs, public.exchange_reputation, public.exchange_blocks, public.exchange_reports
  from anon, authenticated;
-- (bản v1 từng có policy đọc bảng; bỏ đi cho gọn)
drop policy if exists "owner can read own requests" on public.exchange_requests;

-- ---------------------------------------------------------------------
-- Hàm nội bộ: điểm uy tín (không cấp quyền cho client)
-- ---------------------------------------------------------------------
create or replace function public.exchange_score(p_user uuid)
returns int language sql security definer set search_path = public stable
as $$
  select coalesce((select rp.score from public.exchange_reputation rp where rp.user_id = p_user), 100);
$$;

create or replace function public.exchange_bump(
  p_user uuid, p_score int, p_done int, p_failed int, p_missing int
) returns void language sql security definer set search_path = public
as $$
  insert into public.exchange_reputation as rp (user_id, score, done_count, failed_count, missing_count)
  values (p_user, greatest(0, least(200, 100 + p_score)), p_done, p_failed, p_missing)
  on conflict (user_id) do update
    set score = greatest(0, least(200, rp.score + p_score)),
        done_count = rp.done_count + p_done,
        failed_count = rp.failed_count + p_failed,
        missing_count = rp.missing_count + p_missing,
        updated_at = now();
$$;

revoke all on function public.exchange_score(uuid) from public, anon, authenticated;
revoke all on function public.exchange_bump(uuid,int,int,int,int) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Tạo yêu cầu (công khai hoặc trong một nhóm riêng)
-- ---------------------------------------------------------------------
create function public.create_exchange_request(
  p_post_url text, p_post_id text, p_reaction text, p_display_name text,
  p_group_id uuid default null
) returns public.exchange_requests
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  result_row public.exchange_requests;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if public.exchange_score(uid) < 40 then raise exception 'LOW_REPUTATION'; end if;

  if p_group_id is not null and not exists (
      select 1 from public.exchange_group_members m
       where m.group_id = p_group_id and m.user_id = uid) then
    raise exception 'NOT_IN_GROUP';
  end if;

  update public.exchange_requests set status = 'expired'
   where status = 'open' and expires_at < now();

  if exists (select 1 from public.exchange_requests r
              where r.owner_id = uid and r.post_id = p_post_id and r.status = 'open') then
    raise exception 'DUPLICATE_POST';
  end if;

  insert into public.exchange_requests (owner_id, display_name, post_url, post_id, reaction, group_id)
  values (uid,
          left(coalesce(nullif(trim(p_display_name), ''), 'Ẩn danh'), 40),
          p_post_url, p_post_id, upper(p_reaction), p_group_id)
  returning * into result_row;
  return result_row;
end $$;

-- ---------------------------------------------------------------------
-- Yêu cầu đang mở của người khác. p_group null = công khai, có giá trị = trong nhóm đó.
-- Ẩn: yêu cầu bạn đã nhận, người bạn đã chặn, yêu cầu bị báo cáo >= 3 lần, người uy tín thấp.
-- ---------------------------------------------------------------------
create function public.list_open_requests(p_group uuid default null)
returns table (
  id uuid, display_name text, post_url text, reaction text,
  created_at timestamptz, expires_at timestamptz, accepted_count bigint, owner_score int
)
language sql security definer set search_path = public stable
as $$
  select r.id, r.display_name, r.post_url, r.reaction, r.created_at, r.expires_at,
         (select count(*) from public.exchange_pairs p where p.request_id = r.id),
         public.exchange_score(r.owner_id)
    from public.exchange_requests r
   where r.status = 'open'
     and r.expires_at > now()
     and r.owner_id <> auth.uid()
     and r.report_count < 3
     and public.exchange_score(r.owner_id) >= 40
     and not exists (select 1 from public.exchange_pairs p
                      where p.request_id = r.id and p.b_owner = auth.uid())
     and not exists (select 1 from public.exchange_blocks b
                      where b.user_id = auth.uid() and b.blocked_id = r.owner_id)
     and (
          (p_group is null and r.group_id is null)
       or (p_group is not null and r.group_id = p_group and exists (
             select 1 from public.exchange_group_members m
              where m.group_id = p_group and m.user_id = auth.uid()))
     )
   order by public.exchange_score(r.owner_id) desc, r.created_at desc
   limit 100;
$$;

-- ---------------------------------------------------------------------
-- Nhận một yêu cầu: tạo cặp ngay, không giới hạn số người nhận
-- ---------------------------------------------------------------------
create function public.accept_exchange_request(
  p_target_id uuid, p_post_url text, p_post_id text, p_reaction text, p_display_name text
) returns uuid
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  target public.exchange_requests;
  new_pair uuid;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if public.exchange_score(uid) < 40 then raise exception 'LOW_REPUTATION'; end if;

  select * into target from public.exchange_requests r where r.id = p_target_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if target.status <> 'open' then raise exception 'CLOSED'; end if;
  if target.expires_at < now() then raise exception 'EXPIRED'; end if;
  if target.owner_id = uid then raise exception 'OWN_REQUEST'; end if;
  if target.post_id = p_post_id then raise exception 'SAME_POST'; end if;

  if target.group_id is not null and not exists (
      select 1 from public.exchange_group_members m
       where m.group_id = target.group_id and m.user_id = uid) then
    raise exception 'NOT_IN_GROUP';
  end if;

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
-- Yêu cầu của tôi
-- ---------------------------------------------------------------------
create function public.get_my_requests()
returns table (
  id uuid, status text, post_url text, reaction text,
  created_at timestamptz, expires_at timestamptz, accepted_count bigint, group_name text
)
language sql security definer set search_path = public stable
as $$
  select r.id,
         case when r.status = 'open' and r.expires_at < now() then 'expired' else r.status end,
         r.post_url, r.reaction, r.created_at, r.expires_at,
         (select count(*) from public.exchange_pairs p where p.request_id = r.id),
         (select g.name from public.exchange_groups g where g.id = r.group_id)
    from public.exchange_requests r
   where r.owner_id = auth.uid()
   order by r.created_at desc
   limit 50;
$$;

-- ---------------------------------------------------------------------
-- Các lượt trao đổi của tôi (nhìn từ phía tôi)
-- ---------------------------------------------------------------------
create function public.get_my_pairs()
returns table (
  id uuid, role text, status text, created_at timestamptz,
  my_post_url text, my_post_id text, my_reaction text,
  partner_display_name text, partner_post_url text, partner_post_id text, partner_reaction text,
  my_task_status text, my_task_message text, partner_task_status text,
  partner_actor_uid text, partner_verify text, my_verify text
)
language sql security definer set search_path = public stable
as $$
  (select p.id, 'requester', p.status, p.created_at,
          r.post_url, r.post_id, r.reaction,
          p.b_display_name, p.b_post_url, p.b_post_id, p.b_reaction,
          p.a_task_status, p.a_task_message, p.b_task_status,
          p.b_actor_uid, p.b_task_verify, p.a_task_verify
     from public.exchange_pairs p
     join public.exchange_requests r on r.id = p.request_id
    where p.a_owner = auth.uid())
  union all
  (select p.id, 'accepter', p.status, p.created_at,
          p.b_post_url, p.b_post_id, p.b_reaction,
          r.display_name, r.post_url, r.post_id, r.reaction,
          p.b_task_status, p.b_task_message, p.a_task_status,
          p.a_actor_uid, p.a_task_verify, p.b_task_verify
     from public.exchange_pairs p
     join public.exchange_requests r on r.id = p.request_id
    where p.b_owner = auth.uid())
  order by created_at desc
  limit 100;
$$;

-- ---------------------------------------------------------------------
-- Báo kết quả thả reaction của tôi (kèm uid Facebook của người thả)
-- ---------------------------------------------------------------------
create function public.report_exchange_task(
  p_pair_id uuid, p_success boolean, p_message text default null, p_actor_uid text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pr public.exchange_pairs;
  new_status text := case when p_success then 'done' else 'failed' end;
  actor text := nullif(left(regexp_replace(coalesce(p_actor_uid, ''), '[^0-9]', '', 'g'), 30), '');
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into pr from public.exchange_pairs
   where id = p_pair_id and (a_owner = uid or b_owner = uid) for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if pr.a_owner = uid then
    if pr.a_task_status <> 'pending' then return; end if;
    update public.exchange_pairs
       set a_task_status = new_status, a_task_message = left(p_message, 300), a_actor_uid = actor
     where id = pr.id;
    pr.a_task_status := new_status;
  else
    if pr.b_task_status <> 'pending' then return; end if;
    update public.exchange_pairs
       set b_task_status = new_status, b_task_message = left(p_message, 300), b_actor_uid = actor
     where id = pr.id;
    pr.b_task_status := new_status;
  end if;

  if p_success then
    perform public.exchange_bump(uid, 1, 1, 0, 0);
  else
    perform public.exchange_bump(uid, -3, 0, 1, 0);
  end if;

  if pr.a_task_status <> 'pending' and pr.b_task_status <> 'pending' then
    update public.exchange_pairs set status = 'done' where id = pr.id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Xác minh: tôi kiểm tra bài của mình và báo đối tác có thật sự thả reaction hay không
-- ---------------------------------------------------------------------
create function public.report_verification(p_pair_id uuid, p_ok boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pr public.exchange_pairs;
  partner uuid;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into pr from public.exchange_pairs
   where id = p_pair_id and (a_owner = uid or b_owner = uid) for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if pr.a_owner = uid then
    -- tôi là A: kiểm tra việc của B
    if pr.b_task_status <> 'done' or pr.b_task_verify <> 'unknown' then return; end if;
    update public.exchange_pairs set b_task_verify = case when p_ok then 'ok' else 'missing' end where id = pr.id;
    partner := pr.b_owner;
  else
    if pr.a_task_status <> 'done' or pr.a_task_verify <> 'unknown' then return; end if;
    update public.exchange_pairs set a_task_verify = case when p_ok then 'ok' else 'missing' end where id = pr.id;
    partner := pr.a_owner;
  end if;

  if p_ok then
    perform public.exchange_bump(partner, 1, 0, 0, 0);
  else
    perform public.exchange_bump(partner, -10, 0, 0, 1);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Đóng yêu cầu của tôi (các cặp đã tạo vẫn tiếp tục)
-- ---------------------------------------------------------------------
create function public.cancel_exchange_request(p_request_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update public.exchange_requests set status = 'cancelled'
   where id = p_request_id and owner_id = auth.uid() and status = 'open';
$$;

-- ---------------------------------------------------------------------
-- Báo cáo yêu cầu / chặn chủ yêu cầu
-- ---------------------------------------------------------------------
create function public.report_request(p_request_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid(); inserted int;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  insert into public.exchange_reports (reporter_id, request_id, reason)
  values (uid, p_request_id, left(p_reason, 200))
  on conflict (reporter_id, request_id) do nothing;
  get diagnostics inserted = row_count;
  if inserted > 0 then
    update public.exchange_requests set report_count = report_count + 1 where id = p_request_id;
  end if;
end $$;

create function public.block_request_owner(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid(); target uuid;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select r.owner_id into target from public.exchange_requests r where r.id = p_request_id;
  if target is null then raise exception 'NOT_FOUND'; end if;
  if target = uid then raise exception 'OWN_REQUEST'; end if;
  insert into public.exchange_blocks (user_id, blocked_id) values (uid, target)
  on conflict do nothing;
end $$;

create function public.clear_my_blocks()
returns void
language sql security definer set search_path = public
as $$
  delete from public.exchange_blocks where user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- Nhóm riêng (mã mời)
-- ---------------------------------------------------------------------
create function public.create_exchange_group(p_name text)
returns table (group_id uuid, group_name text, group_code text, member_count bigint, is_owner boolean)
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  new_id uuid;
  new_code text;
  tries int := 0;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'NAME_TOO_SHORT'; end if;
  if (select count(*) from public.exchange_groups g where g.owner_id = uid) >= 5 then
    raise exception 'TOO_MANY_GROUPS';
  end if;

  loop
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      insert into public.exchange_groups (name, code, owner_id)
      values (left(trim(p_name), 40), new_code, uid)
      returning exchange_groups.id into new_id;
      exit;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;

  insert into public.exchange_group_members (group_id, user_id) values (new_id, uid);
  return query select g.id, g.name, g.code, 1::bigint, true
                 from public.exchange_groups g where g.id = new_id;
end $$;

create function public.join_exchange_group(p_code text)
returns table (group_id uuid, group_name text, group_code text, member_count bigint, is_owner boolean)
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  g public.exchange_groups;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into g from public.exchange_groups x where x.code = upper(trim(p_code));
  if not found then raise exception 'GROUP_NOT_FOUND'; end if;
  insert into public.exchange_group_members (group_id, user_id) values (g.id, uid)
  on conflict do nothing;
  return query select g.id, g.name, g.code,
                      (select count(*) from public.exchange_group_members m where m.group_id = g.id),
                      g.owner_id = uid;
end $$;

create function public.get_my_groups()
returns table (group_id uuid, group_name text, group_code text, member_count bigint, is_owner boolean)
language sql security definer set search_path = public stable
as $$
  select g.id, g.name, g.code,
         (select count(*) from public.exchange_group_members m2 where m2.group_id = g.id),
         g.owner_id = auth.uid()
    from public.exchange_groups g
    join public.exchange_group_members m on m.group_id = g.id
   where m.user_id = auth.uid()
   order by m.joined_at desc;
$$;

create function public.leave_exchange_group(p_group_id uuid)
returns void
language sql security definer set search_path = public
as $$
  delete from public.exchange_group_members where group_id = p_group_id and user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- Điểm uy tín của tôi
-- ---------------------------------------------------------------------
create function public.get_my_reputation()
returns table (score int, done_count int, failed_count int, missing_count int)
language sql security definer set search_path = public stable
as $$
  select public.exchange_score(auth.uid()),
         coalesce((select rp.done_count from public.exchange_reputation rp where rp.user_id = auth.uid()), 0),
         coalesce((select rp.failed_count from public.exchange_reputation rp where rp.user_id = auth.uid()), 0),
         coalesce((select rp.missing_count from public.exchange_reputation rp where rp.user_id = auth.uid()), 0);
$$;

-- ---------------------------------------------------------------------
-- Phân quyền: chỉ người dùng đã đăng nhập (kể cả ẩn danh) được gọi RPC
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  for f in select unnest(array[
    'public.create_exchange_request(text,text,text,text,uuid)',
    'public.list_open_requests(uuid)',
    'public.accept_exchange_request(uuid,text,text,text,text)',
    'public.get_my_requests()',
    'public.get_my_pairs()',
    'public.report_exchange_task(uuid,boolean,text,text)',
    'public.report_verification(uuid,boolean)',
    'public.cancel_exchange_request(uuid)',
    'public.report_request(uuid,text)',
    'public.block_request_owner(uuid)',
    'public.clear_my_blocks()',
    'public.create_exchange_group(text)',
    'public.join_exchange_group(text)',
    'public.get_my_groups()',
    'public.leave_exchange_group(uuid)',
    'public.get_my_reputation()'
  ]) loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
