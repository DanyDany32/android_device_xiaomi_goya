#include <android/log.h>
#include <stdarg.h>
#include <stdlib.h>

/*
 * Android 15/16 vendor binaries are built against a newer libc++ that expects
 * std::__libcpp_verbose_abort to exist. OrangeFox 14.1's recovery libc++ does
 * not export it, so provide the symbol and keep the message in the kernel log.
 */
extern "C" __attribute__((noreturn, visibility("default")))
void GoyaLibcppVerboseAbort(const char* format, ...)
    __asm__("_ZNSt3__122__libcpp_verbose_abortEPKcz");

void GoyaLibcppVerboseAbort(const char* format, ...) {
    va_list args;
    va_start(args, format);
    __android_log_vprint(ANDROID_LOG_FATAL, "goya-libcxx-compat", format, args);
    va_end(args);
    abort();
}
