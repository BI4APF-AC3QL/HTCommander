#pragma once

#include <flutter/flutter_engine.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>

// PluginRegistrarWindows destroys its plugins before its messenger and view.
// Use the same ownership for app-specific native plugins in every engine,
// including detached windows; never keep them in a process-static vector.
template <typename NativePlugin>
class EngineOwnedNativePlugin final : public flutter::Plugin {
 public:
  explicit EngineOwnedNativePlugin(flutter::BinaryMessenger* messenger)
      : plugin_(std::make_unique<NativePlugin>(messenger)) {}

 private:
  std::unique_ptr<NativePlugin> plugin_;
};

template <typename NativePlugin>
void RegisterEngineOwnedNativePlugin(flutter::FlutterEngine* engine,
                                     const char* name) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            engine->GetRegistrarForPlugin(name));
  registrar->AddPlugin(
      std::make_unique<EngineOwnedNativePlugin<NativePlugin>>(registrar->messenger()));
}
