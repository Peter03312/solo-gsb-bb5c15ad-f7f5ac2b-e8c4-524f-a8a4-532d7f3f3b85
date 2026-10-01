# 频点协调服务

为临时演出的无线电设备组协调频点。录入场次可用的整数频点、设备组使用时段
（左闭右开）与组间干扰关系（正整数最小频点间距），服务在满足全部约束的前提
下规划频点分配，并发布为不可变的版本。

- 时段相交的干扰组，频点间距不小于其最小间距；同组全程只用一个频点；
- 规划时可锁定部分组的频点；
- 现场其他设备可在指定整数分钟时段占用场次频点：设备组时段与占用时段
  相交（左闭右开，端点相接不算）时，该组不得选用被占用频点；
- 目标依次为：满足所有约束 → 最小化与前一发布版共有组的改频数（首次规划
  计零）→ 并列时按组编号升序的频点序列取字典序最小；
- 无解时返回 422 并说明涉及的锁定组、干扰关系或占用记录，当前发布版不变；
- 发布须提交所见版本号 `base_version`，过期即返回 409；并发发布只有一个
  可成功；各发布版不可变，可读取分配结果及与前版差异；**已发布版不会因
  占用变化自动重写**；
- 占用登记/撤销与发布按场次串行，发布始终基于一份一致的当前占用状态；
- 起点不早于终点、引用未知组、锁定不可用频点等校验失败均返回 400 并拒绝
  整次操作。

## 一键启动（Docker Compose）

```bash
docker compose up --build
```

Compose 会启动 PostgreSQL 与应用两个容器；应用启动时自动等待数据库就绪并
初始化表结构（`schema.sql`），无需手工操作。

- API 地址：http://localhost:8000
- 交互式接口文档（Swagger UI）：http://localhost:8000/docs
- PostgreSQL：localhost:5432（用户/密码/库名均为 `freq` / `freq` / `freqdb`）

停止并清空数据：`docker compose down -v`

## 配置

| 环境变量       | 默认值                                          | 说明           |
| -------------- | ----------------------------------------------- | -------------- |
| `DATABASE_URL` | `postgresql://freq:freq@localhost:5432/freqdb`  | 数据库连接串   |

Compose 中已注入 `DATABASE_URL=postgresql://freq:freq@db:5432/freqdb`。

## 本地开发（不用 Docker）

```bash
pip install -r requirements.txt
# 准备 PostgreSQL 并设置 DATABASE_URL，然后：
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

运行测试：

```bash
pip install pytest
python -m pytest tests/            # 求解器单元测试（无需数据库）
# 端到端集成检查（自动拉起嵌入式 PostgreSQL 与真实服务进程）：
pip install pgserver httpx
python tests/integration_check.py
```

## 数据模型与约定

- **场次（session）**：名称 + 可用整数频点集合；
- **设备组（group）**：使用时段 `[start, end)`，左闭右开，整数分钟；`id`
  即组编号（自增），规划的字典序比较按组编号升序；
- **干扰关系（interference）**：两个组 + 正整数最小频点间距，仅当两组时段
  相交时生效；
- **发布版（plan）**：场次内版本号从 1 递增，发布后不可变，记录分配结果、
  改频数与本次锁定。
- **占用记录（occupation）**：外部设备在整数分钟时段 `[start, end)`
  （左闭右开）占用场次某个可用频点；记录编号自增，撤销即删除。设备组时段
  与占用时段相交时该组禁用此频点，端点相接（如组 `[0,60)` 与占用
  `[60,120)`）不算相交。

## API 一览

| 方法 | 路径 | 说明 |
| ---- | ---- | ---- |
| POST | `/sessions` | 创建场次（登记可用频点集合） |
| GET  | `/sessions/{id}` | 场次详情（含组与干扰关系） |
| POST | `/sessions/{id}/groups` | 录入设备组及时段 |
| POST | `/sessions/{id}/interferences` | 录入干扰关系 |
| POST | `/sessions/{id}/occupations` | 登记频点占用（返回记录编号） |
| GET  | `/sessions/{id}/occupations` | 查询场次当前占用 |
| DELETE | `/sessions/{id}/occupations/{occ_id}` | 撤销一条占用记录 |
| POST | `/sessions/{id}/plans` | 规划并发布新版本（携带 `base_version` 与 `locks`） |
| GET  | `/sessions/{id}/plans` | 列出全部发布版 |
| GET  | `/sessions/{id}/plans/{version}` | 读取指定发布版分配结果 |
| GET  | `/sessions/{id}/plans/{version}/diff` | 与前一版的差异 |
| POST | `/sessions/{id}/retune` | 计算两个发布版之间的逐组切换路线（只读） |

状态码约定：`201` 创建/发布成功；`400` 校验失败（起点不早于终点、引用未知
组、锁定不可用频点、占用频点不属于场次、撤销未知占用记录等）；`404` 资源
不存在；`409` 版本冲突；`422` 约束不可满足（当前发布版不变）。

## 请求示例

```bash
# 1. 创建场次：可用频点 1..6
curl -s -X POST http://localhost:8000/sessions \
  -H 'Content-Type: application/json' \
  -d '{"name": "周六演出", "frequencies": [1, 2, 3, 4, 5, 6]}'
