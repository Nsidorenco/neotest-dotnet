local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-dotnet.dotnet_utils")

local M = {}

M.sdk_path = nil

local function get_vstest_path()
  if not M.sdk_path then
    local process = nio.process.run({
      cmd = "dotnet",
      args = { "--info" },
    })

    local default_sdk_path
    if vim.fn.has("win32") then
      default_sdk_path = "C:/Program Files/dotnet/sdk/"
    else
      default_sdk_path = "/usr/local/share/dotnet/sdk/"
    end

    if not process then
      M.sdk_path = default_sdk_path
      local log_string =
        string.format("neotest-dotnet: failed to detect sdk path. falling back to %s", M.sdk_path)

      logger.info(log_string)
      nio.scheduler()
      vim.notify_once(log_string)
    else
      local out = process.stdout.read()
      local info = dotnet_utils.parse_dotnet_info(out or "")
      if info.sdk_path then
        M.sdk_path = info.sdk_path
        logger.info(string.format("neotest-dotnet: detected sdk path: %s", M.sdk_path))
      else
        M.sdk_path = default_sdk_path
        local log_string =
          string.format("neotest-dotnet: failed to detect sdk path. falling back to %s", M.sdk_path)
        logger.info(log_string)
        nio.scheduler()
        vim.notify_once(log_string)
      end
      process.close()
    end
  end

  return vim.fs.find("vstest.console.dll", { upward = false, type = "file", path = M.sdk_path })[1]
end

local function get_script(script_name)
  local script_paths = vim.api.nvim_get_runtime_file(vim.fs.joinpath("scripts", script_name), true)
  logger.debug("neotest-dotnet: possible scripts:")
  logger.debug(script_paths)
  for _, path in ipairs(script_paths) do
    if path:match("neotest%-dotnet") ~= nil then
      return path
    end
  end
end

local test_runner
local test_runner_semaphore = nio.control.semaphore(1)

local function invoke_test_runner(command)
  test_runner_semaphore.with(function()
    if test_runner ~= nil then
      return
    end

    local test_discovery_script = get_script("run_tests.fsx")
    local testhost_dll = get_vstest_path()

    logger.debug("neotest-dotnet: found discovery script: " .. test_discovery_script)
    logger.debug("neotest-dotnet: found testhost dll: " .. testhost_dll)

    local vstest_command = { "dotnet", "fsi", test_discovery_script, testhost_dll }

    logger.info("neotest-dotnet: starting vstest console with:")
    logger.info(vstest_command)

    local process = vim.system(vstest_command, {
      stdin = true,
      stdout = function(err, data)
        if data then
          logger.trace("neotest-dotnet: " .. data)
        end
        if err then
          logger.trace("neotest-dotnet " .. err)
        end
      end,
    }, function(obj)
      vim.schedule(function()
        vim.notify_once("neotest-dotnet: vstest process exited unexpectedly.", vim.log.levels.ERROR)
      end)
      logger.warn("neotest-dotnet: vstest process died :(")
      logger.warn(obj.code)
      logger.warn(obj.signal)
      logger.warn(obj.stdout)
      logger.warn(obj.stderr)
    end)

    logger.info(string.format("neotest-dotnet: spawned vstest process with pid: %s", process.pid))

    test_runner = function(content)
      process:write(content .. "\n")
    end
  end)

  return test_runner(command)
end

local spin_lock = nio.control.semaphore(1)

---Repeatly tries to read content. Repeats until the file is non-empty or operation times out.
---@param file_path string
---@param max_wait integer maximal time to wait for the file to populated in milliseconds.
---@return string?
function M.spin_lock_wait_file(file_path, max_wait)
  local content

  local sleep_time = 25 -- scan every 25 ms
  local tries = 1
  local file_exists = false

  while not file_exists and tries * sleep_time < max_wait do
    if lib.files.exists(file_path) then
      spin_lock.with(function()
        file_exists = true
        content = lib.files.read(file_path)
      end)
    else
      tries = tries + 1
      nio.sleep(sleep_time)
    end
  end

  if not content then
    logger.warn(string.format("neotest-dotnet: timed out reading content of file %s", file_path))
  end

  return content
