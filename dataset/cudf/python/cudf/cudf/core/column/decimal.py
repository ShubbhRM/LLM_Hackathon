# Copyright (c) 2021-2025, NVIDIA CORPORATION.

from __future__ import annotations

import warnings
from decimal import Decimal
from typing import TYPE_CHECKING, Any, cast

import cupy as cp
import numpy as np
import pandas as pd
import pyarrow as pa

import pylibcudf as plc

import cudf
from cudf.api.types import is_scalar
from cudf.core._internals import binaryop
from cudf.core.buffer import acquire_spill_lock, as_buffer
from cudf.core.column.column import ColumnBase, pa_mask_buffer_to_mask
from cudf.core.column.numerical_base import NumericalBaseColumn
from cudf.core.dtypes import (
    Decimal32Dtype,
    Decimal64Dtype,
    Decimal128Dtype,
    DecimalDtype,
    is_decimal128_dtype,
)
from cudf.core.mixins import BinaryOperand
from cudf.utils.dtypes import (
    CUDF_STRING_DTYPE,
    cudf_dtype_to_pa_type,
    get_dtype_of_same_kind,
    get_dtype_of_same_type,
    pyarrow_dtype_to_cudf_dtype,
)
from cudf.utils.scalar import pa_scalar_to_plc_scalar

if TYPE_CHECKING:
    from typing_extensions import Self

    from cudf._typing import ColumnBinaryOperand, ColumnLike, Dtype, ScalarLike
    from cudf.core.buffer import Buffer
    from cudf.core.column.numerical import NumericalColumn
    from cudf.core.column.string import StringColumn


def _to_plc_scalar(scalar: int | Decimal, dtype: DecimalDtype) -> plc.Scalar:
    pa_scalar = pa.scalar(scalar, type=dtype.to_arrow())
    plc_scalar = pa_scalar_to_plc_scalar(pa_scalar)
    if isinstance(dtype, (Decimal32Dtype, Decimal64Dtype)):
        # pyarrow only supports decimal128
        if isinstance(dtype, Decimal32Dtype):
            plc_type = plc.DataType(plc.TypeId.DECIMAL32, -dtype.scale)
        elif isinstance(dtype, Decimal64Dtype):
            plc_type = plc.DataType(plc.TypeId.DECIMAL64, -dtype.scale)
        plc_column = plc.unary.cast(
            plc.Column.from_scalar(plc_scalar, 1), plc_type
        )
        plc_scalar = plc.copying.get_element(plc_column, 0)
    return plc_scalar


