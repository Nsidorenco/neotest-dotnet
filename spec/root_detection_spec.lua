describe("Test root detection", function()
  it("Detect .sln file as root", function()
    local plugin = require("neotest-dotnet")
    local dir = vim.fn.getcwd() .. "/spec/samples/root_detection/sln_dir"
    local root = plugin.root(dir)
    assert.are_equal(dir, root)
  end)
  it("Detect .sln file as root from project dir", function()
    local plugin = require("neotest-dotnet")
    local dir = vim.fn.getcwd() .. "/spec/samples/root_detection/sln_dir"
    local root = plugin.root(dir .. "/proj")
    assert.are_equal(dir, root)
  end)
end)
