#include "document_store.h"
#include <bcrypt.h>
#include <objbase.h>
#include <array>
#include <algorithm>
#include <system_error>
#include <memory>

namespace documents {
namespace {
struct Close {
  void operator()(HANDLE h) const { CloseHandle(h); }
};
using Handle = std::unique_ptr<void, Close>;
std::string Reason(DWORD code) {
  wchar_t message[512]{};
  FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, code, 0, message, 512, nullptr);
  std::wstring text(message);
  text.erase(text.find_last_not_of(L"\r\n ") + 1);
  return Path(text).u8string() + " (Windows " + std::to_string(code) + ")";
}
void Check(BOOL ok, const char* operation, const Path& path) {
  if (!ok) {
    DWORD code = GetLastError();
    throw StorageError(std::string(operation) + "\n" + path.u8string() + "\n" + Reason(code));
  }
}
Handle Open(const Path& path, DWORD access, DWORD sharing, DWORD creation, DWORD flags) {
  HANDLE h = CreateFileW(path.c_str(), access, sharing, nullptr, creation, flags, nullptr);
  Check(h != INVALID_HANDLE_VALUE, creation == CREATE_NEW ? "无法创建临时文件" : "无法打开文件", path);
  return Handle(h);
}
std::string Hex(const unsigned char* data, size_t size) {
  constexpr char digits[] = "0123456789abcdef";
  std::string hex;
  for (size_t i = 0; i < size; ++i) {
    hex += digits[data[i] >> 4];
    hex += digits[data[i] & 15];
  }
  return hex;
}
std::string Identity(HANDLE h, const Path& path) {
  FILE_ID_INFO id{};
  Check(GetFileInformationByHandleEx(h, FileIdInfo, &id, sizeof(id)), "无法核验文件身份", path);
  return std::to_string(id.VolumeSerialNumber) + "/" + Hex(id.FileId.Identifier, 16) + "/";
}
class Sha256 {
 public:
  Sha256() {
    if (BCryptCreateHash(BCRYPT_SHA256_ALG_HANDLE, &hash_, nullptr, 0, nullptr, 0, 0) < 0)
      throw StorageError("无法初始化 SHA-256 校验");
  }
  ~Sha256() { BCryptDestroyHash(hash_); }
  void Add(const uint8_t* bytes, DWORD n) {
    if (BCryptHashData(hash_, const_cast<PUCHAR>(bytes), n, 0) < 0)
      throw StorageError("无法计算文件摘要");
  }
  std::string Finish() {
    unsigned char digest[32];
    if (BCryptFinishHash(hash_, digest, sizeof(digest), 0) < 0)
      throw StorageError("无法完成文件摘要校验");
    return Hex(digest, sizeof(digest));
  }
 private:
  BCRYPT_HASH_HANDLE hash_ = nullptr;
};
Snapshot Inspect(HANDLE h, const Path& path, bool include_bytes) {
  Snapshot result{Identity(h, path), {}};
  Sha256 hash;
  std::array<uint8_t, 64 * 1024> block;
  DWORD n;
  for (;;) {
    Check(ReadFile(h, block.data(), static_cast<DWORD>(block.size()), &n, nullptr), "读取文件失败", path);
    if (!n) break;
    hash.Add(block.data(), n);
    if (include_bytes) result.bytes.insert(result.bytes.end(), block.begin(), block.begin() + n);
  }
  result.version += hash.Finish();
  return result;
}
void RemoveOpened(HANDLE h, const Path& path) {
  FILE_DISPOSITION_INFO disposition{TRUE};
  Check(SetFileInformationByHandle(h, FileDispositionInfo, &disposition, sizeof(disposition)),
        "未能清理，请核对后手动移除", path);
}
void RemoveVerified(const Path& path, const std::string& version) {
  auto handle = Open(path, GENERIC_READ | DELETE, FILE_SHARE_READ, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL);
  if (Inspect(handle.get(), path, false).version != version)
    throw StorageError("文件身份或内容已变化，已保留：" + path.u8string());
  RemoveOpened(handle.get(), path);
}
void RemoveDirectoryHandle(HANDLE original, const Path& path) {
  auto writable = Open(path, FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
  if (Identity(original, path) != Identity(writable.get(), path))
    throw StorageError("备份目录已变化，请检查：" + path.u8string());
  RemoveOpened(writable.get(), path);
}
std::wstring UniqueName() {
  GUID guid;
  if (FAILED(CoCreateGuid(&guid))) throw StorageError("无法生成临时文件名");
  wchar_t name[40];
  StringFromGUID2(guid, name, 40);
  return std::wstring(L".h2readmd-") + name;
}
std::string Stage(const Path& stage, const Bytes& bytes, decltype(&WriteFile) write) {
  auto h = Open(stage, GENERIC_WRITE | DELETE, 0, CREATE_NEW, FILE_ATTRIBUTE_NORMAL);
  std::string version;
  try {
    version = Identity(h.get(), stage);
    Sha256 hash;
    size_t offset = 0;
    while (offset < bytes.size()) {
      const auto count = static_cast<DWORD>(std::min<size_t>(bytes.size() - offset, 65536));
      DWORD written = 0;
      Check(write(h.get(), bytes.data() + offset, count, &written, nullptr), "写入临时文件失败", stage);
      if (!written || written > count) throw StorageError("临时文件写入不完整");
      hash.Add(bytes.data() + offset, written);
      offset += written;
    }
    Check(FlushFileBuffers(h.get()), "刷新临时文件失败", stage);
    version += hash.Finish();
  } catch (const std::exception& original) {
    try { RemoveOpened(h.get(), stage); }
    catch (const std::exception& cleanup) {
      throw RecoveryNeeded(std::string(original.what()) + "\n原文件尚未提交。\n" + cleanup.what());
    }
    throw;
  }
  Check(CloseHandle(h.release()), "关闭临时文件失败，原文件尚未提交。请检查临时文件", stage);
  return version;
}
}  // namespace

Snapshot Read(const Path& path, bool include_bytes) {
  auto h = Open(path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL);
  return Inspect(h.get(), path, include_bytes);
}
Saved Save(const Path& path, const Bytes& bytes, const std::optional<std::string>& expected,
           decltype(&WriteFile) write, decltype(&ReplaceFileW) replace) {
  if (!path.is_absolute()) throw StorageError("保存目标必须是完整路径");
  auto stem = path.parent_path() / UniqueName();
  Path stage = stem.wstring() + L".tmp";
  Path backup = stem / L"previous.md";
  const auto staged = Stage(stage, bytes, write);
  Handle directory;
  bool directory_created = false;
  try {
    if (expected) {
      Check(CreateDirectoryW(stem.c_str(), nullptr), "无法创建专用备份目录", stem);
      directory_created = true;
      // Hold the actual directory through cleanup; never recursively remove it.
      directory = Open(stem, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
      std::string current;
      try { current = Read(path, false).version; }
      catch (const StorageError& e) { throw VersionConflict(e.what()); }
      if (current != *expected)
        throw VersionConflict("磁盘文件已被修改或替换。请另存为新文件，或重新打开磁盘版本。");
      if (!replace(path.c_str(), stage.c_str(), backup.c_str(), 0, nullptr, nullptr)) {
        DWORD e = GetLastError();
        // A failed ReplaceFile can have moved the old file. Only clean up a
        // demonstrably untouched layout. Preserve everything else for inspection.
        bool untouched = false;
        try {
          if (Read(path, false).version == *expected &&
              GetFileAttributesW(backup.c_str()) == INVALID_FILE_ATTRIBUTES)
            untouched = GetLastError() == ERROR_FILE_NOT_FOUND;
        } catch (const StorageError&) {}
        if (untouched) throw StorageError("替换失败，旧文件仍在原路径。\n" + Reason(e));
        throw RecoveryNeeded("替换失败，目标或备份可能已经移动。\n" + Reason(e));
      }
    } else {
      Check(MoveFileExW(stage.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH),
            "新建保存失败。若目标已存在，请另选文件名", path);
    }
  } catch (const RecoveryNeeded& e) {
    throw RecoveryNeeded(std::string(e.what()) + "\n目标：" + path.u8string() +
        "\n旧版本可能在：" + backup.u8string() + "\n临时文件：" + stage.u8string() +
        "\n请先将现存文件复制到其他位置并核对内容，再决定保留哪个版本。");
  } catch (const std::exception& e) {
    try {
      RemoveVerified(stage, staged);
      if (directory) RemoveDirectoryHandle(directory.get(), stem);
      else if (directory_created) throw StorageError("无法核验临时目录，已保留：" + stem.u8string());
    } catch (const std::exception& cleanup) {
      throw RecoveryNeeded(std::string(e.what()) + "\n" + cleanup.what() +
          "\n目标：" + path.u8string() + "\n临时文件：" + stage.u8string() +
          "\n请核对原文件及临时目录后再清理。");
    }
    throw;
  }

  try {
    if (Read(path, false).version != staged)
      throw StorageError("目标文件与本次保存的内容或身份不符");
    if (expected) RemoveVerified(backup, *expected);
  } catch (const std::exception& e) {
    throw RecoveryNeeded("提交已执行，但未能核实或清理保存结果。\n目标：" + path.u8string() +
        (expected ? "\n旧版本可能在：" + backup.u8string() : "\n本次为新建保存，没有旧版备份。") +
        "\n" + e.what() + "\n请将现存版本复制到其他位置，比较内容后再继续保存。");
  }
  if (directory) {
    try { RemoveDirectoryHandle(directory.get(), stem); }
    catch (const StorageError& e) {
      return {staged, std::string("保存结果已核实，旧版备份已清理。备份目录仍在：\n") + e.what()};
    }
  }
  return {staged, {}};
}
}  // namespace documents
