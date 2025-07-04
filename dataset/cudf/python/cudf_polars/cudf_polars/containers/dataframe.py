# SPDX-FileCopyrightText: Copyright (c) 2024-2025, NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0

"""A dataframe, with some properties."""

from __future__ import annotations

from functools import cached_property
from typing import TYPE_CHECKING, cast

import polars as pl

import pylibcudf as plc

from cudf_polars.containers import Column, DataType
from cudf_polars.utils import conversion

if TYPE_CHECKING:
    from collections.abc import Iterable, Mapping, Sequence, Set

    from typing_extensions import Any, CapsuleType, Self

    from cudf_polars.typing import ColumnOptions, DataFrameHeader, Slice


__all__: list[str] = ["DataFrame"]


def _create_polars_column_metadata(
    name: str | None, dtype: pl.DataType
) -> plc.interop.ColumnMetadata:
    """Create ColumnMetadata preserving pl.Struct field names."""
    if isinstance(dtype, pl.Struct):
        children_meta = [
            _create_polars_column_metadata(field.name, field.dtype)
            for field in dtype.fields
        ]
    else:
        children_meta = []
    return plc.interop.ColumnMetadata(name=name, children_meta=children_meta)


# This is also defined in pylibcudf.interop
class _ObjectWithArrowMetadata:
    def __init__(
        self, obj: plc.Table, metadata: list[plc.interop.ColumnMetadata]
    ) -> None:
        self.obj = obj
        self.metadata = metadata

    def __arrow_c_array__(
        self, requested_schema: None = None
    ) -> tuple[CapsuleType, CapsuleType]:
        return self.obj._to_schema(self.metadata), self.obj._to_host_array()


# Pacify the type checker. DataFrame init asserts that all the columns
# have a string name, so let's narrow the type.
class NamedColumn(Column):
    name: str


