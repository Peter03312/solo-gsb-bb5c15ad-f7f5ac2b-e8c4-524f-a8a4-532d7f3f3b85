"""请求体的 Pydantic 模型。"""

from __future__ import annotations

from pydantic import BaseModel, Field


class SessionCreate(BaseModel):
    name: str = Field(min_length=1)
    frequencies: list[int] = Field(
        min_length=1, description="场次可用的整数频点集合")


class GroupCreate(BaseModel):
    name: str = ""
    start: int = Field(description="使用时段起点（分钟，左闭）")
    end: int = Field(description="使用时段终点（分钟，右开）")


class InterferenceCreate(BaseModel):
    group_a: int
    group_b: int
    min_separation: int = Field(description="正整数最小频点间距")


class Lock(BaseModel):
    group_id: int
    frequency: int


class PlanCreate(BaseModel):
    base_version: int = Field(
        ge=0, description="所见版本号；无发布版时为 0，否则为最新发布版号")
    locks: list[Lock] = Field(default_factory=list)


class RetuneRequest(BaseModel):
    start_version: int = Field(
        ge=1, description="起始发布版版本号（同一场次内）")
    target_version: int = Field(
        ge=1, description="目标发布版版本号（同一场次内）")
    fixed_groups: list[int] = Field(
        default_factory=list,
        description="切换期间不可调频的组编号；其在两版中的频点必须相同")


class OccupationCreate(BaseModel):
    frequency: int = Field(
        description="被其他设备占用的可用频点（须属于场次可用集合）")
    start: int = Field(description="占用时段起点（分钟，左闭）")
    end: int = Field(description="占用时段终点（分钟，右开）")


class Reading(BaseModel):
    group_id: int = Field(description="设备组编号")
    frequency: int = Field(
        description="该组实测整数频点；不在可用集合内也照样记录并标明异常")


class MeasurementCreate(BaseModel):
    plan_version: int = Field(
        ge=1, description="核对所用的指定发布版号（须为该场次已发布版本）")
    batch_no: int = Field(
        ge=1, description="该场次递增批次号；低于已记录最新批次将被拒绝")
    readings: list[Reading] = Field(
        min_length=1, description="每个设备组一条实测频点；组集合须与"
                                  "指定发布版及场次当前组集合一致")
