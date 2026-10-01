"""实测频点批次的差异核对（纯逻辑，无数据库依赖）。

现场人员对某场次的一次完整实测：每个设备组记录一个实测整数频点，并与
**指定发布版**及**当前约束**核对。核对在同一份“当前占用状态快照”下完成，
判定结果由调用方固化到数据库；后续撤销占用或发布新版本都不改变历史结果。

核对项：

1. ``deviations``：实测频点相对指定发布版发生偏离的组（频点不同）；
2. ``unavailable``：实测频点不在场次可用集合内的组（异常，照常记录）；
3. ``interferences``：时段相交（左闭右开，端点相接不算）的干扰组中，实测
   频点间距小于最小间距的干扰关系；
4. ``occupation_conflicts``：实测频点与外部占用冲突的组及占用编号
   （组时段与占用时段相交且频点相同）。
"""

from __future__ import annotations

from .solver import intervals_overlap


def analyze_measurement(groups, frequencies, interferences, plan_assignment,
                        readings, occupations):
    """对一次完整实测做差异核对。

    调用方须先保证组集合一致（实测组集合 == 指定发布版组集合 == 场次当前
    组集合），本函数不再检查组集合。

    :param groups:          场次当前组列表（字典，含 id/start/end）。
    :param frequencies:     场次可用整数频点集合（以批次提交时的快照为准）。
    :param interferences:   干扰关系列表（group_a/group_b/min_separation），
                            本函数按组时段相交（左闭右开）过滤后核对。
    :param plan_assignment: 指定发布版的分配 {group_id: frequency}。
    :param readings:        实测频点 {group_id: frequency}（整数，可越界）。
    :param occupations:     当前占用记录列表（id/frequency/start/end），
                            多份调用须共用同一份快照。
    :returns: 结构化核对结果字典（deviations / unavailable / interferences /
              occupation_conflicts / anomalous / summary）。
    """
    available = set(frequencies)
    group_by_id = {g["id"]: g for g in groups}

    # 1) 偏离指定发布版的组
    deviations = [
        {"group_id": gid,
         "planned_frequency": plan_assignment[gid],
         "measured_frequency": readings[gid]}
        for gid in sorted(readings)
        if plan_assignment[gid] != readings[gid]
    ]

    # 2) 不可用频点（不在场次可用集合内；异常但照常留存）
    unavailable = [
        {"group_id": gid, "frequency": readings[gid]}
        for gid in sorted(readings) if readings[gid] not in available
    ]

    # 3) 时段相交时违反最小间距的干扰关系
    bad_edges = []
    for itf in sorted(interferences,
                      key=lambda e: (e["group_a"], e["group_b"])):
        ga, gb = group_by_id[itf["group_a"]], group_by_id[itf["group_b"]]
        if not intervals_overlap(ga["start"], ga["end"],
                                 gb["start"], gb["end"]):
            continue
        if abs(readings[itf["group_a"]] - readings[itf["group_b"]]) \
                < itf["min_separation"]:
            bad_edges.append({
                "group_a": itf["group_a"],
                "group_b": itf["group_b"],
                "min_separation": itf["min_separation"],
                "frequency_a": readings[itf["group_a"]],
                "frequency_b": readings[itf["group_b"]],
            })

    # 4) 实测频点与外部占用冲突的组和占用编号（组时段与占用时段相交）
    conflicts = []
    for gid in sorted(readings):
        g = group_by_id[gid]
        hit_occ = []
        for occ in sorted(occupations, key=lambda o: o["id"]):
            if occ["frequency"] != readings[gid]:
                continue
            if intervals_overlap(g["start"], g["end"],
                                 occ["start"], occ["end"]):
                hit_occ.append({"id": occ["id"], "frequency": occ["frequency"],
                                "start": occ["start"], "end": occ["end"]})
        if hit_occ:
            conflicts.append({
                "group_id": gid,
                "frequency": readings[gid],
                "occupations": hit_occ,
            })

    anomalous = bool(unavailable or bad_edges or conflicts)
    return {
        "deviations": deviations,
        "unavailable": unavailable,
        "interferences": bad_edges,
        "occupation_conflicts": conflicts,
        "anomalous": anomalous,
        "summary": {
            "groups": len(readings),
            "deviations": len(deviations),
            "unavailable": len(unavailable),
            "interferences": len(bad_edges),
            "occupation_conflicts": len(conflicts),
        },
    }
