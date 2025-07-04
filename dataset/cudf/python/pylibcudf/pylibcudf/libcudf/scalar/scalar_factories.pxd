# Copyright (c) 2024-2025, NVIDIA CORPORATION.
from libcpp.memory cimport unique_ptr
from libcpp.string cimport string
from pylibcudf.exception_handler cimport libcudf_exception_handler
from pylibcudf.libcudf.types cimport data_type
from pylibcudf.libcudf.column.column_view cimport column_view
from pylibcudf.libcudf.scalar.scalar cimport scalar
from pylibcudf.libcudf.fixed_point.fixed_point cimport scale_type
from pylibcudf.libcudf.types cimport int128 as int128_t


cdef extern from "cudf/scalar/scalar_factories.hpp" namespace "cudf" nogil:
    cdef unique_ptr[scalar] make_string_scalar(
        const string & _string
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_fixed_width_scalar[T](
        T value
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_fixed_point_scalar[T](
        int128_t value,
        scale_type scale,
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_numeric_scalar(
        data_type type_
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_timestamp_scalar(
        data_type type_
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_empty_scalar_like(
        const column_view &
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_duration_scalar(
        data_type type_
    ) except +libcudf_exception_handler
    cdef unique_ptr[scalar] make_default_constructed_scalar(
        data_type type_
    ) except +libcudf_exception_handler
