# Copyright (c) 2018-2025, NVIDIA CORPORATION.

from __future__ import annotations

import functools
from typing import TYPE_CHECKING, Any, cast

import cupy as cp
import numpy as np
import pyarrow as pa
from typing_extensions import Self

import pylibcudf as plc

import cudf
from cudf.api.types import is_scalar
from cudf.core._internals import binaryop
from cudf.core.buffer import acquire_spill_lock, as_buffer
from cudf.core.column.column import ColumnBase, as_column, column_empty
from cudf.core.column.numerical_base import NumericalBaseColumn
from cudf.core.dtypes import CategoricalDtype
from cudf.core.mixins import BinaryOperand
from cudf.utils.dtypes import (
    CUDF_STRING_DTYPE,
    cudf_dtype_from_pa_type,
    cudf_dtype_to_pa_type,
    dtype_to_pylibcudf_type,
    find_common_type,
    get_dtype_of_same_kind,
    get_dtype_of_same_type,
    min_signed_type,
    min_unsigned_type,
)
from cudf.utils.scalar import pa_scalar_to_plc_scalar
from cudf.utils.utils import _is_null_host_scalar, is_na_like

if TYPE_CHECKING:
    from collections.abc import Sequence

    from cudf._typing import (
        ColumnBinaryOperand,
        ColumnLike,
        Dtype,
        DtypeObj,
        ScalarLike,
    )
    from cudf.core.buffer import Buffer
    from cudf.core.column import DecimalBaseColumn
    from cudf.core.column.datetime import DatetimeColumn
    from cudf.core.column.string import StringColumn
    from cudf.core.column.timedelta import TimeDeltaColumn
    from cudf.core.dtypes import DecimalDtype


