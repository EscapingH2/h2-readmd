#pragma once
#include <windows.h>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace documents {
using Path = std::filesystem::path;
using Bytes = std::vector<uint8_t>;
// Opaque to Dart: volume and file ID followed by the raw byte SHA-256.
struct Snapshot {
  std::string version;
  Bytes bytes;
};
struct StorageError : std::exception {
  // Flutter's MSVC runner uses _HAS_EXCEPTIONS=0. Own the UTF-8 message
  // explicitly so it survives destruction of temporary path strings.
  explicit StorageError(std::string message) : message_(std::move(message)) {}
  const char* what() const noexcept override { return message_.c_str(); }
 private:
  std::string message_;
};
struct VersionConflict : StorageError {
  using StorageError::StorageError;
};
struct RecoveryNeeded : StorageError {
  using StorageError::StorageError;
};
struct Saved {
  std::string version;
  std::string warning;
};
Snapshot Read(const Path& path, bool include_bytes);
Saved Save(const Path& path, const Bytes& bytes,
           const std::optional<std::string>& expected,
           decltype(&WriteFile) write = WriteFile,
           decltype(&ReplaceFileW) replace = ReplaceFileW);
}  // namespace documents
