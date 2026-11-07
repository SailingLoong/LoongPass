include(FetchContent)

FetchContent_Declare(nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
  URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
)
FetchContent_MakeAvailable(nlohmann_json)

FetchContent_Declare(webview2
  URL https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4314.35/microsoft.web.webview2.1.0.4314.35.nupkg
  URL_HASH SHA256=90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4
)
FetchContent_MakeAvailable(webview2)
add_library(webview2_loader STATIC IMPORTED)
set_target_properties(webview2_loader PROPERTIES
  IMPORTED_LOCATION "${webview2_SOURCE_DIR}/build/native/x64/WebView2LoaderStatic.lib"
  INTERFACE_INCLUDE_DIRECTORIES "${webview2_SOURCE_DIR}/build/native/include"
)

file(TO_CMAKE_PATH "$ENV{WINSPARKLE_SDK}" WINSPARKLE_ROOT)
if(NOT WINSPARKLE_ROOT)
  message(FATAL_ERROR "Set WINSPARKLE_SDK to the SDK built by tool/build_winsparkle.ps1")
endif()
add_library(winsparkle_library SHARED IMPORTED)
set_target_properties(winsparkle_library PROPERTIES
  IMPORTED_IMPLIB "${WINSPARKLE_ROOT}/x64/Release/WinSparkle.lib"
  IMPORTED_LOCATION "${WINSPARKLE_ROOT}/x64/Release/WinSparkle.dll"
  INTERFACE_INCLUDE_DIRECTORIES "${WINSPARKLE_ROOT}/include"
)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/../tool/windows_build_config.py"
          "${CMAKE_CURRENT_BINARY_DIR}/loongpass_config.h" "${WINSPARKLE_ROOT}"
  COMMAND_ERROR_IS_FATAL ANY
)
