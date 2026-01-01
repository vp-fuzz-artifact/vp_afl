cmake_minimum_required(VERSION 3.20)

project(harness)

set(SRC "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(INC "${CMAKE_CURRENT_SOURCE_DIR}/include")

include_directories(${INC})

find_package(vp-testing-interface  REQUIRED CONFIG)

add_executable(harness
    ${SRC}/main.cpp

    ${SRC}/harness.cpp

    ${SRC}/vp_manager.cpp
    ${SRC}/afl_interface.cpp

    ${SRC}/afl_config.cpp
    ${SRC}/vp_config.cpp

    ${SRC}/logger.cpp
    ${SRC}/utils.cpp
)
set_target_properties(harness PROPERTIES CXX_STANDARD 17)

# Link test_client with required libraries
target_link_libraries(harness
  PRIVATE
    vp-testing-interface::vp-testing-interface
    rt
)

# for compatibility with the old name.
add_custom_command(TARGET harness POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:harness> ./test_client
)