class DecimalBaseColumn(NumericalBaseColumn):
    """Base column for decimal32, decimal64 or decimal128 columns"""

    _VALID_BINARY_OPERATIONS = BinaryOperand._SUPPORTED_BINARY_OPERATIONS

    def __init__(
        self,
        data: Buffer,
        size: int,
        dtype: DecimalDtype,
        mask: Buffer | None = None,
        offset: int = 0,
        null_count: int | None = None,
        children: tuple = (),
    ):
        if not isinstance(size, int):
            raise ValueError("Must specify an integer size")
        if not isinstance(dtype, DecimalDtype):
            raise ValueError(f"{dtype=} must be a DecimalDtype instance")
        super().__init__(
            data=data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
            children=children,
        )

    @property
    def __cuda_array_interface__(self):
        raise NotImplementedError(
            "Decimals are not yet supported via `__cuda_array_interface__`"
        )

    def element_indexing(self, index: int):
        result = super().element_indexing(index)
        if isinstance(result, pa.Scalar):
            return result.as_py()
        return result

    def as_decimal_column(
        self,
        dtype: DecimalDtype,
    ) -> DecimalBaseColumn:
        if isinstance(dtype, DecimalDtype) and dtype.scale < self.dtype.scale:
            warnings.warn(
                "cuDF truncates when downcasting decimals to a lower scale. "
                "To round, use Series.round() or DataFrame.round()."
            )

        if dtype == self.dtype:
            return self
        return self.cast(dtype=dtype)  # type: ignore[return-value]

    def as_string_column(self, dtype) -> StringColumn:
        if len(self) > 0:
            with acquire_spill_lock():
                plc_column = (
                    plc.strings.convert.convert_fixed_point.from_fixed_point(
                        self.to_pylibcudf(mode="read"),
                    )
                )
                return type(self).from_pylibcudf(plc_column)  # type: ignore[return-value]
        else:
            return cast(
                cudf.core.column.StringColumn,
                cudf.core.column.column_empty(0, dtype=CUDF_STRING_DTYPE),
            )

    def __pow__(self, other):
        if isinstance(other, int):
            if other == 0:
                res = cudf.core.column.as_column(
                    1, dtype=self.dtype, length=len(self)
                )
                if self.nullable:
                    res = res.set_mask(self.mask)
                return res
            elif other < 0:
                raise TypeError("Power of negative integers not supported.")
            res = self
            for _ in range(other - 1):
                res = self * res
            return res
        else:
            raise NotImplementedError(
                f"__pow__ of types {self.dtype} and {type(other)} is "
                "not yet implemented."
            )

    # Decimals in libcudf don't support truediv, see
    # https://github.com/rapidsai/cudf/pull/7435 for explanation.
    def __truediv__(self, other):
        return self._binaryop(other, "__div__")

    def __rtruediv__(self, other):
        return self._binaryop(other, "__rdiv__")

    def _binaryop(self, other: ColumnBinaryOperand, op: str):
        reflect, op = self._check_reflected_op(op)
        other, other_cudf_dtype = self._normalize_binop_operand(other)  # type: ignore[assignment]
        if other is NotImplemented:
            return NotImplemented
        if reflect:
            lhs_dtype = other_cudf_dtype
            rhs_dtype = self.dtype
            lhs = other
            rhs = self
        else:
            lhs_dtype = self.dtype
            rhs_dtype = other_cudf_dtype
            lhs = self
            rhs = other  # type: ignore[assignment]

        # Binary Arithmetics between decimal columns. `Scale` and `precision`
        # are computed outside of libcudf
        if op in {"__add__", "__sub__", "__mul__", "__div__"}:
            output_type = _get_decimal_type(lhs_dtype, rhs_dtype, op)
            new_lhs_dtype = type(output_type)(
                lhs_dtype.precision, lhs_dtype.scale
            )
            new_rhs_dtype = type(output_type)(
                rhs_dtype.precision, rhs_dtype.scale
            )
            if isinstance(lhs, (int, Decimal)):
                lhs = _to_plc_scalar(lhs, new_lhs_dtype)
            else:
                lhs = lhs.astype(new_lhs_dtype)
            if isinstance(rhs, (int, Decimal)):
                rhs = _to_plc_scalar(rhs, new_rhs_dtype)
            else:
                rhs = rhs.astype(new_rhs_dtype)  # type: ignore[assignment]
            result = binaryop.binaryop(lhs, rhs, op, output_type)
            # libcudf doesn't support precision, so result.dtype doesn't
            # maintain output_type.precision
            result.dtype.precision = output_type.precision
            return result
        elif op in {
            "__eq__",
            "__ne__",
            "__lt__",
            "__gt__",
            "__le__",
            "__ge__",
        }:
            if isinstance(rhs, (int, Decimal)):
                rhs = _to_plc_scalar(rhs, self.dtype)
            return binaryop.binaryop(
                lhs,
                rhs,
                op,
                get_dtype_of_same_kind(self.dtype, np.dtype(np.bool_)),
            )
        else:
            raise TypeError(
                f"{op} not supported for the following dtypes: "
                f"{self.dtype}, {other_cudf_dtype}"
            )

    def _cast_setitem_value(self, value: Any) -> plc.Scalar | ColumnBase:
        if isinstance(value, np.integer):
            value = value.item()
        if is_scalar(value):
            return self._scalar_to_plc_scalar(value)
        return super()._cast_setitem_value(value)

    def _scalar_to_plc_scalar(self, scalar: ScalarLike) -> plc.Scalar:
        """Return a pylibcudf.Scalar that matches the type of self.dtype"""
        if not isinstance(scalar, pa.Scalar):
            # e.g casting int to decimal type isn't allow, but OK in the constructor?
            pa_scalar = pa.scalar(
                scalar, type=cudf_dtype_to_pa_type(self.dtype)
            )
        else:
            pa_scalar = scalar.cast(cudf_dtype_to_pa_type(self.dtype))
        plc_scalar = pa_scalar_to_plc_scalar(pa_scalar)
        if isinstance(self.dtype, (Decimal32Dtype, Decimal64Dtype)):
            # pyarrow.Scalar only supports Decimal128 so conversion
            # from pyarrow would only return a pylibcudf.Scalar with Decimal128
            col = ColumnBase.from_pylibcudf(
                plc.Column.from_scalar(plc_scalar, 1)
            ).astype(self.dtype)
            return plc.copying.get_element(col.to_pylibcudf(mode="read"), 0)
        return plc_scalar

    def _validate_fillna_value(
        self, fill_value: ScalarLike | ColumnLike
    ) -> plc.Scalar | ColumnBase:
        """Align fill_value for .fillna based on column type."""
        if isinstance(fill_value, (int, Decimal)):
            return super()._validate_fillna_value(fill_value)
        elif isinstance(fill_value, ColumnBase) and (
            isinstance(self.dtype, DecimalDtype) or self.dtype.kind in "iu"
        ):
            return super()._validate_fillna_value(fill_value)
        raise TypeError(
            "Decimal columns only support using fillna with decimal and "
            "integer values"
        )

    def _normalize_binop_operand(
        self, other: Any
    ) -> tuple[int | Decimal | ColumnBase, DecimalDtype]:
        # TODO: Once pyarrow 19 is the minimum version, we can remove the
        # passing the DecimalDtype since pyarrow scalars support decimal32/64 types
        if isinstance(other, ColumnBase):
            if not isinstance(other, NumericalBaseColumn):
                return NotImplemented, self.dtype
            elif other.dtype.kind in "fb":
                raise TypeError(
                    "Decimal columns only support binary operations with "
                    "integer numerical columns."
                )
            elif other.dtype.kind in "iu":
                other = other.astype(
                    type(self.dtype)(self.dtype.MAX_PRECISION, 0)
                )
            elif not isinstance(self.dtype, other.dtype.__class__):
                # This branch occurs if we have a DecimalBaseColumn of a
                # different size (e.g. 64 instead of 32).
                if _same_precision_and_scale(self.dtype, other.dtype):
                    other = other.astype(self.dtype)
            return other, other.dtype
        elif isinstance(other, (int, Decimal)):
            return other, self.dtype._from_decimal(Decimal(other))
        return super()._normalize_binop_operand(other), self.dtype

    def as_numerical_column(self, dtype: np.dtype) -> NumericalColumn:
        return self.cast(dtype=dtype)  # type: ignore[return-value]


