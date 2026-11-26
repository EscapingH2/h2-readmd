#include "../runner/document_store.h"
#include <objbase.h>
#include <fstream>
#include <iostream>
#include <functional>
#include <iterator>

using namespace documents;
namespace fs = std::filesystem;
const Bytes old_text{'o','l','d'}, new_text{'n','e','w'};
void Expect(bool condition, const char* label) {
  if (!condition) throw std::runtime_error(label);
}
void Fails(const std::function<void()>& operation, bool recovery = false) {
  try { operation(); }
  catch (const RecoveryNeeded&) { if (!recovery) throw; return; }
  catch (const StorageError&) { Expect(!recovery, "missing recovery warning"); return; }
  throw std::runtime_error("unexpected success");
}
BOOL WINAPI PartialWrite(HANDLE file, LPCVOID buffer, DWORD, LPDWORD count, LPOVERLAPPED overlapped) {
  if (!WriteFile(file, buffer, 1, count, overlapped)) return FALSE;
  SetLastError(ERROR_DISK_FULL);
  return FALSE;
}
BOOL WINAPI PartialReplace(LPCWSTR target, LPCWSTR, LPCWSTR backup, DWORD, LPVOID, LPVOID) {
  if (!MoveFileExW(target, backup, 0)) return FALSE;
  SetLastError(ERROR_UNABLE_TO_MOVE_REPLACEMENT_2);
  return FALSE;
}
BOOL WINAPI ChangedBackup(LPCWSTR target, LPCWSTR stage, LPCWSTR backup, DWORD flags, LPVOID a, LPVOID b) {
  if (!ReplaceFileW(target, stage, backup, flags, a, b)) return FALSE;
  std::ofstream(Path(backup), std::ios::binary) << "foreign";
  return TRUE;
}
int main() {
  GUID id; CoCreateGuid(&id); wchar_t unique[40]; StringFromGUID2(id, unique, 40);
  auto dir = fs::temp_directory_path() / (std::wstring(L"h2readmd-tests-") + unique);
  if (!fs::create_directory(dir)) return 1;
  try {
    auto path = dir / L"中文 文档.md";
    auto first = Save(path, old_text, std::nullopt);
    Expect(Read(path,true).bytes == old_text, "new");
    Fails([&]{ Save(path,new_text,std::nullopt); });
    auto second = Save(path, new_text, first.version);
    auto third = Save(path, old_text, second.version);
    Expect(Read(path,true).version == third.version && third.version != first.version, "second overwrite");
    { std::ofstream(path) << "change"; }
    Fails([&]{ Save(path,new_text,third.version); });
    Expect(Read(path,true).bytes == Bytes({'c','h','a','n','g','e'}), "external edit preserved");
    auto baseline = Read(path,false).version;
    fs::rename(path, dir / "moved");
    Fails([&]{ Save(path,new_text,baseline); });
    Expect(!fs::exists(path), "rename recreated path");
    fs::copy_file(dir / "moved",path);
    Fails([&]{ Save(path,new_text,baseline); });
    auto copy = Read(path,false).version;
    fs::remove(path);
    Fails([&]{ Save(path,new_text,copy); });
    Expect(!fs::exists(path), "delete recreated path");
    auto restored = Save(path, old_text, std::nullopt);
    Fails([&]{ Save(path,new_text,restored.version,PartialWrite); });
    Expect(Read(path,true).version == restored.version, "partial stage write affected target");
    SetFileAttributesW(path.c_str(),FILE_ATTRIBUTE_READONLY);
    Fails([&]{ Save(path,new_text,restored.version); });
    SetFileAttributesW(path.c_str(),FILE_ATTRIBUTE_NORMAL);
    Expect(Read(path,true).version == restored.version, "failed real replacement affected target");
    Expect(std::distance(fs::directory_iterator(dir), fs::directory_iterator{}) == 2, "temporary files leaked");
    Fails([&]{ Save(path,new_text,restored.version,WriteFile,PartialReplace); },true);
    Expect(!fs::exists(path), "partial state overwritten");
    int verified_backups = 0;
    for (const auto& entry : fs::directory_iterator(dir))
      if (entry.is_directory() && Read(entry.path() / "previous.md",false).version == restored.version)
        ++verified_backups;
    Expect(verified_backups == 1,"old backup lost");
    auto recreated = Save(path,old_text,std::nullopt);
    Fails([&]{ Save(path,new_text,recreated.version,WriteFile,ChangedBackup); },true);
    bool foreign_preserved = false;
    for (const auto& entry : fs::directory_iterator(dir))
      if (entry.is_directory() && Read(entry.path() / "previous.md",true).bytes == Bytes({'f','o','r','e','i','g','n'}))
        foreign_preserved = true;
    Expect(foreign_preserved && Read(path,true).bytes == new_text, "unexpected backup deleted");
    std::wcout << L"PASS real NTFS saves/conflicts and injected failures. Fixtures: " << dir << std::endl;
  } catch (const std::exception& e) {
    std::cerr << e.what() << std::endl;
    return 1;
  }
}