end

local discovery_cache = {}
local last_discovery = {}

---@class TestCase
---@field CodeFilePath string
---@field DisplayName string
---@field FullyQualifiedName string
---@field LineNumber integer

local project_semaphore = nio.control.semaphore(1)
local project_semaphores = {}

---@param project DotnetProjectInfo
---@param path string
---@return integer?
local function get_project_last_modified(project, path)
  local path_open_err, path_stats = nio.uv.fs_stat(path)

  if
    not (
      not path_open_err
      and path_stats
      and path_stats.mtime
      and last_discovery[project.proj_file]
      and path_stats.mtime.sec <= last_discovery[project.proj_file]
    )
  then
    logger.debug("neotest-dotnet: building project " .. project.proj_file)
    local exitCode, out = lib.process.run(
      { "dotnet", "build", project.proj_file },
      { stdout = true, stderr = true }
    )
    if exitCode ~= 0 then
      nio.scheduler()
      vim.notify_once(
        "neotest-dotnet: failed to build project " .. project.proj_file .. "\n" .. out.stdout,
        vim.log.levels.ERROR
      )
    end
  end

  local dll_open_err, dll_stats = nio.uv.fs_stat(project.dll_file)
  if dll_open_err then
    logger.warn(
      "neotest-dotnet: failed to read dll file for "
        .. project.dll_file
        .. " reason: "
        .. (dll_open_err or "")
    )
    return nil
  end

  return dll_stats and dll_stats.mtime and dll_stats.mtime.sec
end

---@param projects DotnetProjectInfo[]
---@param json any
local function populate_discovery_cache(projects, json)
  for file_path, test_map in pairs(json) do
    if vim.endswith(file_path, ".dll") then
      for _, project in ipairs(projects) do
        if project.dll_file == file_path then
          discovery_cache[project.proj_file] = test_map
        end
      end
    else
      discovery_cache[dotnet_utils.abspath(file_path)] = test_map
    end
  end
end

