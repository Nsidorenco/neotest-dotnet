local _MODREV, _SPECREV = "scm", "-1"
rockspec_format = "3.0"
package = "neotest-dotnet"
version = _MODREV .. _SPECREV

dependencies = {
  "neotest",
  "tree-sitter-fsharp",
  "tree-sitter-c_sharp",
}

test_dependencies = {
  "lua >= 5.1",
  "nlua",
}

source = {
  url = "git://github.com/issafalcon/neotest-dotnet",
}

build = {
  type = "builtin",
}
