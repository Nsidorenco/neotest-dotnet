describe("test cache should", function()
  -- add test_discovery script and treesitter parsers installed with luarocks
  vim.opt.runtimepath:append(vim.fn.getcwd())
  vim.opt.runtimepath:append(vim.fn.expand("~/.luarocks/lib/lua/5.1/"))

  local nio = require("nio")

  nio.tests.it("return stored unix path using windows path query", function()
    local cache = require("neotest-dotnet.vstest.discovery.cache")

    local sample_project = {
      proj_file = "C:\\src\\CSharpTest\\CSharpTest.csproj",
      dll_file = "C:\\src\\CSharpTest\\bin\\Debug\\net6.0\\CSharpTest.dll",
      is_test_project = true,
    }

    local test_cases = {
      ["C:/src/CSharpTest/CSharpTest.cs"] = {
        {
          CodeFilePath = "C:\\src\\CSharpTest\\CSharpTest.cs",
          DisplayName = "CSharpTest.CSharpTest.TestMethod1",
          FullyQualifiedName = "CSharpTest.CSharpTest.TestMethod1",
          LineNumber = 10,
        },
      },
    }

    cache.populate_discovery_cache(sample_project, test_cases, 0)

    local cached_test_cases =
      cache.get_cache_entry(sample_project, "C:\\src\\CSharpTest\\CSharpTest.cs")

    local expected = {
      {
        CodeFilePath = "C:\\src\\CSharpTest\\CSharpTest.cs",
        DisplayName = "CSharpTest.CSharpTest.TestMethod1",
        FullyQualifiedName = "CSharpTest.CSharpTest.TestMethod1",
        LineNumber = 10,
      },
    }

    assert.is_not_nil(cached_test_cases)
    assert.are_same(expected, cached_test_cases.TestCases)
  end)

  nio.tests.it("return stored windows path using unix path query", function()
    local cache = require("neotest-dotnet.vstest.discovery.cache")

    local sample_project = {
      proj_file = "C:\\src\\CSharpTest\\CSharpTest.csproj",
      dll_file = "C:\\src\\CSharpTest\\bin\\Debug\\net6.0\\CSharpTest.dll",
      is_test_project = true,
    }

    local test_cases = {
      ["C:\\src\\CSharpTest\\CSharpTest.cs"] = {
        {
          CodeFilePath = "C:\\src\\CSharpTest\\CSharpTest.cs",
          DisplayName = "CSharpTest.CSharpTest.TestMethod1",
          FullyQualifiedName = "CSharpTest.CSharpTest.TestMethod1",
          LineNumber = 10,
        },
      },
    }

    cache.populate_discovery_cache(sample_project, test_cases, 0)

    local cached_test_cases =
      cache.get_cache_entry(sample_project, "C:/src/CSharpTest/CSharpTest.cs")

    local expected = {
      {
        CodeFilePath = "C:\\src\\CSharpTest\\CSharpTest.cs",
        DisplayName = "CSharpTest.CSharpTest.TestMethod1",
        FullyQualifiedName = "CSharpTest.CSharpTest.TestMethod1",
        LineNumber = 10,
      },
    }

    assert.is_not_nil(cached_test_cases)
    assert.are_same(expected, cached_test_cases.TestCases)
  end)
end)