class NumericalColumn(NumericalBaseColumn):
    """
    A Column object for Numeric types.

    Parameters
    ----------
    data : Buffer
    dtype : np.dtype
        The dtype associated with the data Buffer
    mask : Buffer, optional
    """

    _VALID_BINARY_OPERATIONS = BinaryOperand._SUPPORTED_BINARY_OPERATIONS

    def __init__(
        self,
        data: Buffer,
        size: int | None,
        dtype: np.dtype,
        mask: Buffer | None = None,
        offset: int = 0,
        null_count: int | None = None,
        children: tuple = (),
    ):
        if (
            cudf.get_option("mode.pandas_compatible")
            and dtype.kind not in "iufb"
        ) or (
            not cudf.get_option("mode.pandas_compatible")
            and not (isinstance(dtype, np.dtype) and dtype.kind in "iufb")
        ):
            raise ValueError(
                f"dtype must be a floating, integer or boolean dtype. Got: {dtype}"
            )

        if data.size % dtype.itemsize:
            raise ValueError("Buffer size must be divisible by element size")
        if size is None:
            size = (data.size // dtype.itemsize) - offset
        super().__init__(
            data=data,
            size=size,
            dtype=dtype,
            mask=mask,
            offset=offset,
            null_count=null_count,
            children=children,
        )

    def _clear_cache(self):
        super()._clear_cache()
        try:
            del self.nan_count
        except AttributeError:
            pass

    def __contains__(self, item: ScalarLike) -> bool:
        """
        Returns True if column contains item, else False.
        """
        # Handles improper item types
        # Fails if item is of type None, so the handler.
        try:
            search_item = self.dtype.type(item)
            if search_item != item and self.dtype.kind != "f":
                return False
        except (TypeError, ValueError):
            return False
        # TODO: Use `scalar`-based `contains` wrapper
        return self.contains(as_column([search_item], dtype=self.dtype)).any()

    def indices_of(self, value: ScalarLike) -> NumericalColumn:
        if isinstance(value, (bool, np.bool_)) and self.dtype.kind != "b":
            raise ValueError(
                f"Cannot use a {type(value).__name__} to find an index of "
                f"a {self.dtype} Index."
            )
        elif (
            self.dtype.kind in {"c", "f"}
            and isinstance(value, (float, np.floating))
            and np.isnan(value)
        ):
            return self.isnan().indices_of(True)
        else:
            return super().indices_of(value)

    def has_nulls(self, include_nan: bool = False) -> bool:
        return bool(self.null_count != 0) or (
            include_nan and bool(self.nan_count != 0)
        )

    def element_indexing(self, index: int):
        result = super().element_indexing(index)
        if isinstance(result, pa.Scalar):
            return self.dtype.type(result.as_py())
        return result

    def _cast_setitem_value(self, value: Any) -> plc.Scalar | ColumnBase:
        if is_scalar(value):
            if value is cudf.NA or value is None:
                scalar = pa.scalar(
                    None, type=cudf_dtype_to_pa_type(self.dtype)
                )
            else:
                try:
                    scalar = pa.scalar(value)
                except ValueError as err:
                    raise TypeError(
                        f"Cannot set value of type {type(value)} to column of type {self.dtype}"
                    ) from err
            is_scalar_bool = pa.types.is_boolean(scalar.type)
            if (is_scalar_bool and self.dtype.kind != "b") or (
                not is_scalar_bool and self.dtype.kind == "b"
            ):
                raise TypeError(
                    f"Invalid value {value} for dtype {self.dtype}"
                )
            return pa_scalar_to_plc_scalar(
                scalar.cast(cudf_dtype_to_pa_type(self.dtype))
            )
        else:
            col = as_column(value)
            if col.dtype.kind == "b" and self.dtype.kind != "b":
                raise TypeError(
                    f"Invalid value {value} for dtype {self.dtype}"
                )
            return col.astype(self.dtype)

    @acquire_spill_lock()
    def transform(self, compiled_op, np_dtype: np.dtype) -> ColumnBase:
        plc_column = plc.transform.transform(
            [self.to_pylibcudf(mode="read")],
            compiled_op[0],
            plc.column._datatype_from_dtype_desc(np_dtype.str[1:]),
            True,
        )
        return type(self).from_pylibcudf(plc_column)

    def __invert__(self):
        if self.dtype.kind in "ui":
            return self.unary_operator("invert")
        elif self.dtype.kind == "b":
            return self.unary_operator("not")
        else:
            return super().__invert__()

    def _binaryop(self, other: ColumnBinaryOperand, op: str) -> ColumnBase:
        int_float_dtype_mapping = {
            np.int8: np.float32,
            np.int16: np.float32,
            np.int32: np.float32,
            np.int64: np.float64,
            np.uint8: np.float32,
            np.uint16: np.float32,
            np.uint32: np.float64,
            np.uint64: np.float64,
            np.bool_: np.float32,
        }

        out_dtype = None
        if op in {"__truediv__", "__rtruediv__"}:
            # Division with integer types results in a suitable float.
            if truediv_type := int_float_dtype_mapping.get(self.dtype.type):
                return self.astype(np.dtype(truediv_type))._binaryop(other, op)
        elif op in {
            "__lt__",
            "__gt__",
            "__le__",
            "__ge__",
            "__eq__",
            "__ne__",
        }:
            out_dtype = get_dtype_of_same_kind(self.dtype, np.dtype(np.bool_))

            # If `other` is a Python integer and it is out-of-bounds
            # promotion could fail but we can trivially define the result
            # in terms of `notnull` or `NULL_NOT_EQUALS`.
            if type(other) is int and self.dtype.kind in "iu":
                truthiness = None
                iinfo = np.iinfo(self.dtype)
                if iinfo.min > other:
                    truthiness = op in {"__ne__", "__gt__", "__ge__"}
                elif iinfo.max < other:
                    truthiness = op in {"__ne__", "__lt__", "__le__"}

                # Compare with minimum value so that the result is true/false
                if truthiness is True:
                    other = iinfo.min
                    op = "__ge__"
                elif truthiness is False:
                    other = iinfo.min
                    op = "__lt__"

        elif op in {"NULL_EQUALS", "NULL_NOT_EQUALS"}:
            out_dtype = get_dtype_of_same_kind(self.dtype, np.dtype(np.bool_))

        reflect, op = self._check_reflected_op(op)
        if (other := self._normalize_binop_operand(other)) is NotImplemented:
            return NotImplemented
        other_cudf_dtype = (
            cudf_dtype_from_pa_type(other.type)
            if isinstance(other, pa.Scalar)
            else other.dtype
        )

        if out_dtype is None:
            out_dtype = find_common_type((self.dtype, other_cudf_dtype))
            if op in {"__mod__", "__floordiv__"}:
                tmp = self if reflect else other
                tmp_dtype = self.dtype if reflect else other_cudf_dtype
                # Guard against division by zero for integers.
                if tmp_dtype.kind in "iu" and (
                    (isinstance(tmp, NumericalColumn) and 0 in tmp)
                    or (isinstance(tmp, pa.Scalar) and tmp.as_py() == 0)
                ):
                    out_dtype = get_dtype_of_same_kind(
                        out_dtype, np.dtype(np.float64)
                    )

        if op in {"__and__", "__or__", "__xor__"}:
            if self.dtype.kind == "f" or other_cudf_dtype.kind == "f":
                raise TypeError(
                    f"Operation 'bitwise {op[2:-2]}' not supported between "
                    f"{self.dtype.type.__name__} and "
                    f"{other_cudf_dtype.type.__name__}"
                )
            if self.dtype.kind == "b" or other_cudf_dtype.kind == "b":
                out_dtype = get_dtype_of_same_kind(
                    out_dtype, np.dtype(np.bool_)
                )

        elif (
            op == "__pow__"
            and self.dtype.kind in "iu"
            and (other_cudf_dtype.kind in "iu")
        ):
            op = "INT_POW"

        lhs, rhs = (other, self) if reflect else (self, other)

        if isinstance(lhs, pa.Scalar):
            lhs = pa_scalar_to_plc_scalar(lhs)
        elif isinstance(rhs, pa.Scalar):
            rhs = pa_scalar_to_plc_scalar(rhs)
        return binaryop.binaryop(lhs, rhs, op, out_dtype)

    def nans_to_nulls(self: Self) -> Self:
        # Only floats can contain nan.
        if self.dtype.kind != "f" or self.nan_count == 0:
            return self
        with acquire_spill_lock():
            mask, _ = plc.transform.nans_to_nulls(
                self.to_pylibcudf(mode="read")
            )
            return self.set_mask(as_buffer(mask))

    def _normalize_binop_operand(self, other: Any) -> pa.Scalar | ColumnBase:
        if isinstance(other, ColumnBase):
            if not isinstance(other, type(self)):
                return NotImplemented
            return other
        elif isinstance(other, (cp.ndarray, np.ndarray)) and other.ndim == 0:
            other = other[()]

        if is_scalar(other):
            if is_na_like(other):
                return super()._normalize_binop_operand(other)
            if not isinstance(other, (int, float, complex)):
                # Go via NumPy to get the value
                other = np.array(other)
                if other.dtype.kind in "uifc":
                    other = other.item()

            # Try and match pandas and hence numpy. Deduce the common
            # dtype via the _value_ of other, and the dtype of self on NumPy 1.x
            # with NumPy 2, we force weak promotion even for our/NumPy scalars
            # to match pandas 2.2.
            # Weak promotion is not at all simple:
            # np.result_type(0, np.uint8)
            #   => np.uint8
            # np.result_type(np.asarray([0], dtype=np.int64), np.uint8)
            #   => np.int64
            # np.promote_types(np.int64(0), np.uint8)
            #   => np.int64
            # np.promote_types(np.asarray([0], dtype=np.int64).dtype, np.uint8)
            #   => np.int64
            common_dtype = np.result_type(self.dtype, other)  # noqa: TID251
            if common_dtype.kind in {"b", "i", "u", "f"}:
                if self.dtype.kind == "b" and not isinstance(other, bool):
                    common_dtype = min_signed_type(other)
                return pa.scalar(
                    other, type=cudf_dtype_to_pa_type(common_dtype)
                )
            else:
                return NotImplemented
        else:
            return NotImplemented

    @acquire_spill_lock()
    def int2ip(self) -> StringColumn:
        if self.dtype != np.dtype(np.uint32):
            raise TypeError("Only uint32 type can be converted to ip")
        plc_column = plc.strings.convert.convert_ipv4.integers_to_ipv4(
            self.to_pylibcudf(mode="read")
        )
        return type(self).from_pylibcudf(plc_column)  # type: ignore[return-value]

    def as_string_column(self, dtype) -> StringColumn:
        if len(self) == 0:
            return cast(
                cudf.core.column.StringColumn,
                column_empty(0, dtype=CUDF_STRING_DTYPE),
            )
        elif self.dtype.kind == "b":
            conv_func = functools.partial(
                plc.strings.convert.convert_booleans.from_booleans,
                true_string=pa_scalar_to_plc_scalar(pa.scalar("True")),
                false_string=pa_scalar_to_plc_scalar(pa.scalar("False")),
            )
        elif self.dtype.kind in {"i", "u"}:
            conv_func = plc.strings.convert.convert_integers.from_integers
        elif self.dtype.kind == "f":
            conv_func = plc.strings.convert.convert_floats.from_floats
        else:
            raise ValueError(f"No string conversion from type {self.dtype}")

        with acquire_spill_lock():
            return type(self).from_pylibcudf(  # type: ignore[return-value]
                conv_func(self.to_pylibcudf(mode="read"))
            )

    def as_datetime_column(self, dtype: np.dtype) -> DatetimeColumn:
        return cudf.core.column.DatetimeColumn(
            data=self.astype(np.dtype(np.int64)).base_data,  # type: ignore[arg-type]
            dtype=dtype,
            mask=self.base_mask,
            offset=self.offset,
            size=self.size,
        )

    def as_timedelta_column(self, dtype: np.dtype) -> TimeDeltaColumn:
        return cudf.core.column.TimeDeltaColumn(
            data=self.astype(np.dtype(np.int64)).base_data,  # type: ignore[arg-type]
            dtype=dtype,
            mask=self.base_mask,
            offset=self.offset,
            size=self.size,
        )

    def as_decimal_column(self, dtype: DecimalDtype) -> DecimalBaseColumn:
        return self.cast(dtype=dtype)  # type: ignore[return-value]

    def as_numerical_column(self, dtype: Dtype) -> NumericalColumn:
        if dtype == self.dtype:
            return self
        if cudf.get_option("mode.pandas_compatible"):
            if dtype_to_pylibcudf_type(dtype) == dtype_to_pylibcudf_type(
                self.dtype
            ):
                # Short-circuit the cast if the dtypes are equivalent
                # but not the same type object.
                self._dtype = dtype
                return self
        return self.cast(dtype=dtype)  # type: ignore[return-value]

    def all(self, skipna: bool = True) -> bool:
        # If all entries are null the result is True, including when the column
        # is empty.
        result_col = self.nans_to_nulls() if skipna else self
        return super(type(self), result_col).all(skipna=skipna)

    def any(self, skipna: bool = True) -> bool:
        # Early exit for fast cases.
        result_col = self.nans_to_nulls() if skipna else self
        return super(type(self), result_col).any(skipna=skipna)

    @functools.cached_property
    def nan_count(self) -> int:
        if self.dtype.kind != "f":
            return super().nan_count
        return self.isnan().sum()

    def _process_values_for_isin(
        self, values: Sequence
    ) -> tuple[ColumnBase, ColumnBase]:
        try:
            lhs, rhs = super()._process_values_for_isin(values)
        except TypeError:
            # Can remove once dask 25.04 is the minimum version
            # https://github.com/dask/dask/pull/11869
            if isinstance(values, np.ndarray) and values.dtype.kind == "O":
                return super()._process_values_for_isin(values.tolist())
            else:
                raise
        if lhs.dtype != rhs.dtype and rhs.dtype != CUDF_STRING_DTYPE:
            if rhs.can_cast_safely(lhs.dtype):
                rhs = rhs.astype(lhs.dtype)
            elif lhs.can_cast_safely(rhs.dtype):
                lhs = lhs.astype(rhs.dtype)
        return lhs, rhs

    def _can_return_nan(self, skipna: bool | None = None) -> bool:
        return not skipna and self.has_nulls(include_nan=True)

    def _min_column_type(self, expected_type: np.dtype) -> np.dtype:
        """
        Return the smallest dtype which can represent all elements of self.
        """
        if self.null_count == len(self):
            return self.dtype

        min_value, max_value = self.min(), self.max()
        either_is_inf = np.isinf(min_value) or np.isinf(max_value)
        if not either_is_inf and expected_type.kind == "i":
            max_bound_dtype = min_signed_type(max_value)
            min_bound_dtype = min_signed_type(min_value)
            return np.promote_types(max_bound_dtype, min_bound_dtype)
        elif not either_is_inf and expected_type.kind == "u":
            max_bound_dtype = min_unsigned_type(max_value)
            min_bound_dtype = min_unsigned_type(min_value)
            return np.promote_types(max_bound_dtype, min_bound_dtype)
        elif self.dtype.kind == "f" or expected_type.kind == "f":
            return np.promote_types(
                expected_type,
                np.promote_types(
                    np.min_scalar_type(float(max_value)),
                    np.min_scalar_type(float(min_value)),
                ),
            )
        else:
            return self.dtype

    def find_and_replace(
        self,
        to_replace: ColumnLike,
        replacement: ColumnLike,
        all_nan: bool = False,
    ) -> Self:
        """
        Return col with *to_replace* replaced with *value*.
        """

        # If all of `to_replace`/`replacement` are `None`,
        # dtype of `to_replace_col`/`replacement_col`
        # is inferred as `string`, but this is a valid
        # float64 column too, Hence we will need to type-cast
        # to self.dtype.
        to_replace_col = as_column(to_replace)
        if to_replace_col.null_count == len(to_replace_col):
            to_replace_col = to_replace_col.astype(self.dtype)

        replacement_col = as_column(replacement)
        if replacement_col.null_count == len(replacement_col):
            replacement_col = replacement_col.astype(self.dtype)

        if not isinstance(to_replace_col, type(replacement_col)):
            raise TypeError(
                f"to_replace and value should be of same types,"
                f"got to_replace dtype: {to_replace_col.dtype} and "
                f"value dtype: {replacement_col.dtype}"
            )

        if not isinstance(to_replace_col, NumericalColumn) and not isinstance(
            replacement_col, NumericalColumn
        ):
            return self.copy()

        try:
            to_replace_col = _normalize_find_and_replace_input(
                self.dtype, to_replace
            )
        except TypeError:
            # if `to_replace` cannot be normalized to the current dtype,
            # that means no value of `to_replace` is present in self,
            # Hence there is no point of proceeding further.
            return self.copy()

        if all_nan:
            replacement_col = as_column(replacement, dtype=self.dtype)
        else:
            try:
                replacement_col = _normalize_find_and_replace_input(
                    self.dtype, replacement
                )
            except TypeError:
                # Some floating values can never be converted into signed or unsigned integers
                # for those cases, we just need a column of `replacement` constructed
                # with its own type for the final type determination below at `find_common_type`
                # call.
                replacement_col = as_column(
                    replacement,
                    dtype=self.dtype if len(replacement) <= 0 else None,
                )
        common_type = find_common_type(
            (to_replace_col.dtype, replacement_col.dtype, self.dtype)
        )
        if len(replacement_col) == 1 and len(to_replace_col) > 1:
            replacement_col = as_column(
                replacement[0], length=len(to_replace_col), dtype=common_type
            )
        elif len(replacement_col) == 1 and len(to_replace_col) == 0:
            return self.copy()
        replaced = cast(Self, self.astype(common_type))
        df = cudf.DataFrame._from_data(
            {
                "old": to_replace_col.astype(common_type),
                "new": replacement_col.astype(common_type),
            }
        )
        df = df.drop_duplicates(subset=["old"], keep="last", ignore_index=True)
        if df._data["old"].null_count == 1:
            replaced = replaced.fillna(
                df._data["new"]
                .apply_boolean_mask(df._data["old"].isnull())
                .element_indexing(0)
            )
            df = df.dropna(subset=["old"])

        return replaced.replace(df._data["old"], df._data["new"])

    def _validate_fillna_value(
        self, fill_value: ScalarLike | ColumnLike
    ) -> plc.Scalar | ColumnBase:
        """Align fill_value for .fillna based on column type."""
        if is_scalar(fill_value):
            cudf_obj = ColumnBase.from_pylibcudf(
                plc.Column.from_scalar(
                    pa_scalar_to_plc_scalar(pa.scalar(fill_value)), 1
                )
            )
            if not cudf_obj.can_cast_safely(self.dtype):
                raise TypeError(
                    f"Cannot safely cast non-equivalent "
                    f"{type(fill_value).__name__} to {self.dtype.name}"
                )
            return super()._validate_fillna_value(fill_value)
        else:
            cudf_obj = as_column(fill_value, nan_as_null=False)
            if not cudf_obj.can_cast_safely(self.dtype):  # type: ignore[attr-defined]
                raise TypeError(
                    f"Cannot safely cast non-equivalent "
                    f"{cudf_obj.dtype.type.__name__} to "
                    f"{self.dtype.type.__name__}"
                )
            return cudf_obj.astype(self.dtype)

    def can_cast_safely(self, to_dtype: DtypeObj) -> bool:
        """
        Returns true if all the values in self can be
        safely cast to dtype
        """
        # Convert potential pandas extension dtypes to numpy dtypes
        # For example, convert Int32Dtype to np.dtype('int32')
        self_dtype_numpy = (
            np.dtype(self.dtype.numpy_dtype)
            if hasattr(self.dtype, "numpy_dtype")
            else self.dtype
        )
        to_dtype_numpy = (
            np.dtype(to_dtype.numpy_dtype)
            if hasattr(to_dtype, "numpy_dtype")
            else to_dtype
        )

        if self_dtype_numpy.kind == to_dtype_numpy.kind:
            # Check if self dtype can be safely cast to to_dtype
            # For same kinds, we can compare the sizes
            if self_dtype_numpy <= to_dtype_numpy:
                return True
            else:
                if self_dtype_numpy.kind == "f":
                    # Exclude 'np.inf', '-np.inf'
                    not_inf = (self != np.inf) & (self != -np.inf)
                    col = self.apply_boolean_mask(not_inf)
                else:
                    col = self

                min_ = col.min()
                # TODO: depending on implementation of cudf scalar and future
                # refactor of min/max, change the test method
                if np.isnan(min_):
                    # Column contains only infs
                    return True

                # Kinds are the same but to_dtype is smaller
                if "float" in to_dtype_numpy.name:
                    finfo = np.finfo(to_dtype_numpy)
                    lower_, upper_ = finfo.min, finfo.max
                elif "int" in to_dtype_numpy.name:
                    iinfo = np.iinfo(to_dtype_numpy)
                    lower_, upper_ = iinfo.min, iinfo.max

                return (min_ >= lower_) and (col.max() < upper_)

        # want to cast int to uint
        elif self_dtype_numpy.kind == "i" and to_dtype_numpy.kind == "u":
            i_max_ = np.iinfo(self_dtype_numpy).max
            u_max_ = np.iinfo(to_dtype_numpy).max

            return (self.min() >= 0) and (
                (i_max_ <= u_max_) or (self.max() < u_max_)
            )

        # want to cast uint to int
        elif self_dtype_numpy.kind == "u" and to_dtype_numpy.kind == "i":
            u_max_ = np.iinfo(self_dtype_numpy).max
            i_max_ = np.iinfo(to_dtype_numpy).max

            return (u_max_ <= i_max_) or (self.max() < i_max_)

        # want to cast int to float
        elif (
            self_dtype_numpy.kind in {"i", "u"} and to_dtype_numpy.kind == "f"
        ):
            info = np.finfo(to_dtype_numpy)
            biggest_exact_int = 2 ** (info.nmant + 1)
            if (self.min() >= -biggest_exact_int) and (
                self.max() <= biggest_exact_int
            ):
                return True
            else:
                filled = self.fillna(0)
                return (
                    filled.astype(to_dtype).astype(filled.dtype) == filled
                ).all()

        # want to cast float to int:
        elif self_dtype_numpy.kind == "f" and to_dtype_numpy.kind in {
            "i",
            "u",
        }:
            if self.nan_count > 0:
                return False
            iinfo = np.iinfo(to_dtype_numpy)
            min_, max_ = iinfo.min, iinfo.max

            # best we can do is hope to catch it here and avoid compare
            # Use Python floats, which have precise comparison for float64.
            # NOTE(seberg): it would make sense to limit to the mantissa range.
            if (float(self.min()) >= min_) and (float(self.max()) <= max_):
                filled = self.fillna(0)
                return (filled % 1 == 0).all()
            else:
                return False

        return False

    def _with_type_metadata(
        self: Self,
        dtype: Dtype,
    ) -> ColumnBase:
        if isinstance(dtype, CategoricalDtype):
            codes = cudf.core.column.categorical.as_unsigned_codes(
                len(dtype.categories), self
            )
            return cudf.core.column.CategoricalColumn(
                data=None,
                size=self.size,
                dtype=dtype,
                mask=self.base_mask,
                offset=self.offset,
                null_count=self.null_count,
                children=(codes,),
            )
        if cudf.get_option("mode.pandas_compatible"):
            self._dtype = get_dtype_of_same_type(dtype, self.dtype)
        return self

    def _reduction_result_dtype(self, reduction_op: str) -> Dtype:
        if reduction_op in {"sum", "product"}:
            if self.dtype.kind == "f":
                return self.dtype
            elif self.dtype.kind == "u":
                return np.dtype("uint64")
            return np.dtype("int64")
        elif reduction_op == "sum_of_squares":
            return find_common_type((self.dtype, np.dtype(np.uint64)))
        elif reduction_op in {"var", "std", "mean"}:
            if self.dtype.kind == "f":
                return self.dtype
            else:
                return np.dtype("float64")

        return super()._reduction_result_dtype(reduction_op)

    @acquire_spill_lock()
    def digitize(self, bins: np.ndarray, right: bool = False) -> Self:
        """Return the indices of the bins to which each value in column belongs.

        Parameters
        ----------
        bins : np.ndarray
            1-D column-like object of bins with same type as `column`, should be
            monotonically increasing.
        right : bool
            Indicates whether interval contains the right or left bin edge.

        Returns
        -------
        A column containing the indices
        """
        if self.dtype != bins.dtype:
            raise ValueError(
                "digitize() expects bins and input column have the same dtype."
            )

        bin_col = as_column(bins, dtype=bins.dtype)
        if bin_col.nullable:
            raise ValueError("`bins` cannot contain null entries.")

        return type(self).from_pylibcudf(  # type: ignore[return-value]
            getattr(plc.search, "lower_bound" if right else "upper_bound")(
                plc.Table([bin_col.to_pylibcudf(mode="read")]),
                plc.Table([self.to_pylibcudf(mode="read")]),
                [plc.types.Order.ASCENDING],
                [plc.types.NullOrder.BEFORE],
            )
        )


def _normalize_find_and_replace_input(
    input_column_dtype: DtypeObj, col_to_normalize: ColumnBase | list
) -> ColumnBase:
    normalized_column = as_column(
        col_to_normalize,
        dtype=input_column_dtype if len(col_to_normalize) <= 0 else None,
    )
    col_to_normalize_dtype = normalized_column.dtype
    if isinstance(col_to_normalize, list):
        if normalized_column.null_count == len(normalized_column):
            normalized_column = normalized_column.astype(input_column_dtype)
        if normalized_column.can_cast_safely(input_column_dtype):
            return normalized_column.astype(input_column_dtype)
        col_to_normalize_dtype = normalized_column._min_column_type(  # type: ignore[attr-defined]
            input_column_dtype
        )
        # Scalar case
        if len(col_to_normalize) == 1:
            if _is_null_host_scalar(col_to_normalize[0]):
                return normalized_column.astype(input_column_dtype)
            if np.isinf(col_to_normalize[0]):
                return normalized_column
            col_to_normalize_casted = np.array(col_to_normalize[0]).astype(
                col_to_normalize_dtype
            )

            if not np.isnan(col_to_normalize_casted) and (
                col_to_normalize_casted != col_to_normalize[0]
            ):
                raise TypeError(
                    f"Cannot safely cast non-equivalent "
                    f"{col_to_normalize[0]} "
                    f"to {input_column_dtype.name}"
                )
        if normalized_column.can_cast_safely(col_to_normalize_dtype):
            return normalized_column.astype(col_to_normalize_dtype)
    elif hasattr(col_to_normalize, "dtype"):
        col_to_normalize_dtype = col_to_normalize.dtype
    else:
        raise TypeError(f"Type {type(col_to_normalize)} not supported")

    if (
        col_to_normalize_dtype.kind == "f"
        and input_column_dtype.kind in {"i", "u"}
    ) or (col_to_normalize_dtype.num > input_column_dtype.num):
        raise TypeError(
            f"Potentially unsafe cast for non-equivalent "
            f"{col_to_normalize_dtype.name} "
            f"to {input_column_dtype.name}"
        )
    if not normalized_column.can_cast_safely(input_column_dtype):
        return normalized_column
    return normalized_column.astype(input_column_dtype)
