cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)
include(native_dependencies.cmake)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "native_storage.cpp"
  "native_authorization.cpp"
  "trae_authorization.cpp"
  "native_updater.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE nlohmann_json::nlohmann_json
  webview2_loader winsparkle_library bcrypt ncrypt crypt32 advapi32 shell32
  ole32 oleaut32 version userenv shlwapi normaliz comdlg32 uuid urlmon winhttp)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "$<TARGET_FILE:winsparkle_library>" "$<TARGET_FILE_DIR:${BINARY_NAME}>"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${WINSPARKLE_ROOT}/COPYING" "$<TARGET_FILE_DIR:${BINARY_NAME}>/WINSPARKLE-LICENSE.txt"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${webview2_SOURCE_DIR}/LICENSE.txt" "$<TARGET_FILE_DIR:${BINARY_NAME}>/WEBVIEW2-LICENSE.txt"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

add_executable(loongpass_storage_checks EXCLUDE_FROM_ALL
  "${CMAKE_SOURCE_DIR}/../tool/windows_storage_checks.cpp")
apply_standard_settings(loongpass_storage_checks)
target_link_libraries(loongpass_storage_checks PRIVATE flutter flutter_wrapper_app
  nlohmann_json::nlohmann_json bcrypt advapi32 shell32 ole32 uuid)

add_executable(loongpass_authorization_checks EXCLUDE_FROM_ALL "trae_authorization.cpp")
apply_standard_settings(loongpass_authorization_checks)
target_compile_definitions(loongpass_authorization_checks PRIVATE LOONGPASS_AUTHORIZATION_SELF_TEST)
target_link_libraries(loongpass_authorization_checks PRIVATE flutter flutter_wrapper_app
  nlohmann_json::nlohmann_json bcrypt ncrypt crypt32 advapi32 shell32 ole32 uuid)
