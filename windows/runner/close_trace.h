#ifndef RUNNER_CLOSE_TRACE_H_
#define RUNNER_CLOSE_TRACE_H_

#include <windows.h>
#include <chrono>
#include <cstdio>

// Opt-in diagnostics only; no document contents or file paths are logged.
inline void TraceClose(const char* stage) {
  static const bool enabled = [] {
    wchar_t value[2] = {};
    return GetEnvironmentVariableW(L"MDREADER_CLOSE_TRACE", value, 2) == 1 &&
           value[0] == L'1';
  }();
  if (!enabled) return;
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
  char message[256];
  std::snprintf(message, sizeof(message), "[close pid=%lu ms=%lld] %s\n",
                static_cast<unsigned long>(GetCurrentProcessId()),
                static_cast<long long>(ms), stage);
  std::fputs(message, stderr);
  std::fflush(stderr);
  OutputDebugStringA(message);
}

#endif  // RUNNER_CLOSE_TRACE_H_
