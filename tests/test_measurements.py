"""实测频点核对逻辑单元测试：可脱离数据库直接运行。

运行：python -m pytest tests/
"""

from app.measurements import analyze_measurement

GROUPS = [
    {"id": 1, "name": "音响", "start": 0, "end": 120},
    {"id": 2, "name": "灯光", "start": 60, "end": 180},
    {"id": 3, "name": "返送", "start": 120, "end": 240},
]
FREQS = [1, 2, 3, 4, 5, 6]
INTERFERENCES = [
    {"id": 10, "group_a": 1, "group_b": 2, "min_separation": 3},
    {"id": 11, "group_a": 2, "group_b": 3, "min_separation": 3},
]
PLAN = {1: 1, 2: 4, 3: 1}


def check(readings, occupations=()):
    return analyze_measurement(GROUPS, FREQS, INTERFERENCES, PLAN,
                               readings, list(occupations))


class TestDeviations:
    def test_all_match(self):
        r = check({1: 1, 2: 4, 3: 1})
        assert r["deviations"] == []
        assert r["anomalous"] is False

    def test_some_groups_deviate(self):
        r = check({1: 2, 2: 4, 3: 5})
        assert r["deviations"] == [
            {"group_id": 1, "planned_frequency": 1, "measured_frequency": 2},
            {"group_id": 3, "planned_frequency": 1, "measured_frequency": 5},
        ]


class TestUnavailable:
    def test_out_of_set_still_recorded(self):
        # 频点不在可用集合内也要记录并标明异常
        r = check({1: 99, 2: 4, 3: 1})
        assert r["unavailable"] == [{"group_id": 1, "frequency": 99}]
        assert r["anomalous"] is True
        assert r["summary"]["unavailable"] == 1

    def test_negative_frequency(self):
        r = check({1: -3, 2: 4, 3: 1})
        assert r["unavailable"] == [{"group_id": 1, "frequency": -3}]


class TestInterferences:
    def test_violation_between_overlapping_groups(self):
        # 组1[0,120) 与组2[60,180) 相交；实测 1 与 2 间距 1 < 3；
        # 组2 与组3[120,240) 同样相交，实测 2 与 1 间距 1 < 3
        r = check({1: 1, 2: 2, 3: 1})
        assert r["interferences"] == [
            {"group_a": 1, "group_b": 2, "min_separation": 3,
             "frequency_a": 1, "frequency_b": 2},
            {"group_a": 2, "group_b": 3, "min_separation": 3,
             "frequency_a": 2, "frequency_b": 1}]

    def test_boundary_equal_is_violation(self):
        # |4-2|=2 < 3 违规；|4-1|=3 恰好满足
        r = check({1: 4, 2: 2, 3: 4})
        assert {(e["group_a"], e["group_b"]) for e in r["interferences"]} \
            == {(1, 2), (2, 3)}

    def test_touching_intervals_not_effective(self):
        # 干扰关系即使录入到不相交的组，也不生效：
        # 构造组1[0,60) 与组2[60,120) 端点相接
        groups = [
            {"id": 1, "start": 0, "end": 60},
            {"id": 2, "start": 60, "end": 120},
        ]
        edges = [{"id": 1, "group_a": 1, "group_b": 2,
                  "min_separation": 3}]
        r = analyze_measurement(groups, FREQS, edges, {1: 1, 2: 1},
                                {1: 1, 2: 1}, [])
        assert r["interferences"] == []

    def test_satisfied_separation(self):
        r = check({1: 1, 2: 4, 3: 1})
        assert r["interferences"] == []


class TestOccupationConflicts:
    def test_overlap_same_frequency_conflicts(self):
        occ = [{"id": 7, "frequency": 4, "start": 30, "end": 150}]
        r = check({1: 1, 2: 4, 3: 1}, occ)
        # 占用 [30,150) 与组1[0,120)、组2[60,180) 相交；仅组2实测为 4
        assert r["occupation_conflicts"] == [{
            "group_id": 2, "frequency": 4,
            "occupations": [
                {"id": 7, "frequency": 4, "start": 30, "end": 150}]}]
        assert r["anomalous"] is True

    def test_touching_interval_not_conflict(self):
        # 组3[120,240) 与占用 [60,120) 端点相接：不冲突
        occ = [{"id": 8, "frequency": 1, "start": 60, "end": 120}]
        r = check({1: 1, 2: 4, 3: 1}, occ)
        # 与组1[0,120) 相交（60<120），组1 撞占用；组3 端点相接不算
        conflict_groups = {c["group_id"] for c in r["occupation_conflicts"]}
        assert conflict_groups == {1}

    def test_different_frequency_no_conflict(self):
        occ = [{"id": 9, "frequency": 5, "start": 0, "end": 240}]
        r = check({1: 1, 2: 4, 3: 1}, occ)
        assert r["occupation_conflicts"] == []

    def test_multiple_occupations_listed(self):
        # occ1 [60,120) 与组1、组2都相交；occ2 [120,180) 与组2相交、
        # 与组1[0,120) 端点相接不算
        occs = [
            {"id": 1, "frequency": 4, "start": 60, "end": 120},
            {"id": 2, "frequency": 4, "start": 120, "end": 180},
        ]
        r = check({1: 4, 2: 4, 3: 1}, occs)
        by_group = {c["group_id"]: [o["id"] for o in c["occupations"]]
                    for c in r["occupation_conflicts"]}
        assert by_group == {1: [1], 2: [1, 2]}


class TestSummary:
    def test_counts(self):
        occs = [{"id": 1, "frequency": 2, "start": 0, "end": 240}]
        # 组1=99 不可用且偏离；组2=2 偏离并撞占用；组3=5 偏离；
        # 干扰边 1-2 |99-2| 满足、2-3 |2-5|=3 恰好满足
        r = check({1: 99, 2: 2, 3: 5}, occs)
        assert r["summary"] == {
            "groups": 3, "deviations": 3, "unavailable": 1,
            "interferences": 0, "occupation_conflicts": 1}
        assert r["anomalous"] is True
