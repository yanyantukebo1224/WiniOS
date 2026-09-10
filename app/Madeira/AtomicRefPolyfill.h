// SPDX-License-Identifier: MIT
// AtomicRefPolyfill.h - Polyfill for std::atomic_ref on Apple Clang / iOS libc++
#ifndef FEX_ATOMIC_REF_POLYFILL_DEFINED
#define FEX_ATOMIC_REF_POLYFILL_DEFINED

#include <atomic>
#include <cstdint>

#if !defined(__cpp_lib_atomic_ref)
namespace std {
template <typename T>
struct atomic_ref {
    T* ptr;
    explicit atomic_ref(T& obj) noexcept : ptr(&obj) {}
    atomic_ref(const atomic_ref&) noexcept = default;
    atomic_ref& operator=(const atomic_ref&) = delete;

    T load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
        return __atomic_load_n(ptr, static_cast<int>(order));
    }
    void store(T desired, std::memory_order order = std::memory_order_seq_cst) noexcept {
        __atomic_store_n(ptr, desired, static_cast<int>(order));
    }
    bool compare_exchange_strong(T& expected, T desired, std::memory_order success, std::memory_order failure) noexcept {
        return __atomic_compare_exchange_n(ptr, &expected, desired, false, static_cast<int>(success), static_cast<int>(failure));
    }
    bool compare_exchange_strong(T& expected, T desired, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_compare_exchange_n(ptr, &expected, desired, false, static_cast<int>(order), static_cast<int>(order));
    }
    bool compare_exchange_weak(T& expected, T desired, std::memory_order success, std::memory_order failure) noexcept {
        return __atomic_compare_exchange_n(ptr, &expected, desired, true, static_cast<int>(success), static_cast<int>(failure));
    }
    bool compare_exchange_weak(T& expected, T desired, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_compare_exchange_n(ptr, &expected, desired, true, static_cast<int>(order), static_cast<int>(order));
    }
    T fetch_add(T arg, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_fetch_add(ptr, arg, static_cast<int>(order));
    }
    T fetch_sub(T arg, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_fetch_sub(ptr, arg, static_cast<int>(order));
    }
    T fetch_and(T arg, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_fetch_and(ptr, arg, static_cast<int>(order));
    }
    T fetch_or(T arg, std::memory_order order = std::memory_order_seq_cst) noexcept {
        return __atomic_fetch_or(ptr, arg, static_cast<int>(order));
    }
};
}
#endif
#endif // FEX_ATOMIC_REF_POLYFILL_DEFINED
