-- ============================================================
-- 애니노트 v1.10.0 DB 패치
-- 사격장 러시 · 계정별 최고기록 / TOP 10 / 기본 점수 검증
--
-- 게임 중에는 DB 요청이 없습니다.
-- 시작 1회 + 종료 1회(또는 포기 정리 1회)만 사용합니다.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. 최고 기록
-- ------------------------------------------------------------

create table if not exists public.sniper_rush_scores (
  user_id uuid primary key
    references auth.users(id) on delete cascade,

  best_score integer not null default 0
    check (best_score >= 0),

  best_accuracy numeric(5,2) not null default 0
    check (best_accuracy >= 0 and best_accuracy <= 100),

  best_headshots integer not null default 0
    check (best_headshots >= 0),

  best_combo integer not null default 0
    check (best_combo >= 0),

  avg_reaction_ms integer not null default 0
    check (avg_reaction_ms >= 0),

  plays integer not null default 0
    check (plays >= 0),

  updated_at timestamptz not null default now()
);

alter table public.sniper_rush_scores enable row level security;


-- ------------------------------------------------------------
-- 2. 게임 실행 토큰
-- ------------------------------------------------------------

create table if not exists public.sniper_rush_runs (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null
    references auth.users(id) on delete cascade,

  started_at timestamptz not null default now(),
  submitted_at timestamptz
);

create index if not exists sniper_rush_runs_user_started_idx
on public.sniper_rush_runs(user_id, started_at desc);

alter table public.sniper_rush_runs enable row level security;


-- ------------------------------------------------------------
-- 3. 게임 시작
-- ------------------------------------------------------------

create or replace function public.start_sniper_rush_run()
returns uuid
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  caller_id uuid;
  new_run_id uuid;
begin
  caller_id := auth.uid();

  if caller_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if exists(
    select 1
    from public.banned_users b
    where b.user_id = caller_id
  ) then
    raise exception '현재 이용이 제한된 계정입니다.';
  end if;

  delete from public.sniper_rush_runs
  where started_at < now() - interval '1 day';

  insert into public.sniper_rush_runs(user_id)
  values(caller_id)
  returning id into new_run_id;

  return new_run_id;
end;
$$;

grant execute
on function public.start_sniper_rush_run()
to authenticated;


-- ------------------------------------------------------------
-- 4. 포기 / 창 닫기
-- ------------------------------------------------------------