---@param projects DotnetProjectInfo[]
---@return table?
local function discover_tests_in_projects(projects)
  local json

  local wait_file = nio.fn.tempname()
  local output_file = nio.fn.tempname()

  local dlls = {}

  for _, project in ipairs(projects) do
    dlls[#dlls + 1] = project.dll_file
  end

  local command = vim
    .iter({
      "discover",
      output_file,
      wait_file,
      dlls,
    })
    :flatten()
    :join(" ")

  logger.debug("neotest-dotnet: Discovering tests using:")
  logger.debug(command)

  invoke_test_runner(command)

  logger.debug("neotest-dotnet: Waiting for result file to populated...")

  local max_wait = 60 * 1000 -- 60 sec

  if M.spin_lock_wait_file(wait_file, max_wait) then
    local content = M.spin_lock_wait_file(output_file, max_wait)

    logger.debug("neotest-dotnet: file has been populated. Extracting test cases...")

    json = (content and vim.json.decode(content, { luanil = { object = true } })) or {}

    logger.debug("neotest-dotnet: done decoding test cases.")
  end

  return json
end

---@param path string
---@return table<string, TestCase> | nil test_cases map from id -> test case
function M.discover_tests(path)
  path = dotnet_utils.abspath(path)
  local project = dotnet_utils.get_proj_info(path)

  if not project then
    logger.warn(string.format("neotest-dotnet: failed to find project info for %s", path))
    return
  end

  if not project.is_test_project then
    logger.info(string.format("neotest-dotnet: %s is not a test project. Skipping.", path))
    return
  end

  if project.proj_file == "" then
    logger.warn(string.format("neotest-dotnet: failed to find project file for %s", path))
    return
  end

  if project.dll_file == "" then
    logger.warn(string.format("neotest-dotnet: failed to find dll file for %s", path))
    return
  end

  local semaphore

  project_semaphore.with(function()
    if project_semaphores[project.proj_file] then
      semaphore = project_semaphores[project.proj_file]
    else
      project_semaphores[project.proj_file] = nio.control.semaphore(1)
      semaphore = project_semaphores[project.proj_file]
    end
  end)

  semaphore.acquire()
  logger.debug("acquired semaphore for " .. project.proj_file .. " on path: " .. path)

  local project_last_modified = get_project_last_modified(project, path)

  if
    last_discovery[project.proj_file]
    and project_last_modified
    and project_last_modified <= last_discovery[project.proj_file]
  then
    semaphore.release()
    logger.debug(
      string.format(
        "released semaphore for %s on path: %s due to cache hit. last modified: %s last discovery: %s",
        project.proj_file,
        path,
        project_last_modified,
        last_discovery[project.proj_file]
      )
    )
    return discovery_cache[path]
  end

  local json = discover_tests_in_projects({ project })

  if json then
    last_discovery[project.proj_file] = project_last_modified
    populate_discovery_cache({ project }, json)
  end

  semaphore.release()
  logger.debug("released semaphore for " .. project.proj_file .. " on path: " .. path)

  return discovery_cache[path] or {}
end

---runs tests identified by ids.
---@param stream_path string
---@param output_path string
---@param process_output_path string
---@param ids string|string[]
---@return string wait_file
function M.run_tests(stream_path, output_path, process_output_path, ids)
  local command = vim
    .iter({
      "run-tests",
      stream_path,
      output_path,
      process_output_path,
      ids,
    })
    :flatten()
    :join(" ")
  invoke_test_runner(command)

  return output_path
end

--- Uses the vstest console to spawn a test process for the debugger to attach to.
---@param attached_path string
---@param stream_path string
---@param output_path string
---@param ids string|string[]
---@return string? pid
function M.debug_tests(attached_path, stream_path, output_path, ids)
  local process_output = nio.fn.tempname()

  local pid_path = nio.fn.tempname()

  local command = vim
    .iter({
      "debug-tests",
      pid_path,
      attached_path,
      stream_path,
      output_path,
      process_output,
      ids,
    })
    :flatten()
    :join(" ")
  logger.debug("neotest-dotnet: starting test in debug mode using:")
  logger.debug(command)

  invoke_test_runner(command)

  logger.debug("neotest-dotnet: Waiting for pid file to populate...")

  local max_wait = 30 * 1000 -- 30 sec

  return M.spin_lock_wait_file(pid_path, max_wait)
end

local solution_cache
local solution_semaphore = nio.control.semaphore(1)

function M.discover_solution_tests(root)
  if solution_cache then
    return solution_cache
  end

  solution_semaphore.acquire()

  local res = dotnet_utils.get_solution_projects(root)
  if res.solution then
    logger.debug("neotest-dotnet: building solution")

    local build_exit_code, build_res = lib.process.run({
      "dotnet",
      "build",
      res.solution,
    }, {
      stderr = true,
      stdout = true,
    })

    if build_exit_code ~= 0 then
      nio.scheduler()
      vim.notify_once(
        "Failed to build solution " .. res.solution .. " with error: " .. build_res.stdout,
        vim.log.levels.ERROR
      )
    end

    for _, project in ipairs(res.projects) do
      if project.proj_file then
        local dll_open_err, dll_stats = nio.uv.fs_stat(project.dll_file)
        last_discovery[project.proj_file] = (
          not dll_open_err
          and dll_stats
          and dll_stats.mtime
          and dll_stats.mtime.sec
        ) or os.time()
      end
    end
  end

  local project_paths = {}

  for _, project in ipairs(res.projects) do
    project_paths[#project_paths + 1] = project.proj_file
  end

  solution_cache = project_paths

  local json = discover_tests_in_projects(res.projects)

  if json then
    populate_discovery_cache(res.projects, json)
  end

  solution_semaphore.release()

  return solution_cache
end

return M
