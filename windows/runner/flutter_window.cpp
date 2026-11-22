#include "flutter_window.h"
#include "close_trace.h"

#include <optional>
#include <cstdio>
#include <map>
#include <cmath>
#include <commctrl.h>
#include <imm.h>
#include <flutter/standard_method_codec.h>
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "imm32.lib")

namespace {
struct InputState {
  POINT caret{};
  bool has_caret = false;
  bool paste_key = false;
};
std::map<HWND, InputState> input_states;

void InputTrace(const char* stage);

void RefreshSystemCaret(HWND hwnd) {
  auto found = input_states.find(hwnd);
  if (found == input_states.end() || !found->second.has_caret || GetFocus() != hwnd) return;
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  if (!GetGUIThreadInfo(GetCurrentThreadId(), &info)) return;
  if (info.hwndCaret != hwnd && !CreateCaret(hwnd, nullptr, 1, 1)) return;
  const POINT point = found->second.caret;
  SetCaretPos(point.x, point.y);
  // Some third-party IMEs show their UI before delivering STARTCOMPOSITION.
  // Flutter only refreshes these IMM forms while its composition is active;
  // keep the forms current even between compositions (client physical pixels).
  HIMC context = ImmGetContext(hwnd);
  if (context) {
    COMPOSITIONFORM composition{};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos = point;
    const BOOL composition_ok = ImmSetCompositionWindow(context, &composition);
    CANDIDATEFORM candidate{};
    candidate.dwIndex = 0;
    candidate.dwStyle = CFS_EXCLUDE;
    candidate.ptCurrentPos = point;
    candidate.rcArea = {point.x, point.y - 1, point.x + 1, point.y};
    const BOOL candidate_ok = ImmSetCandidateWindow(context, &candidate);
    CANDIDATEFORM actual{};
    const BOOL read_ok = ImmGetCandidateWindow(context, 0, &actual);
    ImmReleaseContext(hwnd, context);
    char message[256];
    std::snprintf(message, sizeof(message),
        "IMM position set composition=%d candidate=%d read=%d actual=%ld,%ld style=%lu",
        composition_ok, candidate_ok, read_ok, actual.ptCurrentPos.x,
        actual.ptCurrentPos.y, static_cast<unsigned long>(actual.dwStyle));
    InputTrace(message);
  } else {
    InputTrace("IMM context unavailable");
  }
}

void InputTrace(const char* stage) {
  static const bool enabled = [] {
    wchar_t value[2]{};
    return GetEnvironmentVariableW(L"H2READMD_INPUT_TRACE", value, 2) == 1 && value[0] == L'1';
  }();
  if (!enabled) return;
  wchar_t folder[MAX_PATH]{};
  if (!GetTempPathW(MAX_PATH, folder)) return;
  const auto path = std::wstring(folder) + L"H2Readmd-input-" +
                    std::to_wstring(GetCurrentProcessId()) + L".log";
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"a") != 0 || !file) return;
  GUITHREADINFO info{};
  info.cbSize = sizeof(info);
  GetGUIThreadInfo(GetCurrentThreadId(), &info);
  std::fprintf(file, "%llu %s focus=%p caret=%p rect=%ld,%ld,%ld,%ld ctrl=%d shift=%d win=%d\n",
    static_cast<unsigned long long>(GetTickCount64()), stage,
    static_cast<void*>(info.hwndFocus), static_cast<void*>(info.hwndCaret),
    info.rcCaret.left, info.rcCaret.top, info.rcCaret.right, info.rcCaret.bottom,
    (GetKeyState(VK_CONTROL) & 0x8000) != 0, (GetKeyState(VK_SHIFT) & 0x8000) != 0,
    ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) != 0);
  std::fclose(file);
}
LRESULT CALLBACK InputSubclass(HWND hwnd, UINT message, WPARAM wparam,
                               LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  switch (message) {
    case WM_SETFOCUS: InputTrace("native focus gained"); break;
    case WM_KILLFOCUS: InputTrace("native focus lost"); break;
    case WM_IME_STARTCOMPOSITION: InputTrace("native IME start"); break;
    case WM_IME_COMPOSITION: InputTrace("native IME composition"); break;
    case WM_IME_ENDCOMPOSITION: InputTrace("native IME end"); break;
    case WM_KEYDOWN:
    case WM_KEYUP:
      if (wparam == 'V') InputTrace(message == WM_KEYDOWN ? "native V down" : "native V up");
      break;
  }
  auto& state = input_states[hwnd];
  // Clipboard history sends Ctrl+V, not WM_PASTE. Route physical and
  // synthesized Ctrl+V through one action before Flutter key redispatch.
  if (message == WM_KEYDOWN && wparam == 'V' &&
      (GetKeyState(VK_CONTROL) & 0x8000) && !(GetKeyState(VK_SHIFT) & 0x8000) &&
      !(GetKeyState(VK_MENU) & 0x8000)) {
    if (!state.paste_key) {
      state.paste_key = true;
      InputTrace("native Ctrl+V forwarded");
      auto* channel = reinterpret_cast<flutter::MethodChannel<flutter::EncodableValue>*>(data);
      channel->InvokeMethod("paste", nullptr);
    }
    return 0;
  }
  if (message == WM_KEYUP && wparam == 'V' && state.paste_key) {
    state.paste_key = false;
    return 0;
  }
  if (message == WM_KILLFOCUS) state.paste_key = false;
  if (message == WM_PASTE) {
    InputTrace("native WM_PASTE");
    auto* channel = reinterpret_cast<flutter::MethodChannel<flutter::EncodableValue>*>(data);
    channel->InvokeMethod("paste", nullptr);
    return 0;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, InputSubclass, id);
    input_states.erase(hwnd);
  }
  const auto result = DefSubclassProc(hwnd, message, wparam, lparam);
  // Flutter destroys its temporary caret on composition end. Recreate an
  // invisible accessibility/IME caret at the last editor position afterwards.
  if (message == WM_IME_ENDCOMPOSITION || message == WM_SETFOCUS) {
    RefreshSystemCaret(hwnd);
    InputTrace("native system caret refreshed");
  }
  return result;
}
}  // namespace


