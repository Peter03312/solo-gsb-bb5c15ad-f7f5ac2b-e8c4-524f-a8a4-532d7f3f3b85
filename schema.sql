-- 频点协调服务数据库结构
-- 应用启动时自动执行（幂等），无需手工初始化。

CREATE TABLE IF NOT EXISTS sessions (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    frequencies  INTEGER[] NOT NULL,          -- 场次可用的整数频点集合（升序、去重）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS groups (
    id           SERIAL PRIMARY KEY,          -- 组编号（自增，规划时按此升序）
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    name         TEXT NOT NULL DEFAULT '',
    start_min    INTEGER NOT NULL,            -- 使用时段起点（分钟，左闭）
    end_min      INTEGER NOT NULL,            -- 使用时段终点（分钟，右开）
    CHECK (start_min < end_min)
);

CREATE TABLE IF NOT EXISTS interferences (
    id             SERIAL PRIMARY KEY,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    group_a        INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    group_b        INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    min_separation INTEGER NOT NULL,          -- 正整数最小频点间距
    CHECK (group_a <> group_b),
    CHECK (min_separation > 0)
);

-- 发布版：每个场次内版本号从 1 单调递增，发布后不可变
CREATE TABLE IF NOT EXISTS plans (
    id           SERIAL PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    version      INTEGER NOT NULL,
    changes      INTEGER NOT NULL,            -- 相对前一发布版共有组的改频数
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, version)
);

CREATE TABLE IF NOT EXISTS plan_assignments (
    plan_id      INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    group_id     INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    frequency    INTEGER NOT NULL,
    PRIMARY KEY (plan_id, group_id)
);

-- 规划时使用的锁定（随发布版留存，便于追溯）
CREATE TABLE IF NOT EXISTS plan_locks (
    plan_id      INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    group_id     INTEGER NOT NULL,
    frequency    INTEGER NOT NULL,
    PRIMARY KEY (plan_id, group_id)
);

-- 外部设备占用记录：场次频点在指定整数分钟时段 [start, end) 被其他设备占用。
-- 设备组时段与占用时段相交（左闭右开，端点相接不算相交）时不得选用该频点。
CREATE TABLE IF NOT EXISTS occupations (
    id           SERIAL PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    frequency    INTEGER NOT NULL,            -- 被占用的频点（须属于场次可用集合）
    start_min    INTEGER NOT NULL,            -- 占用起点（分钟，左闭）
    end_min      INTEGER NOT NULL,            -- 占用终点（分钟，右开）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (start_min < end_min)
);

CREATE INDEX IF NOT EXISTS idx_occupations_session
    ON occupations (session_id);

-- 实测频点批次：现场人员为某场次留存一次完整实测，核对其与指定发布版及
-- 当前约束的差异。批次号在场次内由调用方提交且单调递增（低于已记录最新
-- 批次即拒绝）；同批次号 + 同内容重试为幂等重放，内容不同则冲突。
CREATE TABLE IF NOT EXISTS measurement_batches (
    id             SERIAL PRIMARY KEY,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    batch_no       INTEGER NOT NULL,            -- 场次内递增批次号（调用方提交）
    plan_version   INTEGER NOT NULL,            -- 核对所用指定发布版号
    -- 规范化的提交内容（按组编号升序的 {group_id, frequency}），用于幂等判定
    content        JSONB NOT NULL,
    -- 固化的判定依据与结果（异常列表、发布版分配、可用频点、占用快照等）；
    -- 后续撤销占用或发布新版本均不改变历史结果，读取时直接回放
    result         JSONB NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, batch_no)
);

-- 实测时每个设备组的实测整数频点（频点即使不在可用集合内也照样留存）
CREATE TABLE IF NOT EXISTS measurement_readings (
    batch_id    INTEGER NOT NULL
                REFERENCES measurement_batches(id) ON DELETE CASCADE,
    group_id    INTEGER NOT NULL,                -- 不引用 groups(id)：组删除后
    frequency   INTEGER NOT NULL,                -- 历史批次仍须原样可读
    PRIMARY KEY (batch_id, group_id)
);

-- 该批次基于的同一份当前占用状态快照（id/频点/时段全量固化）
CREATE TABLE IF NOT EXISTS measurement_occupation_snapshot (
    batch_id    INTEGER NOT NULL
                REFERENCES measurement_batches(id) ON DELETE CASCADE,
    occ_id      INTEGER NOT NULL,
    frequency   INTEGER NOT NULL,
    start_min   INTEGER NOT NULL,
    end_min     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_measurement_batches_session
    ON measurement_batches (session_id, batch_no);