# => {"id":1,...}

# 2. 录入设备组（时段左闭右开，单位：分钟）
curl -s -X POST http://localhost:8000/sessions/1/groups \
  -H 'Content-Type: application/json' -d '{"name": "音响", "start": 0, "end": 120}'
curl -s -X POST http://localhost:8000/sessions/1/groups \
  -H 'Content-Type: application/json' -d '{"name": "灯光", "start": 60, "end": 180}'

# 3. 录入干扰关系：组 1 与组 2 最小间距 3
curl -s -X POST http://localhost:8000/sessions/1/interferences \
  -H 'Content-Type: application/json' \
  -d '{"group_a": 1, "group_b": 2, "min_separation": 3}'

# 4. 首次规划并发布（无发布版时 base_version 为 0）
curl -s -X POST http://localhost:8000/sessions/1/plans \
  -H 'Content-Type: application/json' \
  -d '{"base_version": 0, "locks": []}'
# => {"version":1,"changes":0,"assignments":[{"group_id":1,"frequency":1},
#     {"group_id":2,"frequency":4}],...}

# 5. 再次发布：基于版本 1，并锁定组 1 使用频点 2
curl -s -X POST http://localhost:8000/sessions/1/plans \
  -H 'Content-Type: application/json' \
  -d '{"base_version": 1, "locks": [{"group_id": 1, "frequency": 2}]}'

# 6. 读取发布版与差异
curl -s http://localhost:8000/sessions/1/plans/2
curl -s http://localhost:8000/sessions/1/plans/2/diff
```

无解时的响应示例（422，当前发布版不变）：

```json
{
  "detail": {
    "error": "unsatisfiable",
    "message": "约束不可满足，当前发布版不变",
    "cause": "locks",
    "locks": [{"group_id": 1, "frequency": 1}],
    "interferences": [{"group_a": 1, "group_b": 2, "min_separation": 3}]
  }
}
```

版本冲突时的响应示例（409）：

```json
{
  "detail": {
    "error": "version_conflict",
    "message": "所见版本已过期，请基于最新发布版重新提交",
    "current_version": 2
  }
}
```

## 频点占用（现场其他设备）

现场其他设备会在指定时段占用场次频点。可随时按场次**登记**或**撤销**占用
记录，也可查询当前占用：

- 登记输入：场次内的一个**可用频点**与整数分钟时段 `[start, end)`
  （左闭右开），返回记录编号；
- 设备组时段与占用时段**相交**时，该组不得选用该频点；**端点相接不算
  相交**（组 `[0,60)` 与占用 `[60,120)` 互不影响）；
- 频点不属于场次、起点不早于终点、撤销未知记录（含不属于本场次的编号）
  时返回 `400` 并拒绝整次操作；
- 占用登记/撤销与发布**按场次串行**（同一场次行锁），发布基于一份一致的
  当前占用状态；**已发布版保持不可变，不因占用变化自动重写**；
- 占用导致规划无解时返回 `422`，`detail.cause` 为 `occupations`（或
  `locks`/`interferences`），并在 `detail.occupations` 中给出相关占用记录；
- 逐组切换路线按**一次一致的当前占用快照**检查起终点与每个临时步骤；
  旧版若因新占用而不可行，沿用 `endpoint_infeasible` 错误语义，并在
  `start`/`target` 的 `occupations` 与 `related_occupations` 中指出冲突
  （组、频点与对应占用记录）。

```bash
# 登记：外部设备在 [30,150) 占用频点 4
curl -s -X POST http://localhost:8000/sessions/1/occupations \
  -H 'Content-Type: application/json' \
  -d '{"frequency": 4, "start": 30, "end": 150}'
