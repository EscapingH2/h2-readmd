#pragma once
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <thread>

class StorageChannel {
 public:
  static constexpr UINT kCompleted = WM_APP + 0x147;
  StorageChannel(flutter::BinaryMessenger* messenger, HWND owner);
  ~StorageChannel();
  void Complete();
 private:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  HWND owner_;
  flutter::MethodChannel<Value> channel_;
  std::unique_ptr<Result> pending_;
  std::thread writer_;
  Value response_;
  std::string error_code_, error_;
};