class Decimal32Column(DecimalBaseColumn):
    def __init__(
        self,
        data: Buffer,
        size: int,
        dtype: Decimal32Dtype,
        mask: Buffer | None = None,
        offset: int = 0,
        null_count: int | None = None,
        children: tuple = (),
    ):
        if not isinstance(dtype, Decimal32Dtype):
            raise ValueError(f"{dtype=} must be a Decimal32Dtype instance")
        super().__init__(
            data=data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
            children=children,
        )

    @classmethod
    def from_arrow(cls, data: pa.Array) -> Self:
        dtype = Decimal32Dtype.from_arrow(data.type)
        mask_buf = data.buffers()[0]
        mask = (
            mask_buf
            if mask_buf is None
            else pa_mask_buffer_to_mask(mask_buf, len(data))
        )
        data_128 = cp.array(np.frombuffer(data.buffers()[1]).view("int32"))
        data_32 = data_128[::4].copy()
        return cls(
            data=as_buffer(data_32.view("uint8")),
            size=len(data),
            dtype=dtype,
            offset=data.offset,
            mask=mask,
        )

    def to_arrow(self) -> pa.Array:
        data_buf_32 = np.array(self.base_data.memoryview()).view("int32")  # type: ignore[union-attr]
        data_buf_128 = np.empty(len(data_buf_32) * 4, dtype="int32")

        # use striding to set the first 32 bits of each 128-bit chunk:
        data_buf_128[::4] = data_buf_32
        # use striding again to set the remaining bits of each 128-bit chunk:
        # 0 for non-negative values, -1 for negative values:
        data_buf_128[1::4] = np.piecewise(
            data_buf_32, [data_buf_32 < 0], [-1, 0]
        )
        data_buf_128[2::4] = np.piecewise(
            data_buf_32, [data_buf_32 < 0], [-1, 0]
        )
        data_buf_128[3::4] = np.piecewise(
            data_buf_32, [data_buf_32 < 0], [-1, 0]
        )
        data_buf = pa.py_buffer(data_buf_128)
        mask_buf = (
            self.base_mask
            if self.base_mask is None
            else pa.py_buffer(self.base_mask.memoryview())
        )
        return pa.Array.from_buffers(
            type=self.dtype.to_arrow(),
            offset=self._offset,
            length=self.size,
            buffers=[mask_buf, data_buf],
        )

    def _with_type_metadata(
        self: "cudf.core.column.Decimal32Column",
        dtype: Dtype,
    ) -> "cudf.core.column.Decimal32Column":
        if isinstance(dtype, Decimal32Dtype):
            self.dtype.precision = dtype.precision
        if cudf.get_option("mode.pandas_compatible"):
            self._dtype = get_dtype_of_same_type(dtype, self.dtype)
        return self