# => {"id":1,"session_id":1,"frequency":4,"start":30,"end":150,"created_at":...}

# 查询当前占用（按记录编号升序；已撤销记录不再出现）
curl -s http://localhost:8000/sessions/1/occupations

# 撤销记录 1
curl -s -X DELETE http://localhost:8000/sessions/1/occupations/1
# => {"id":1,"session_id":1,"revoked":true,"frequency":4,"start":30,"end":150}
```

登记响应（201）字段：`id`（记录编号）、`session_id`、`frequency`、
`start`、`end`、`created_at`；GET 查询返回上述字段（含 `created_at`）的
数组；场次详情 `GET /sessions/{id}` 也包含当前 `occupations` 列表。

占用导致无解时的响应示例（422，发布版不变）：

```json
{
  "detail": {
    "error": "unsatisfiable",
    "message": "约束不可满足，当前发布版不变",
    "cause": "occupations",
    "locks": [],
    "interferences": [],
    "occupations": [
      {"id": 1, "frequency": 1, "start": 0, "end": 60},
      {"id": 3, "frequency": 2, "start": 10, "end": 50}
    ]
  }
}
```

占用与干扰关系共同导致无解时，`cause` 为 `"occupations"` 且
`interferences` 同时列出涉及的最小干扰关系子集；无解由锁定引入时
`cause` 为 `"locks"`，同样附上与锁定组时段相交的相关占用记录。

占用使旧发布版端点不可行时的响应示例（`POST /retune`，422）：

```json
{
  "detail": {
    "error": "endpoint_infeasible",
    "message": "起始版或目标版在当前规则（含频点占用）下不是可行分配",
    "start": {
      "unavailable": [],
      "interferences": [],
      "occupations": [{"group_id": 2, "frequency": 1}],
      "related_occupations": [
        {"id": 6, "frequency": 1, "start": 60, "end": 180}
      ]
    },
    "target": {
      "unavailable": [],
      "interferences": [],
      "occupations": [],
      "related_occupations": []
    }
  }
}
```

也可以直接运行示例脚本（需服务已启动）：

```bash
bash examples/occupations.sh
```

## 逐组切换路线

现场设备无法把新发布版的频点一次切换到位，需要逐组调频。给定**同一场次**
的起始发布版、目标发布版，以及切换期间不可调频的组（可选），
`POST /sessions/{id}/retune` 返回一条逐组切换路线：

- 每一步只把**一个**组改到本场次的可用频点，可借用**临时频点**（某步的新
  频点不是该组在目标版中的频点时，响应中 `temporary` 为 `true`）；
- 每一步之后（含起点、终点）的**完整分配**都必须满足当前按左闭右开时段
  生效的干扰关系及最小频点间距；外部设备**占用**的频点同样在起点、终点
  及每个临时步骤中禁用（占用取同一只读事务内的一致快照）；
- 不可调频组在两版中的频点必须相同，且在整个路线中保持不变；
- 优化目标依次为：**最少步骤数** → 按各步 `(组编号, 新频点)` 序列取
  **字典序最小**；
- 该接口为**只读**计算：所有数据（配置、发布版、当前占用）在同一个
  `REPEATABLE READ` 只读事务（一致快照）中读取，不会创建或修改任何
  发布版或占用记录。

请求体：

| 字段 | 说明 |
| ---- | ---- |
| `start_version` | 起始发布版版本号（≥1，须属于同一场次） |
| `target_version` | 目标发布版版本号（≥1，可与起始版相同，此时为 0 步） |
| `fixed_groups` | 可选，切换期间不可调频的组编号列表（不可重复） |

```bash
# 场次可用频点 1..7，组 a[0,120)、b[60,180)、c[120,240)，
# 干扰关系 a-b 间距3、b-c 间距3（a、c 时段不相交，关系不生效）。
# 版本 1 分配 (a=1,b=4,c=1)，版本 2 分配 (a=4,b=1,c=4)：
curl -s -X POST http://localhost:8000/sessions/1/retune \
  -H 'Content-Type: application/json' \
  -d '{"start_version": 1, "target_version": 2, "fixed_groups": []}'