#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  input_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "h2readmd/desktop_input",
      &flutter::StandardMethodCodec::GetInstance());
  input_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "caret") {
      const auto* values = call.arguments() ? std::get_if<flutter::EncodableList>(call.arguments()) : nullptr;
      if (!values || values->size() != 2 ||
          !std::holds_alternative<double>((*values)[0]) || !std::holds_alternative<double>((*values)[1])) {
        result->Error("invalid_geometry", "Expected two coordinates");
        return;
      }
      HWND hwnd = flutter_controller_->view()->GetNativeWindow();
      auto& state = input_states[hwnd];
      const double x = std::get<double>((*values)[0]);
      const double y = std::get<double>((*values)[1]);
      if (!std::isfinite(x) || !std::isfinite(y) || std::abs(x) > 10000000 || std::abs(y) > 10000000) {
        result->Error("invalid_geometry", "Coordinates outside supported range");
        return;
      }
      state.caret = {static_cast<LONG>(std::lround(x)), static_cast<LONG>(std::lround(y))};
      state.has_caret = true;
      RefreshSystemCaret(hwnd);
      InputTrace("native caret geometry applied");
      result->Success();
    } else if (call.method_name() == "caretInactive") {
      HWND hwnd = flutter_controller_->view()->GetNativeWindow();
      input_states[hwnd].has_caret = false;
      if (GetFocus() == hwnd) DestroyCaret();
      result->Success();
    } else if (call.method_name() == "trace") {
      const auto* message = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (message) InputTrace(message->c_str());
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
  InputTrace("diagnostic build started");
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(), InputSubclass,
                    1, reinterpret_cast<DWORD_PTR>(input_channel_.get()));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  TraceClose("OnDestroy: engine cleanup begin");
  if (flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(), InputSubclass, 1);
    input_states.erase(flutter_controller_->view()->GetNativeWindow());
    input_channel_.reset();
    flutter_controller_ = nullptr;
  }
  TraceClose("OnDestroy: engine cleanup end");

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_CLOSE) {
    TraceClose("native SC_CLOSE received");
  }
  if (message == WM_CLOSE) TraceClose("native WM_CLOSE received");
  if (message == WM_DESTROY) TraceClose("native WM_DESTROY received");
  if (message == WM_NCDESTROY) TraceClose("native WM_NCDESTROY received");
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const auto result = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (message == WM_DESTROY) TraceClose("native WM_DESTROY completed");
  return result;
}