create or replace function public.abandon_sniper_rush_run(
  run_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  caller_id uuid;
  deleted_count integer;
begin
  caller_id := auth.uid();

  if caller_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  delete from public.sniper_rush_runs
  where id = run_id
    and user_id = caller_id
    and submitted_at is null;

  get diagnostics deleted_count = row_count;

  return deleted_count > 0;
end;
$$;

grant execute
on function public.abandon_sniper_rush_run(uuid)
to authenticated;


-- ------------------------------------------------------------
-- 5. 결과 제출
--
-- 클라이언트 게임이므로 완전한 치트 방지는 불가능합니다.
-- 서버에서는 실행 시간, 목숨, 처치/발사 관계, 헤드샷/콤보,
-- 점수의 이론상 상한 등을 검증합니다.
-- ------------------------------------------------------------

create or replace function public.submit_sniper_rush_score(
  run_id uuid,
  score_value integer,
  shots_value integer,
  kills_value integer,
  civilian_hits_value integer,
  escaped_value integer,
  remaining_lives_value integer,
  headshots_value integer,
  best_combo_value integer,
  avg_reaction_value integer,
  ended_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  caller_id uuid;
  run_row public.sniper_rush_runs%rowtype;
  elapsed_ms bigint;
  accuracy_value numeric(5,2);
  old_best integer := 0;
  final_best integer := 0;
  is_new_best boolean := false;
  life_losses integer;
begin
  caller_id := auth.uid();

  if caller_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if ended_reason not in ('time','lives') then
    raise exception '올바르지 않은 게임 종료 사유입니다.';
  end if;

  select *
  into run_row
  from public.sniper_rush_runs
  where id = run_id
    and user_id = caller_id
    and submitted_at is null
  for update;

  if not found then
    raise exception '유효하지 않거나 이미 제출된 게임 기록입니다.';
  end if;

  elapsed_ms :=
    floor(extract(epoch from (now() - run_row.started_at)) * 1000);

  if elapsed_ms < 500 then
    raise exception '게임 시간이 너무 짧습니다.';
  end if;

  if elapsed_ms > 180000 then
    raise exception '만료된 게임 기록입니다.';
  end if;

  if score_value < 0
     or shots_value < 0
     or kills_value < 0
     or civilian_hits_value < 0
     or escaped_value < 0
     or remaining_lives_value < 0
     or remaining_lives_value > 5
     or headshots_value < 0
     or best_combo_value < 0
     or avg_reaction_value < 0 then
    raise exception '올바르지 않은 게임 기록입니다.';
  end if;

  if shots_value < kills_value + civilian_hits_value then
    raise exception '발사 및 명중 기록이 올바르지 않습니다.';
  end if;

  if headshots_value > kills_value then
    raise exception '헤드샷 기록이 올바르지 않습니다.';
  end if;

  if best_combo_value > kills_value then
    raise exception '콤보 기록이 올바르지 않습니다.';
  end if;

  life_losses := civilian_hits_value + escaped_value;

  if life_losses > 5 then
    raise exception '목숨 수와 맞지 않는 게임 기록입니다.';
  end if;

  if remaining_lives_value <> 5 - life_losses then
    raise exception '남은 목숨 기록이 올바르지 않습니다.';
  end if;

  if ended_reason = 'lives' then
    if life_losses <> 5 or remaining_lives_value <> 0 then
      raise exception '목숨 게임오버 기록이 올바르지 않습니다.';
    end if;
  end if;

  if ended_reason = 'time' then
    if elapsed_ms < 55000 then
      raise exception '제한시간 종료 기록이 너무 빠릅니다.';
    end if;

    if life_losses >= 5 then
      raise exception '목숨이 모두 소진된 기록은 제한시간 종료로 제출할 수 없습니다.';
    end if;
  end if;

  -- 현재 점수식의 적 1명당 이론상 최대치는 약 1,425점입니다.
  -- 여유를 두어 1,500점/처치를 상한으로 검증합니다.
  if score_value > kills_value * 1500 then
    raise exception '점수가 허용 범위를 초과했습니다.';
  end if;

  -- 현재 최소 스폰 간격보다 넉넉하게 둔 비정상 처치 수 검증입니다.
  if kills_value > floor(elapsed_ms / 300.0)::integer + 5 then
    raise exception '처치 수가 허용 범위를 초과했습니다.';
  end if;

  if kills_value = 0 then
    if avg_reaction_value <> 0 then
      raise exception '평균 반응시간 기록이 올바르지 않습니다.';
    end if;
  else
    if avg_reaction_value < 30 or avg_reaction_value > 5000 then
      raise exception '평균 반응시간이 허용 범위를 벗어났습니다.';
    end if;
  end if;

  accuracy_value :=
    case
      when shots_value = 0 then 0
      else round(
        (kills_value::numeric / shots_value::numeric) * 100,
        2
      )
    end;

  select coalesce(best_score,0)
  into old_best
  from public.sniper_rush_scores
  where user_id = caller_id;

  old_best := coalesce(old_best,0);
  is_new_best := score_value > old_best;

  insert into public.sniper_rush_scores(
    user_id,
    best_score,
    best_accuracy,
    best_headshots,
    best_combo,
    avg_reaction_ms,
    plays,
    updated_at
  )
  values(
    caller_id,
    score_value,
    accuracy_value,
    headshots_value,
    best_combo_value,
    avg_reaction_value,
    1,
    now()
  )
  on conflict(user_id)
  do update set
    best_score =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then excluded.best_score
        else sniper_rush_scores.best_score
      end,

    best_accuracy =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then excluded.best_accuracy
        else sniper_rush_scores.best_accuracy
      end,

    best_headshots =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then excluded.best_headshots
        else sniper_rush_scores.best_headshots
      end,

    best_combo =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then excluded.best_combo
        else sniper_rush_scores.best_combo
      end,

    avg_reaction_ms =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then excluded.avg_reaction_ms
        else sniper_rush_scores.avg_reaction_ms
      end,

    plays = sniper_rush_scores.plays + 1,

    updated_at =
      case
        when excluded.best_score > sniper_rush_scores.best_score
          then now()
        else sniper_rush_scores.updated_at
      end;

  update public.sniper_rush_runs
  set submitted_at = now()
  where id = run_id;

  select best_score
  into final_best
  from public.sniper_rush_scores
  where user_id = caller_id;

  return jsonb_build_object(
    'accepted', true,
    'new_best', is_new_best,
    'best_score', coalesce(final_best,0),
    'accuracy', accuracy_value
  );
end;
$$;

grant execute
on function public.submit_sniper_rush_score(
  uuid,
  integer,
  integer,
  integer,
  integer,
  integer,
  integer,
  integer,
  integer,
  integer,
  text
)
to authenticated;


-- ------------------------------------------------------------
-- 6. TOP 10 + 내 순위
-- ------------------------------------------------------------

create or replace function public.get_sniper_rush_leaderboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set row_security = off
as $$
declare
  caller_id uuid;
  result_data jsonb;
begin
  caller_id := auth.uid();

  if caller_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  with ranked as (
    select
      s.user_id,
      s.best_score,
      s.best_accuracy,
      s.best_headshots,
      s.best_combo,
      s.avg_reaction_ms,
      s.plays,
      s.updated_at,
      row_number() over(
        order by
          s.best_score desc,
          s.best_accuracy desc,
          s.best_headshots desc,
          s.updated_at asc
      )::integer as rank
    from public.sniper_rush_scores s
  ),

  top_rows as (
    select
      r.*,
      p.username,
      p.display_name
    from ranked r
    left join public.profiles p
      on p.id = r.user_id
    where r.rank <= 10
    order by r.rank
  ),

  my_row as (
    select
      r.*,
      p.username,
      p.display_name
    from ranked r
    left join public.profiles p
      on p.id = r.user_id
    where r.user_id = caller_id
    limit 1
  )

  select jsonb_build_object(
    'top',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'rank', t.rank,
            'user_id', t.user_id,
            'username', t.username,
            'display_name', t.display_name,
            'best_score', t.best_score,
            'best_accuracy', t.best_accuracy,
            'best_headshots', t.best_headshots,
            'best_combo', t.best_combo,
            'avg_reaction_ms', t.avg_reaction_ms,
            'plays', t.plays
          )
          order by t.rank
        )
        from top_rows t
      ),
      '[]'::jsonb
    ),

    'me',
    (
      select jsonb_build_object(
        'rank', m.rank,
        'user_id', m.user_id,
        'username', m.username,
        'display_name', m.display_name,
        'best_score', m.best_score,
        'best_accuracy', m.best_accuracy,
        'best_headshots', m.best_headshots,
        'best_combo', m.best_combo,
        'avg_reaction_ms', m.avg_reaction_ms,
        'plays', m.plays
      )
      from my_row m
    )
  )
  into result_data;

  return result_data;
end;
$$;

grant execute
on function public.get_sniper_rush_leaderboard()
to authenticated;

commit;


-- ------------------------------------------------------------
-- 확인
-- ------------------------------------------------------------

select
  exists(
    select 1 from information_schema.tables
    where table_schema='public'
      and table_name='sniper_rush_scores'
  ) as sniper_rush_scores_ready,

  exists(
    select 1 from pg_proc
    where proname='start_sniper_rush_run'
  ) as start_sniper_rush_run_ready,

  exists(
    select 1 from pg_proc
    where proname='submit_sniper_rush_score'
  ) as submit_sniper_rush_score_ready,

  exists(
    select 1 from pg_proc
    where proname='get_sniper_rush_leaderboard'
  ) as sniper_leaderboard_ready;