```

成功响应（200）：`steps` 按顺序给出每一步及该步之后的完整分配，
`temporary` 标记借用的临时频点：

```json
{
  "session_id": 1,
  "start_version": 1,
  "target_version": 2,
  "fixed_groups": [],
  "steps_count": 4,
  "start_assignment": [
    {"group_id": 1, "frequency": 1},
    {"group_id": 2, "frequency": 4},
    {"group_id": 3, "frequency": 1}
  ],
  "target_assignment": [
    {"group_id": 1, "frequency": 4},
    {"group_id": 2, "frequency": 1},
    {"group_id": 3, "frequency": 4}
  ],
  "steps": [
    {"step": 1, "group_id": 2, "frequency": 7, "temporary": true,
     "assignment": [{"group_id": 1, "frequency": 1},
                    {"group_id": 2, "frequency": 7},
                    {"group_id": 3, "frequency": 1}]},
    {"step": 2, "group_id": 1, "frequency": 4, "temporary": false,
     "assignment": [{"group_id": 1, "frequency": 4},
                    {"group_id": 2, "frequency": 7},
                    {"group_id": 3, "frequency": 1}]},
    {"step": 3, "group_id": 3, "frequency": 4, "temporary": false,
     "assignment": [{"group_id": 1, "frequency": 4},
                    {"group_id": 2, "frequency": 7},
                    {"group_id": 3, "frequency": 4}]},
    {"step": 4, "group_id": 2, "frequency": 1, "temporary": false,
     "assignment": [{"group_id": 1, "frequency": 4},
                    {"group_id": 2, "frequency": 1},
                    {"group_id": 3, "frequency": 4}]}
  ]
}
```

不可调频组示例（组 5 切换期间必须保持其频点不变）：

```bash
curl -s -X POST http://localhost:8000/sessions/1/retune \
  -H 'Content-Type: application/json' \
  -d '{"start_version": 1, "target_version": 2, "fixed_groups": [5]}'
```

拒绝与失败情形：

| 情形 | 状态码 | `detail.error` |
| ---- | ------ | -------------- |
| 起始版/目标版不存在、不可调频组引用未知组或重复指定 | 400 | `invalid_reference` |
| 场次不存在 | 404 | （`"场次不存在"`） |
| 两版组集合不同，或与场次当前组集合不一致 | 422 | `group_set_mismatch` |
| 不可调频组在两版中的频点不同（需改频） | 422 | `fixed_group_conflict` |
| 起始版或目标版在当前规则下不是可行分配（含频点不可用、违反间距、组频点在当前占用中被禁用） | 422 | `endpoint_infeasible` |
| 两端点均可行，但不存在满足约束的逐组切换路线（配置空间被冻结） | 422 | `no_safe_route` |
| 搜索规模超过资源上限 | 503 | （`"切换路线搜索超出资源限制…"`） |

`endpoint_infeasible` 会分别给出起点/终点的不可用频点
（`unavailable`）、违反的干扰关系（`interferences`）、与当前占用冲突的
组及频点（`occupations`），并在 `related_occupations` 中给出对应占用记录
的编号与时段；`group_set_mismatch` 会给出仅在某一版出现、以及当前配置中
缺失/未知的组。
例如端点可行却无安全路线时（422）：

```json
{
  "detail": {
    "error": "no_safe_route",
    "message": "两端点均可行，但不存在满足约束的逐组切换安全路线"
  }
}
```

也可以直接运行示例脚本（需服务已启动）：

```bash
bash examples/demo.sh          # 场次/组/干扰/发布/差异
bash examples/occupations.sh   # 占用登记、查询、422 与撤销
bash examples/retune.sh        # 逐组切换路线（只读）
```

## 项目结构

```
app/main.py    HTTP API 与发布事务（行锁串行化并发发布与占用变更；切换路线
               只读快照，起点/终点/每个临时步骤都按当前占用检查）
app/solver.py  回溯 + 前向检查求解器（含占用禁用频点）；无解时给出不可约的
               锁定/干扰/占用核心
app/retune.py  逐组切换路线：连通分量分解 + 限深 BFS（最少步数、字典序最小）
app/db.py      连接池、启动重试与 schema 初始化
schema.sql     表结构（应用启动时幂等执行；occupations 为本轮新增）
tests/         求解器单元测试与端到端集成检查
examples/      curl 请求示例
```