class Decimal128Column(DecimalBaseColumn):
    def __init__(
        self,
        data: Buffer,
        size: int,
        dtype: Decimal128Dtype,
        mask: Buffer | None = None,
        offset: int = 0,
        null_count: int | None = None,
        children: tuple = (),
    ):
        if (
            not cudf.get_option("mode.pandas_compatible")
            and not isinstance(dtype, Decimal128Dtype)
        ) or (
            cudf.get_option("mode.pandas_compatible")
            and not is_decimal128_dtype(dtype)
        ):
            raise ValueError(f"{dtype=} must be a Decimal128Dtype instance")
        super().__init__(
            data=data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
            children=children,
        )

    @classmethod
    def from_arrow(cls, data: pa.Array) -> Self:
        result = cast(Decimal128Dtype, super().from_arrow(data))
        result.dtype.precision = data.type.precision
        return result

    def to_arrow(self) -> pa.Array:
        if isinstance(self.dtype, pd.ArrowDtype):
            dtype = pyarrow_dtype_to_cudf_dtype(self.dtype)
        else:
            dtype = self.dtype

        return super().to_arrow().cast(dtype.to_arrow())

    def _with_type_metadata(
        self: "cudf.core.column.Decimal128Column",
        dtype: Dtype,
    ) -> "cudf.core.column.Decimal128Column":
        if isinstance(dtype, Decimal128Dtype):
            self.dtype.precision = dtype.precision
        if cudf.get_option("mode.pandas_compatible"):
            self._dtype = get_dtype_of_same_type(dtype, self.dtype)
        return self


class Decimal64Column(DecimalBaseColumn):
    def __init__(
        self,
        data: Buffer,
        size: int,
        dtype: Decimal64Dtype,
        mask: Buffer | None = None,
        offset: int = 0,
        null_count: int | None = None,
        children: tuple = (),
    ):
        if not isinstance(dtype, Decimal64Dtype):
            raise ValueError(f"{dtype=} must be a Decimal64Dtype instance")
        super().__init__(
            data=data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
            children=children,
        )

    @classmethod
    def from_arrow(cls, data: pa.Array) -> Self:
        dtype = Decimal64Dtype.from_arrow(data.type)
        mask_buf = data.buffers()[0]
        mask = (
            mask_buf
            if mask_buf is None
            else pa_mask_buffer_to_mask(mask_buf, len(data))
        )
        data_128 = cp.array(np.frombuffer(data.buffers()[1]).view("int64"))
        data_64 = data_128[::2].copy()
        return cls(
            data=as_buffer(data_64.view("uint8")),
            size=len(data),
            dtype=dtype,
            offset=data.offset,
            mask=mask,
        )

    def to_arrow(self) -> pa.Array:
        data_buf_64 = np.array(self.base_data.memoryview()).view("int64")  # type: ignore[union-attr]
        data_buf_128 = np.empty(len(data_buf_64) * 2, dtype="int64")

        # use striding to set the first 64 bits of each 128-bit chunk:
        data_buf_128[::2] = data_buf_64
        # use striding again to set the remaining bits of each 128-bit chunk:
        # 0 for non-negative values, -1 for negative values:
        data_buf_128[1::2] = np.piecewise(
            data_buf_64, [data_buf_64 < 0], [-1, 0]
        )
        data_buf = pa.py_buffer(data_buf_128)
        mask_buf = (
            self.base_mask
            if self.base_mask is None
            else pa.py_buffer(self.base_mask.memoryview())
        )
        return pa.Array.from_buffers(
            type=self.dtype.to_arrow(),
            offset=self._offset,
            length=self.size,
            buffers=[mask_buf, data_buf],
        )

    def _with_type_metadata(
        self: "cudf.core.column.Decimal64Column",
        dtype: Dtype,
    ) -> "cudf.core.column.Decimal64Column":
        if isinstance(dtype, Decimal64Dtype):
            self.dtype.precision = dtype.precision
        if cudf.get_option("mode.pandas_compatible"):
            self._dtype = get_dtype_of_same_type(dtype, self.dtype)
        return self


