#!/usr/bin/env bash
# 实测频点批次 请求示例（需服务已启动，默认 http://localhost:8000）
#
# 现场人员为某场次留存一次完整实测频点，并核对它与指定发布版及当前约束的
# 差异。本脚本演示：提交实测批次（偏离发布版/不可用频点/间距违规/占用冲突）、
# 同批次幂等重放与内容冲突、批次号单调拒绝、读取最新/指定批次，以及撤销
# 占用后历史批次结果保持不变（快照与判定依据固化）。
set -euo pipefail

BASE="${BASE:-http://localhost:8000}"

echo "== 1. 建场次（频点 1..9）、三组 a[0,120) b[60,180) c[120,240)，边 a-b、b-c 间距 3 =="
SID=$(curl -s -X POST "$BASE/sessions" \
  -H 'Content-Type: application/json' \
  -d '{"name": "实测演示", "frequencies": [1,2,3,4,5,6,7,8,9]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
GA=$(curl -s -X POST "$BASE/sessions/$SID/groups" \
  -H 'Content-Type: application/json' -d '{"name":"a","start":0,"end":120}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
GB=$(curl -s -X POST "$BASE/sessions/$SID/groups" \
  -H 'Content-Type: application/json' -d '{"name":"b","start":60,"end":180}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
GC=$(curl -s -X POST "$BASE/sessions/$SID/groups" \
  -H 'Content-Type: application/json' -d '{"name":"c","start":120,"end":240}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
curl -s -X POST "$BASE/sessions/$SID/interferences" \
  -H 'Content-Type: application/json' \
  -d "{\"group_a\": $GA, \"group_b\": $GB, \"min_separation\": 3}" >/dev/null
curl -s -X POST "$BASE/sessions/$SID/interferences" \
  -H 'Content-Type: application/json' \
  -d "{\"group_a\": $GB, \"group_b\": $GC, \"min_separation\": 3}" >/dev/null

echo "== 2. 发布版本 1：a=1、b=4、c=1 =="
curl -s -X POST "$BASE/sessions/$SID/plans" \
  -H 'Content-Type: application/json' \
  -d '{"base_version": 0, "locks": []}' | python3 -m json.tool

echo "== 3. 登记外部占用：频点 1 的 [60,180)，与三个组时段都相交 =="
OCC=$(curl -s -X POST "$BASE/sessions/$SID/occupations" \
  -H 'Content-Type: application/json' \
  -d '{"frequency": 1, "start": 60, "end": 180}')
echo "$OCC" | python3 -m json.tool

echo "== 4. 提交实测批次 1：a=1、c=1（频点与占用相同，撞占用）、b=4；实测与发布版一致 =="
curl -s -w '\nHTTP %{http_code}\n' -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 1, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 1},
        {\"group_id\": $GB, \"frequency\": 4},
        {\"group_id\": $GC, \"frequency\": 1}]}"

echo "== 5. 提交实测批次 2：a=5（偏离）、b=1（偏离且撞占用）、c=99（不可用频点照常记录） =="
curl -s -w '\nHTTP %{http_code}\n' -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 2, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 5},
        {\"group_id\": $GB, \"frequency\": 1},
        {\"group_id\": $GC, \"frequency\": 99}]}"

echo "== 6. 提交实测批次 3：a=1、b=2（间距 1 < 3 违规）、c=5（|2-5|=3 恰好满足） =="
curl -s -w '\nHTTP %{http_code}\n' -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 3, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 1},
        {\"group_id\": $GB, \"frequency\": 2},
        {\"group_id\": $GC, \"frequency\": 5}]}"

echo "== 7. 非法提交被拒绝 =="
# 未知发布版
curl -s -o /dev/null -w '未知发布版       -> HTTP %{http_code}\n' \
  -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 99, \"batch_no\": 9, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 1}]}"
# 漏组
curl -s -o /dev/null -w '漏组             -> HTTP %{http_code}\n' \
  -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 9, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 1},
        {\"group_id\": $GB, \"frequency\": 4}]}"
# 重复组
curl -s -o /dev/null -w '重复组           -> HTTP %{http_code}\n' \
  -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 9, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 1},
        {\"group_id\": $GA, \"frequency\": 2},
        {\"group_id\": $GB, \"frequency\": 4},
        {\"group_id\": $GC, \"frequency\": 1}]}"
# 批次号低于最新
curl -s -o /dev/null -w '批次号倒退       -> HTTP %{http_code}\n' \
  -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 1, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 5},
        {\"group_id\": $GB, \"frequency\": 4},
        {\"group_id\": $GC, \"frequency\": 1}]}"

echo "== 8. 相同批次号相同内容重试：200 幂等重放（replayed=true） =="
curl -s -w '\nHTTP %{http_code}\n' -X POST "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 2, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 5},
        {\"group_id\": $GB, \"frequency\": 1},
        {\"group_id\": $GC, \"frequency\": 99}]}" \
  | python3 -c 'import json,sys
raw=sys.stdin.read()
body,_,code=raw.rpartition("\nHTTP ")
d=json.loads(body)
print("replayed =", d["replayed"], "| anomalous =", d["anomalous"])
print("HTTP", code.strip())'

echo "== 9. 相同批次号不同内容：409 batch_conflict =="
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST \
  "$BASE/sessions/$SID/measurements" \
  -H 'Content-Type: application/json' \
  -d "{\"plan_version\": 1, \"batch_no\": 2, \"readings\": [
        {\"group_id\": $GA, \"frequency\": 6},
        {\"group_id\": $GB, \"frequency\": 1},
        {\"group_id\": $GC, \"frequency\": 99}]}"

echo "== 10. 读取批次列表 / 最新批次 / 指定批次 =="
curl -s "$BASE/sessions/$SID/measurements" | python3 -m json.tool
curl -s "$BASE/sessions/$SID/measurements/latest" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("最新批次:", d["batch_no"])'
curl -s "$BASE/sessions/$SID/measurements/1" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)
print("批次1 占用冲突:", [(c["group_id"], [o["id"] for o in c["occupations"]])
                         for c in d["occupation_conflicts"]])'
echo "== 11. 撤销占用后，历史批次结果不变（仍含原占用冲突与快照依据） =="
OCC_ID=$(echo "$OCC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
curl -s -X DELETE "$BASE/sessions/$SID/occupations/$OCC_ID" >/dev/null
curl -s "$BASE/sessions/$SID/measurements/1" | python3 -m json.tool
