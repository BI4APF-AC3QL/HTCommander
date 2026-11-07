cmake_minimum_required(VERSION 3.14)
project(htcommander_native_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
enable_testing()
if(MSVC)
  add_compile_options(/utf-8 /W4 /WX /wd4100 /EHsc)
  add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS _HAS_EXCEPTIONS=0)
endif()
add_executable(bluetooth_receive_queue_test bluetooth_receive_queue_test.cpp)
add_test(NAME bluetooth_receive_queue COMMAND bluetooth_receive_queue_test)

# Optional Windows integration test using the wrapper built by Flutter.
if(WIN32 AND FLUTTER_EPHEMERAL_DIR AND FLUTTER_WRAPPER_LIBRARY)
  add_executable(bluetooth_stream_handler_test bluetooth_stream_handler_test.cpp)
  target_compile_definitions(bluetooth_stream_handler_test PRIVATE NOMINMAX)
  target_include_directories(bluetooth_stream_handler_test PRIVATE
    "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include"
    "${FLUTTER_EPHEMERAL_DIR}")
  target_link_libraries(bluetooth_stream_handler_test PRIVATE
    "${FLUTTER_WRAPPER_LIBRARY}" "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll.lib"
    windowsapp)
  add_custom_command(TARGET bluetooth_stream_handler_test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:bluetooth_stream_handler_test>")
  add_test(NAME bluetooth_stream_handler COMMAND bluetooth_stream_handler_test)
endif()
set_tests_properties(bluetooth_receive_queue PROPERTIES TIMEOUT 30)
if(TARGET bluetooth_stream_handler_test)
  set_tests_properties(bluetooth_stream_handler PROPERTIES TIMEOUT 30)
endif()