def _get_decimal_type(
    lhs_dtype: DecimalDtype,
    rhs_dtype: DecimalDtype,
    op: str,
) -> DecimalDtype:
    """
    Returns the resulting decimal type after calculating
    precision & scale when performing the binary operation
    `op` for the given dtypes.

    For precision & scale calculations see : https://docs.microsoft.com/en-us/sql/t-sql/data-types/precision-scale-and-length-transact-sql
    """

    # This should at some point be hooked up to libcudf's
    # binary_operation_fixed_point_scale
    # Note: libcudf decimal types don't have a concept of precision

    p1, p2 = lhs_dtype.precision, rhs_dtype.precision
    s1, s2 = lhs_dtype.scale, rhs_dtype.scale

    if op in {"__add__", "__sub__"}:
        scale = max(s1, s2)
        precision = scale + max(p1 - s1, p2 - s2) + 1
        if precision > Decimal128Dtype.MAX_PRECISION:
            precision = Decimal128Dtype.MAX_PRECISION
            scale = Decimal128Dtype.MAX_PRECISION - max(p1 - s1, p2 - s2)
    elif op in {"__mul__", "__div__"}:
        if op == "__mul__":
            scale = s1 + s2
            precision = p1 + p2 + 1
        else:
            scale = max(6, s1 + p2 + 1)
            precision = p1 - s1 + s2 + scale
        if precision > Decimal128Dtype.MAX_PRECISION:
            integral = precision - scale
            if integral < 32:
                scale = min(scale, Decimal128Dtype.MAX_PRECISION - integral)
            elif scale > 6 and integral > 32:
                scale = 6
            precision = Decimal128Dtype.MAX_PRECISION
    else:
        raise NotImplementedError()

    try:
        if isinstance(lhs_dtype, type(rhs_dtype)):
            # SCENARIO 1: If `lhs_dtype` & `rhs_dtype` are same, then try to
            # see if `precision` & `scale` can be fit into this type.
            return lhs_dtype.__class__(precision=precision, scale=scale)
        else:
            # SCENARIO 2: If `lhs_dtype` & `rhs_dtype` are of different dtypes,
            # then try to see if `precision` & `scale` can be fit into the type
            # with greater MAX_PRECISION (i.e., the bigger dtype).
            if lhs_dtype.MAX_PRECISION >= rhs_dtype.MAX_PRECISION:
                return lhs_dtype.__class__(precision=precision, scale=scale)
            else:
                return rhs_dtype.__class__(precision=precision, scale=scale)
    except ValueError:
        # Call to _validate fails, which means we need
        # to goto SCENARIO 3.
        pass

    # SCENARIO 3: If either of the above two scenarios fail, then get the
    # MAX_PRECISION of `lhs_dtype` & `rhs_dtype` so that we can only check
    # and return a dtype that is greater than or equal to input dtype that
    # can fit `precision` & `scale`.
    max_precision = max(lhs_dtype.MAX_PRECISION, rhs_dtype.MAX_PRECISION)
    for decimal_type in (
        Decimal32Dtype,
        Decimal64Dtype,
        Decimal128Dtype,
    ):
        if decimal_type.MAX_PRECISION >= max_precision:
            try:
                return decimal_type(precision=precision, scale=scale)
            except ValueError:
                # Call to _validate fails, which means we need
                # to try the next dtype
                continue

    # if we've reached this point, we cannot create a decimal type without
    # overflow; raise an informative error
    raise ValueError(
        f"Performing {op} between columns of type {lhs_dtype!r} and "
        f"{rhs_dtype!r} would result in overflow"
    )


def _same_precision_and_scale(lhs: DecimalDtype, rhs: DecimalDtype) -> bool:
    return lhs.precision == rhs.precision and lhs.scale == rhs.scale
