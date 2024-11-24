describe("Test test detection", function()
  local nio = require("nio")
  nio.tests.it("detect tests in fsharp file", function()
    local plugin = require("neotest-dotnet")
    local dir = vim.fn.getcwd() .. "/spec/samples/test_solution"
    local test_file = dir .. "/src/FsharpTest/Tests.fs"
    local positions = plugin.discover_positions(test_file)
    assert.are_equal(nil, positions)
  end)
  nio.tests.it("detect tests in c_sharp file", function()
    local plugin = require("neotest-dotnet")
    local dir = vim.fn.getcwd() .. "/spec/samples/test_solution"
    local test_file = dir .. "/src/CSharpTest/UnitTest1.cs"
    local positions = plugin.discover_positions(test_file)
    assert.are_equal(nil, positions)
  end)
end)
