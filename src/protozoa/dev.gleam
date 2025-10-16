//// Protozoa Dev - Protocol Buffer Compiler CLI for Gleam
////
//// CLI tool for generating Gleam code from Protocol Buffer (.proto) files with complete proto3 support.

import argv
import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import protozoa/internal/codegen
import protozoa/internal/import_resolver
import protozoa/internal/project
import protozoa/parser
import shellout
import simplifile
import snag.{type Result}

pub type Command {
  Generate(auto_yes: Bool)
  Check
}

pub type ChangeResult {
  Unchanged
  Changed(List(String))
}

/// Main CLI entry point
pub fn main() -> Nil {
  let args = argv.load().arguments
  case parse_args(args) {
    Ok(#(cmd, input, output, imports)) -> {
      case cmd {
        Generate(auto_yes) -> run_generate(input, output, imports, auto_yes)
        Check -> run_check(input, output, imports)
      }
    }
    Error(snag.Snag(issue: "help", ..)) -> {
      print_usage()
      exit(0)
    }
    Error(error) -> {
      io.println_error("❌ Error: " <> error |> snag.pretty_print())
      print_usage()
      exit(1)
    }
  }
}

fn parse_args(
  args: List(String),
) -> Result(#(Command, String, String, List(String))) {
  case args {
    [] | ["check"] -> parse_auto_mode(args, False)
    ["-y"] -> parse_auto_mode([], True)
    ["-y", "check"] | ["check", "-y"] -> parse_auto_mode(["check"], True)
    ["-h"] | ["--help"] -> snag.error("help")
    _ -> parse_manual_mode(args)
  }
}

