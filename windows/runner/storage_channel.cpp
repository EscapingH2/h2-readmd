#include "storage_channel.h"
#include "document_store.h"
#include <shobjidl.h>
#include <wrl/client.h>

namespace {
using Microsoft::WRL::ComPtr;
using namespace documents;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
void ComCheck(HRESULT hr) {
  if (FAILED(hr)) throw StorageError("无法取得保存对话框的选择，请重新选择文件。HRESULT " +
                                     std::to_string(static_cast<unsigned long>(hr)));
}
Path ItemPath(IShellItem* item) {
  PWSTR raw = nullptr;
  ComCheck(item->GetDisplayName(SIGDN_FILESYSPATH, &raw));
  std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned(raw, CoTaskMemFree);
  return Path(raw);
}
bool SamePath(const Path& a, const Path& b) {
  return CompareStringOrdinal(a.lexically_normal().c_str(), -1,
                              b.lexically_normal().c_str(), -1, TRUE) == CSTR_EQUAL;
}
struct Choice {
  Path path;
  std::optional<std::string> version;
};
class OverwriteEvents final : public IFileDialogEvents {
 public:
  Choice approved;
  HWND owner;
  explicit OverwriteEvents(HWND window) : owner(window) {}
  IFACEMETHODIMP QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_IFileDialogEvents) return E_NOINTERFACE;
    *out = static_cast<IFileDialogEvents*>(this);
    AddRef(); return S_OK;
  }
  // Stack lifetime encloses Advise, Show and destruction of the dialog.
  IFACEMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  IFACEMETHODIMP_(ULONG) Release() override { return --refs_; }
  IFACEMETHODIMP OnOverwrite(IFileDialog*, IShellItem* item, FDE_OVERWRITE_RESPONSE* response) override {
    *response = FDEOR_REFUSE;
    approved = {};
    try {
      auto path = ItemPath(item);
      approved = {path, Read(path, false).version};
      *response = FDEOR_DEFAULT;
    } catch (const std::exception& e) {
      MessageBoxW(owner, std::filesystem::u8path(e.what()).c_str(), L"无法核验覆盖目标", MB_OK | MB_ICONWARNING);
    }
    return S_OK;
  }
  IFACEMETHODIMP OnFileOk(IFileDialog*) override { return S_OK; }
  IFACEMETHODIMP OnFolderChanging(IFileDialog*, IShellItem*) override { return S_OK; }
  IFACEMETHODIMP OnFolderChange(IFileDialog*) override { return S_OK; }
  IFACEMETHODIMP OnSelectionChange(IFileDialog*) override { return S_OK; }
  IFACEMETHODIMP OnShareViolation(IFileDialog*, IShellItem*, FDE_SHAREVIOLATION_RESPONSE* r) override {
    *r = FDESVR_DEFAULT; return S_OK;
  }
  IFACEMETHODIMP OnTypeChange(IFileDialog*) override { return S_OK; }
 private:
  ULONG refs_ = 1;
};
std::optional<Choice> Pick(HWND owner, const std::string& name) {
  OverwriteEvents events(owner);
  ComPtr<IFileSaveDialog> dialog;
  ComCheck(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)));
  DWORD options;
  ComCheck(dialog->GetOptions(&options));
  ComCheck(dialog->SetOptions(options | FOS_OVERWRITEPROMPT | FOS_FORCEFILESYSTEM |
                              FOS_NOCHANGEDIR | FOS_NOTESTFILECREATE));
  const COMDLG_FILTERSPEC filters[] = {{L"Markdown", L"*.md;*.markdown"}, {L"所有文件", L"*.*"}};
  ComCheck(dialog->SetFileTypes(2, filters));
  ComCheck(dialog->SetDefaultExtension(L"md"));
  ComCheck(dialog->SetFileName(std::filesystem::u8path(name).c_str()));
  DWORD cookie;
  ComCheck(dialog->Advise(&events, &cookie));
  HRESULT hr = dialog->Show(owner);
  ComCheck(dialog->Unadvise(cookie));
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return std::nullopt;
  ComCheck(hr);
  ComPtr<IShellItem> item;
  ComCheck(dialog->GetResult(&item));
  auto path = ItemPath(item.Get());
  if (events.approved.version && SamePath(path, events.approved.path))
    return Choice{path, events.approved.version};
  return Choice{path, std::nullopt};  // Move without overwrite, even if a file appeared.
}
const std::string& StringArg(const Map& args, const char* key) {
  auto it = args.find(Value(key));
  if (it == args.end() || !std::holds_alternative<std::string>(it->second))
    throw StorageError("缺少保存参数");
  return std::get<std::string>(it->second);
}
}  // namespace

StorageChannel::StorageChannel(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner), channel_(messenger, "h2readmd/storage", &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!args) throw StorageError("无效的文件参数");
      auto path = std::filesystem::u8path(StringArg(*args, "path"));
      if (call.method_name() == "read") {
        auto data = Read(path, true);
        result->Success(Value(Map{{Value("version"), Value(data.version)}, {Value("bytes"), Value(std::move(data.bytes))}}));
        return;
      }
      if (call.method_name() != "save" && call.method_name() != "saveAs") {
        result->NotImplemented(); return;
      }
      if (pending_) throw StorageError("已有保存操作正在进行");
      auto version = StringArg(*args, "version");
      Choice choice{path, version};
      bool current_document = true;
      if (call.method_name() == "saveAs") {
        auto selected = Pick(owner_, StringArg(*args, "name"));
        if (!selected) { result->Success(); return; }
        choice = *selected;
        std::error_code ec;
        current_document = !path.empty() && (SamePath(path, choice.path) ||
            std::filesystem::equivalent(path, choice.path, ec));
        if (current_document && (!choice.version || *choice.version != version)) {
          result->Error("document_conflict", "当前文档的磁盘版本已变化或已移走。请另选文件名。");
          return;
        }
      }
      auto it = args->find(Value("bytes"));
      if (it == args->end() || !std::holds_alternative<Bytes>(it->second)) throw StorageError("缺少待保存内容");
      // Reply on the platform thread. The filesystem work leaves the editor responsive.
      writer_ = std::thread([this, choice, current_document, bytes = std::get<Bytes>(it->second)] {
        try {
          auto saved = Save(choice.path, bytes, choice.version);
          response_ = Value(Map{{Value("path"), Value(choice.path.u8string())},
                                {Value("version"), Value(saved.version)}, {Value("warning"), Value(saved.warning)}});
        } catch (const RecoveryNeeded& e) { error_code_ = "recovery"; error_ = e.what(); }
          catch (const VersionConflict& e) {
            error_code_ = current_document ? "document_conflict" : "save_failed";
            error_ = e.what();
          } catch (const std::exception& e) { error_code_ = "save_failed"; error_ = e.what(); }
        PostMessageW(owner_, kCompleted, 0, 0);
      });
      pending_ = std::move(result);
    } catch (const std::exception& e) { result->Error("storage", e.what()); }
  });
}
void StorageChannel::Complete() {
  if (!pending_) return;
  writer_.join();
  auto result = std::move(pending_);
  if (error_code_.empty()) result->Success(response_);
  else result->Error(error_code_, error_);
  response_ = Value();
  error_code_.clear();
  error_.clear();
}
StorageChannel::~StorageChannel() {
  channel_.SetMethodCallHandler(nullptr);
  if (writer_.joinable()) writer_.join();
}
