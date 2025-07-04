# SPDX-FileCopyrightText: Copyright (c) 2024-2025, NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import pytest

import polars as pl

import pylibcudf as plc

from cudf_polars.containers import Column, DataType
from cudf_polars.dsl.ir import broadcast


@pytest.mark.parametrize("target", [4, None])
def test_broadcast_all_scalar(target):
    columns = [
        Column(
            plc.column_factories.make_numeric_column(
                plc.DataType(plc.TypeId.INT8), 1, plc.MaskState.ALL_VALID
            ),
            name=f"col{i}",
            dtype=DataType(pl.Int8()),
        )
        for i in range(3)
    ]
    result = broadcast(*columns, target_length=target)
    expected = 1 if target is None else target

    assert [c.name for c in result] == [f"col{i}" for i in range(3)]
    assert all(column.size == expected for column in result)


def test_invalid_target_length():
    dtype = DataType(pl.Int8())
    columns = [
        Column(
            plc.column_factories.make_numeric_column(
                dtype.plc, 4, plc.MaskState.ALL_VALID
            ),
            dtype=dtype,
            name=f"col{i}",
        )
        for i in range(3)
    ]
    with pytest.raises(RuntimeError):
        _ = broadcast(*columns, target_length=8)


def test_broadcast_mismatching_column_lengths():
    dtype = DataType(pl.Int8())
    columns = [
        Column(
            plc.column_factories.make_numeric_column(
                dtype.plc, i + 1, plc.MaskState.ALL_VALID
            ),
            dtype=dtype,
            name=f"col{i}",
        )
        for i in range(3)
    ]
    with pytest.raises(RuntimeError):
        _ = broadcast(*columns)


@pytest.mark.parametrize("nrows", [0, 5])
def test_broadcast_with_scalars(nrows):
    dtype = DataType(pl.Int8())
    columns = [
        Column(
            plc.column_factories.make_numeric_column(
                dtype.plc,
                nrows if i == 0 else 1,
                plc.MaskState.ALL_VALID,
            ),
            dtype=dtype,
            name=f"col{i}",
        )
        for i in range(3)
    ]

    result = broadcast(*columns)
    assert [c.name for c in result] == [f"col{i}" for i in range(3)]
    assert all(column.size == nrows for column in result)