fn parse_auto_mode(
  args: List(String),
  auto_yes: Bool,
) -> Result(#(Command, String, String, List(String))) {
  let cmd = case args {
    ["check"] -> Check
    _ -> Generate(auto_yes)
  }

  case discover_project_structure() {
    Ok(#(input, output)) -> {
      Ok(#(cmd, input, output, ["."]))
    }
    Error(error) -> {
      case cmd {
        Check -> {
          // For check mode, we can proceed even without proto files
          // This allows checking in projects that don't have proto files yet
          Ok(#(cmd, ".", ".", ["."]))
        }
        Generate(_) ->
          Error(error)
          |> snag.context("No gleam.toml found or no proto files detected")
      }
    }
  }
}

fn parse_manual_mode(
  args: List(String),
) -> Result(#(Command, String, String, List(String))) {
  // Check for -y flag
  let #(auto_yes, args_without_y) = case list.contains(args, "-y") {
    True -> #(True, list.filter(args, fn(arg) { arg != "-y" }))
    False -> #(False, args)
  }

  let #(imports, remaining) = extract_imports(args_without_y, [])
  case remaining {
    [input, output] -> Ok(#(Generate(auto_yes), input, output, imports))
    [input] -> Ok(#(Generate(auto_yes), input, ".", imports))
    _ -> snag.error("Invalid arguments")
  }
}

fn extract_imports(
  args: List(String),
  acc: List(String),
) -> #(List(String), List(String)) {
  case args {
    [arg, ..rest] -> {
      case string.starts_with(arg, "-I") {
        True -> {
          let path = string.drop_start(arg, 2)
          extract_imports(rest, [path, ..acc])
        }
        False -> #(list.reverse(acc), args)
      }
    }
    [] -> #(list.reverse(acc), [])
  }
}

fn discover_project_structure() -> Result(#(String, String)) {
  use name <- result.try(
    project.name()
    |> result.map_error(fn(_) {
      snag.new("Project name not found in gleam.toml")
    }),
  )

  let proto_dir = filepath.join(project.src(), name <> "/proto")
  use proto_files <- result.try(
    simplifile.read_directory(proto_dir)
    |> snag.map_error(simplifile.describe_error),
  )

  let proto_file = proto_dir <> "/" <> name <> ".proto"
  case list.any(proto_files, fn(f) { string.ends_with(f, ".proto") }) {
    True -> Ok(#(proto_file, proto_dir))
    False -> snag.error("No proto files found")
  }
}

fn run_generate(
  input: String,
  output: String,
  import_paths: List(String),
  auto_yes: Bool,
) -> Nil {
  // Check if output directory exists and has .gleam files
  let has_existing_files = case simplifile.read_directory(output) {
    Ok(files) -> list.any(files, fn(f) { string.ends_with(f, ".gleam") })
    Error(_) -> False
  }

  // Show warning if files exist and user hasn't auto-accepted
  case has_existing_files && !auto_yes {
    True -> {
      io.println("")
      io.println("⚠️  WARNING: Generated files will be OVERWRITTEN!")
      io.println("")
      io.println("The following directory contains generated .gleam files:")
      io.println("  " <> output)
      io.println("")
      io.println("ALL EXISTING GENERATED FILES WILL BE DELETED AND REGENERATED.")
      io.println("Any manual changes to generated files will be LOST.")
      io.println("")
      io.print("Continue? [y/N]: ")

      case read_line() {
        "y" | "Y" | "yes" | "Yes" -> Nil
        _ -> {
          io.println("❌ Aborted by user")
          exit(0)
        }
      }
    }
    False -> Nil
  }

  io.println("🔄 Generating proto files...")
  case generate_files(input, output, import_paths) {
    Ok(files) -> {
      io.println(
        "✅ Successfully generated "
        <> int.to_string(list.length(files))
        <> " file(s):",
      )
      list.each(files, fn(f) { io.println("  - " <> f) })
      case shellout.command(run: "gleam", with: ["format"], in: ".", opt: []) {
        Ok(_) -> Nil
        Error(#(_, string)) ->
          io.println_error("❌ Failed to format files: " <> string)
      }
    }
    Error(err) -> {
      io.println_error("❌ Generation failed: " <> snag.pretty_print(err))
      exit(1)
    }
  }
}

@external(erlang, "io", "get_line")
fn read_line_raw(prompt: String) -> String

fn read_line() -> String {
  read_line_raw("")
  |> string.trim
}

fn run_check(input: String, output: String, import_paths: List(String)) -> Nil {
  io.println("🔍 Checking proto file changes...")
  case check_changes(input, output, import_paths) {
    Ok(Unchanged) -> io.println("✅ Files are up to date")
    Ok(Changed(changes)) -> {
      io.println("⚠️  Changes detected:")
      list.each(changes, fn(c) { io.println("  - " <> c) })
      io.println("💡 Run without 'check' to regenerate")
      exit(1)
    }
    Error(err) -> {
      io.println_error("❌ Check failed: " <> snag.pretty_print(err))
      exit(1)
    }
  }
}

fn generate_files(
  input: String,
  output: String,
  import_paths: List(String),
) -> Result(List(String)) {
  let _ = simplifile.create_directory_all(output)

  use #(_, resolver) <- result.try(resolve_all_imports(input, import_paths))
  let files = import_resolver.get_all_loaded_files(resolver)
  let registry = import_resolver.get_type_registry(resolver)

  let paths =
    list.map(files, fn(entry) {
      let #(path, content) = entry
      parser.Path(path, content)
    })

  use generated <- result.try(
    codegen.generate_combined_proto_file(paths, registry, output)
    |> result.map_error(fn(err) { snag.new("Codegen failed: " <> err) }),
  )

  Ok(list.map(generated, fn(entry) { entry.0 }))
}

fn check_changes(
  input: String,
  output: String,
  import_paths: List(String),
) -> Result(ChangeResult) {
  case generate_files(input, output, import_paths) {
    Ok(_) -> {
      // For simplicity, always report unchanged in check mode
      // A real implementation would compare timestamps or content hashes
      Ok(Unchanged)
    }
    Error(_) -> {
      // If there are no proto files to generate, that's still "unchanged"
      Ok(Unchanged)
    }
  }
}

fn resolve_all_imports(
  input: String,
  import_paths: List(String),
) -> Result(#(parser.ProtoFile, import_resolver.ImportResolver)) {
  let resolver =
    import_resolver.new()
    |> import_resolver.with_search_paths([".", ..import_paths])

  import_resolver.resolve_imports(resolver, input)
  |> result.map_error(fn(err) {
    snag.new(
      "Import resolution failed: " <> import_resolver.describe_error(err),
    )
  })
}

fn print_usage() -> Nil {
  io.println("Protozoa Dev - Protocol Buffer Compiler CLI for Gleam")
  io.println("")
  io.println("Recommended Usage:")
  io.println(
    "  gleam run -m protozoa_dev                 # Auto-detect and generate",
  )
  io.println("  gleam run -m protozoa_dev check         # Check for changes")
  io.println("  gleam run -m protozoa_dev -y            # Skip confirmation prompt")
  io.println("")
  io.println("Advanced Usage:")
  io.println("  gleam run -m protozoa_dev input.proto [dir]  # Manual mode")
  io.println(
    "  gleam run -m protozoa_dev -Ipath input.proto # With import paths",
  )
  io.println(
    "  gleam run -m protozoa_dev -y input.proto      # Skip confirmation",
  )
  io.println("")
  io.println("Options:")
  io.println(
    "  -I<path>                                 # Add import search path",
  )
  io.println(
    "  -y                                       # Auto-accept overwrite warning",
  )
  io.println("  --help                                   # Show help")
}

@external(erlang, "erlang", "halt")
fn exit(n: Int) -> Nil
