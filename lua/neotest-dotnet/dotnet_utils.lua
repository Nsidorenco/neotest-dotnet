local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")

local M = {}

---parses output of running `dotnet --info`
---@param input string?
---@return { sdk_path: string? }
function M.parse_dotnet_info(input)
  if input == nil then
    return { sdk_path = nil }
  end

  local match = input:match("Base Path:%s*(%S+[^\n]*)")
  return { sdk_path = vim.trim(match) }
end

---@class DotnetProjectInfo
---@field proj_file string
---@field dll_file string
---@field proj_dir string
---@field is_test_project boolean

---@type table<string, DotnetProjectInfo>
local proj_info_cache = {}

local discovery_semaphore = nio.control.semaphore(1)

---collects project information based on file
---@async
---@param path string
---@return DotnetProjectInfo
function M.get_proj_info(path)
  local proj_file = vim.fs.find(function(name, _)
    return name:match("%.[cf]sproj$")
  end, { upward = true, type = "file", path = vim.fs.dirname(path) })[1]

  proj_file = vim.fn.fnamemodify(proj_file, ":p")

  discovery_semaphore.acquire()

  if proj_info_cache[proj_file] then
    discovery_semaphore.release()
    return proj_info_cache[proj_file]
  end

  local code, res = lib.process.run({
    "dotnet",
    "msbuild",
    proj_file,
    "-getProperty:TargetFramework",
    "-getProperty:TargetFrameworks",
  }, {
    stderr = true,
    stdout = true,
  })

  logger.debug("neotest-dotnet: msbuild target frameworks for " .. proj_file .. ":")
  logger.debug(res.stdout)

  if code ~= 0 then
    logger.error("neotest-dotnet: failed to get msbuild target framework for " .. proj_file)
    logger.error(res.stderr)

    nio.scheduler()
    vim.notify(
      "Failed to get msbuild target framework for " .. proj_file .. " with error: " .. res.stderr,
      vim.log.levels.ERROR
    )
  end

  local ok, parsed = pcall(nio.fn.json_decode, res.stdout)

  if not ok then
    logger.error("neotest-dotnet: failed to parse msbuild target framework for " .. proj_file)
    logger.error(parsed)

    nio.scheduler()
    vim.notify(
      "Failed to parse msbuild target framework for " .. proj_file .. " with error: " .. parsed,
      vim.log.levels.ERROR
    )
  end

  local framework_info = parsed.Properties
  local target_framework

  if framework_info.TargetFramework == "" then
    local frameworks =
      vim.split(vim.trim(framework_info.TargetFrameworks), ";", { trimempty = true })
    table.sort(frameworks, function(a, b)
      return a > b
    end)
    target_framework = frameworks[1]
  else
    target_framework = vim.trim(framework_info.TargetFramework)
  end

  local command = {
    "dotnet",
    "msbuild",
    proj_file,
    "-getProperty:TargetPath",
    "-getProperty:MSBuildProjectDirectory",
    "-getProperty:IsTestProject",
    "-property:TargetFramework=" .. target_framework,
  }

  local _, res = lib.process.run(command, {
    stderr = false,
    stdout = true,
  })

  local info = nio.fn.json_decode(res.stdout).Properties

  logger.debug("neotest-dotnet: msbuild properties for " .. proj_file .. ":")
  logger.debug(info)

  local proj_data = {
    proj_file = proj_file,
    dll_file = info.TargetPath,
    proj_dir = info.MSBuildProjectDirectory,
    is_test_project = info.IsTestProject == "true",
  }

  if proj_data.dll_file == "" then
    logger.debug("neotest-dotnet: failed to find dll file for " .. proj_file)
    logger.debug(path)
    logger.debug(res.stdout)
  end

  proj_info_cache[proj_file] = proj_data

  discovery_semaphore.release()
  return proj_data
end

---@type table<string, string[]>
local project_cache = {}

---lists all projects in solution.
---Falls back to listing all project in directory.
---@async
---@param root string
---@return string[]
function M.get_solution_projects(root)
  if project_cache[root] then
    return project_cache[root]
  end

  local solution = vim.fs.find(function(name)
    return name:match("%.slnx?$")
  end, { upward = false, type = "file", path = root, limit = 1 })[1]

  local projects

  if solution then
    local _, res = lib.process.run({
      "dotnet",
      "sln",
      solution,
      "list",
    }, {
      stderr = false,
      stdout = true,
    })

    logger.debug("neotest-dotnet: dotnet sln " .. solution .. " list output:")
    logger.debug(res.stdout)

    projects = vim.list_slice(nio.fn.split(res.stdout, "\n"), 3)
  else
    logger.info("found no solution file in " .. root)
    projects = vim.fs.find(function(name, _)
      return name:match("%.[cf]sproj$")
    end, { upward = false, type = "file", path = root })
  end

  local test_projects = {}

  for _, project in ipairs(projects) do
    local project_info = M.get_proj_info(project)
    if project_info.is_test_project then
      table.insert(test_projects, project)
    end
  end

  logger.info("found test projects: " .. root)
  logger.info(test_projects)

  project_cache[root] = test_projects

  return test_projects
end

return M
