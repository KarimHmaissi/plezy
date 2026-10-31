#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "mpv/display_mode_manager.h"
#include "utils.h"

#include <string>

namespace {

// The NVIDIA SHIELD Remote (VID 0955 / PID 7217) pairs over Bluetooth as a bare
// 16-button HID gamepad. SDL ships no mapping for it, so universal_gamepad never
// reports it and the remote does nothing. SDL numbers its buttons in reverse
// bit order; indices below were captured from SDL itself. Volume (b7/b6) stays
// unmapped. On Android TV the remote sends native D-pad keys, so this is
// Windows-only. Prepended: SDL lets later lines replace earlier ones for the
// same GUID, so a user-supplied SDL_GAMECONTROLLERCONFIG still wins.
void RegisterShieldRemoteGamepadMapping() {
  constexpr wchar_t kVar[] = L"SDL_GAMECONTROLLERCONFIG";
  std::wstring config =
      L"03000000550900001772000000000000,NVIDIA SHIELD Remote,"
      L"a:b8,b:b15,guide:b14,start:b5,dpup:b12,dpdown:b11,dpleft:b10,dpright:b9,"
      L"platform:Windows,";
  const DWORD len = ::GetEnvironmentVariableW(kVar, nullptr, 0);
  if (len > 0) {
    std::wstring existing(len - 1, L'\0');
    ::GetEnvironmentVariableW(kVar, existing.data(), len);
    config += L"\n" + existing;
  }
  ::SetEnvironmentVariableW(kVar, config.c_str());
}

}  // namespace

int APIENTRY
wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev, _In_ wchar_t* command_line, _In_ int show_command) {
  // Plezy requires the bundled flutter-plezy engine, which presents the Flutter
  // UI on a topmost DirectComposition visual when FLUTTER_WINDOWS_DCOMP is set.
  // The mpv video window is then a plain child composed beneath the UI in the
  // same HWND: window capture (Discord/OBS) works, there is no transparency
  // hack, and min/max animations are native. Must be set before the engine is
  // created. (On a stock engine the flag is a no-op and compositing breaks.)
  ::SetEnvironmentVariableW(L"FLUTTER_WINDOWS_DCOMP", L"1");
  RegisterShieldRemoteGamepadMapping();

  HANDLE mutex = CreateMutex(nullptr, TRUE, L"com.edde746.Plezy.SingleInstance");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Plezy");
    if (existing && IsWindowVisible(existing)) {
      ShowWindow(existing, SW_RESTORE);
      SetForegroundWindow(existing);
      CloseHandle(mutex);
      return EXIT_SUCCESS;
    }
    // A hidden (or already destroyed) window is either still starting - it
    // shows itself on its first frame - or exiting: the exit path hides the
    // window before a teardown of up to 15 s. Restoring it would bring back a
    // window that is about to vanish. Wait for the other instance instead:
    // if it is exiting, it releases the mutex and this launch takes over.
    constexpr DWORD kExitingInstanceWaitMs = 20000;
    const DWORD wait = WaitForSingleObject(mutex, kExitingInstanceWaitMs);
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      CloseHandle(mutex);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM for Win32 libraries and plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  // Keep rendering with Skia. Flutter 3.47 made Impeller the default Windows
  // renderer, but the DirectComposition presentation above is only correct
  // when the frame's per-pixel alpha is exact: DWM blends the UI visual over
  // the mpv video child, so a frame that presents opaque where it should be
  // translucent hides the video outright. Impeller's GLES backend gets that
  // alpha wrong on some drivers - the video area went black for as long as
  // the player OSD was on screen (#2127). Every release up to 2.17.0 rendered
  // with Skia; keep it until Impeller composites the alpha correctly.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Plezy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Recover display mode if a prior crash left it changed.
  mpv::DisplayModeManager::RecoverIfNeeded();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  // Required app exit posts WM_QUIT without destroying the window. Tear down
  // the controller and plugins while COM is still initialized.
  window.Destroy();

  ::CoUninitialize();
  CloseHandle(mutex);
  return EXIT_SUCCESS;
}