class DataFrame:
    """A representation of a dataframe."""

    column_map: dict[str, Column]
    table: plc.Table
    columns: list[NamedColumn]

    def __init__(self, columns: Iterable[Column]) -> None:
        columns = list(columns)
        if any(c.name is None for c in columns):
            raise ValueError("All columns must have a name")
        self.columns = [cast(NamedColumn, c) for c in columns]
        self.dtypes = [c.dtype for c in self.columns]
        self.column_map = {c.name: c for c in self.columns}
        self.table = plc.Table([c.obj for c in self.columns])

    def copy(self) -> Self:
        """Return a shallow copy of self."""
        return type(self)(c.copy() for c in self.columns)

    def to_polars(self) -> pl.DataFrame:
        """Convert to a polars DataFrame."""
        # If the arrow table has empty names, from_arrow produces
        # column_$i. But here we know there is only one such column
        # (by construction) and it should have an empty name.
        # https://github.com/pola-rs/polars/issues/11632
        # To guarantee we produce correct names, we therefore
        # serialise with names we control and rename with that map.
        name_map = {f"column_{i}": name for i, name in enumerate(self.column_map)}
        metadata = [
            _create_polars_column_metadata(name, dtype.polars)
            for name, dtype in zip(name_map, self.dtypes, strict=True)
        ]
        table_with_metadata = _ObjectWithArrowMetadata(self.table, metadata)
        df = pl.DataFrame(table_with_metadata)
        return df.rename(name_map).with_columns(
            pl.col(c.name).set_sorted(descending=c.order == plc.types.Order.DESCENDING)
            if c.is_sorted
            else pl.col(c.name)
            for c in self.columns
        )

    @cached_property
    def column_names_set(self) -> frozenset[str]:
        """Return the column names as a set."""
        return frozenset(self.column_map)

    @cached_property
    def column_names(self) -> list[str]:
        """Return a list of the column names."""
        return list(self.column_map)

    @cached_property
    def num_columns(self) -> int:
        """Number of columns."""
        return len(self.column_map)

    @cached_property
    def num_rows(self) -> int:
        """Number of rows."""
        return self.table.num_rows() if self.column_map else 0

    @classmethod
    def from_polars(cls, df: pl.DataFrame) -> Self:
        """
        Create from a polars dataframe.

        Parameters
        ----------
        df
            Polars dataframe to convert

        Returns
        -------
        New dataframe representing the input.
        """
        plc_table = plc.Table.from_arrow(df)
        return cls(
            Column(d_col, name=name, dtype=DataType(h_col.dtype)).copy_metadata(h_col)
            for d_col, h_col, name in zip(
                plc_table.columns(), df.iter_columns(), df.columns, strict=True
            )
        )

    @classmethod
    def from_table(
        cls, table: plc.Table, names: Sequence[str], dtypes: Sequence[DataType]
    ) -> Self:
        """
        Create from a pylibcudf table.

        Parameters
        ----------
        table
            Pylibcudf table to obtain columns from
        names
            Names for the columns
        dtypes
            Dtypes for the columns

        Returns
        -------
        New dataframe sharing data with the input table.

        Raises
        ------
        ValueError
            If the number of provided names does not match the
            number of columns in the table.
        """
        if table.num_columns() != len(names):
            raise ValueError("Mismatching name and table length.")
        return cls(
            Column(c, name=name, dtype=dtype)
            for c, name, dtype in zip(table.columns(), names, dtypes, strict=True)
        )

    @classmethod
    def deserialize(
        cls, header: DataFrameHeader, frames: tuple[memoryview, plc.gpumemoryview]
    ) -> Self:
        """
        Create a DataFrame from a serialized representation returned by `.serialize()`.

        Parameters
        ----------
        header
            The (unpickled) metadata required to reconstruct the object.
        frames
            Two-tuple of frames (a memoryview and a gpumemoryview).

        Returns
        -------
        DataFrame
            The deserialized DataFrame.
        """
        packed_metadata, packed_gpu_data = frames
        table = plc.contiguous_split.unpack_from_memoryviews(
            packed_metadata, packed_gpu_data
        )
        return cls(
            Column(c, **Column.deserialize_ctor_kwargs(kw))
            for c, kw in zip(table.columns(), header["columns_kwargs"], strict=True)
        )

    def serialize(
        self,
    ) -> tuple[DataFrameHeader, tuple[memoryview, plc.gpumemoryview]]:
        """
        Serialize the table into header and frames.

        Follows the Dask serialization scheme with a picklable header (dict) and
        a tuple of frames (in this case a contiguous host and device buffer).

        To enable dask support, dask serializers must be registered

            >>> from cudf_polars.experimental.dask_serialize import register
            >>> register()

        Returns
        -------
        header
            A dict containing any picklable metadata required to reconstruct the object.
        frames
            Two-tuple of frames suitable for passing to `plc.contiguous_split.unpack_from_memoryviews`
        """
        packed = plc.contiguous_split.pack(self.table)

        # Keyword arguments for `Column.__init__`.
        columns_kwargs: list[ColumnOptions] = [
            col.serialize_ctor_kwargs() for col in self.columns
        ]
        header: DataFrameHeader = {
            "columns_kwargs": columns_kwargs,
            "frame_count": 2,
        }
        return header, packed.release()

    def sorted_like(
        self, like: DataFrame, /, *, subset: Set[str] | None = None
    ) -> Self:
        """
        Return a shallow copy with sortedness copied from like.

        Parameters
        ----------
        like
            The dataframe to copy from
        subset
            Optional subset of columns from which to copy data.

        Returns
        -------
        Shallow copy of self with metadata set.

        Raises
        ------
        ValueError
            If there is a name mismatch between self and like.
        """
        if like.column_names != self.column_names:
            raise ValueError("Can only copy from identically named frame")
        subset = self.column_names_set if subset is None else subset
        return type(self)(
            c.sorted_like(other) if c.name in subset else c
            for c, other in zip(self.columns, like.columns, strict=True)
        )

    def with_columns(
        self, columns: Iterable[Column], *, replace_only: bool = False
    ) -> Self:
        """
        Return a new dataframe with extra columns.

        Parameters
        ----------
        columns
            Columns to add
        replace_only
            If true, then only replacements are allowed (matching by name).

        Returns
        -------
        New dataframe

        Notes
        -----
        If column names overlap, newer names replace older ones, and
        appear in the same order as the original frame.
        """
        new = {c.name: c for c in columns}
        if replace_only and not self.column_names_set.issuperset(new.keys()):
            raise ValueError("Cannot replace with non-existing names")
        return type(self)((self.column_map | new).values())

    def discard_columns(self, names: Set[str]) -> Self:
        """Drop columns by name."""
        return type(self)(column for column in self.columns if column.name not in names)

    def select(self, names: Sequence[str] | Mapping[str, Any]) -> Self:
        """Select columns by name returning DataFrame."""
        try:
            return type(self)(self.column_map[name] for name in names)
        except KeyError as e:
            raise ValueError("Can't select missing names") from e

    def rename_columns(self, mapping: Mapping[str, str]) -> Self:
        """Rename some columns."""
        return type(self)(c.rename(mapping.get(c.name, c.name)) for c in self.columns)

    def select_columns(self, names: Set[str]) -> list[Column]:
        """Select columns by name."""
        return [c for c in self.columns if c.name in names]

    def filter(self, mask: Column) -> Self:
        """Return a filtered table given a mask."""
        table = plc.stream_compaction.apply_boolean_mask(self.table, mask.obj)
        return (
            type(self)
            .from_table(table, self.column_names, self.dtypes)
            .sorted_like(self)
        )

    def slice(self, zlice: Slice | None) -> Self:
        """
        Slice a dataframe.

        Parameters
        ----------
        zlice
            optional, tuple of start and length, negative values of start
            treated as for python indexing. If not provided, returns self.

        Returns
        -------
        New dataframe (if zlice is not None) otherwise self (if it is)
        """
        if zlice is None:
            return self
        (table,) = plc.copying.slice(
            self.table, conversion.from_polars_slice(zlice, num_rows=self.num_rows)
        )
        return (
            type(self)
            .from_table(table, self.column_names, self.dtypes)
            .sorted_like(self)
        )
